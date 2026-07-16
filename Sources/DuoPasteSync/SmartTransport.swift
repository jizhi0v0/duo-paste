import Foundation
import DuoPasteCore

/// PR 3 smart transport：daemon 启动 + DNS 变化时探每个 peer 的 `/health.ponte_host`，
/// 决定每个 peer 用哪条 URL 跑 pull / WS。**只在 trigger 时跑一次**——周期 probe / 切换
/// 不在这层做，用户明确选了"trust ponte 永久更快"的策略。
///
/// 决策优先级（per peer）：
/// 1. **手抄 `pull_url`**（config 显式给）+ probe OK → 用它（trump card；用户已亲测）
/// 2. 学到的 `ponte_host` + probe OK → 用 `https://<ponte_host>:<peer.url.port>`
/// 3. tailscale `peer.url` 兜底
///
/// WS 跟 chosen pull URL 同 host：ponte 路径 → `URLSessionWebSocketTransport`，tailscale →
/// `NIOWebSocketTransport`。**不**给 WS 单独 RTT probe——ponte/tailscale 的 RTT 差异在 ms 级，
/// WS 流量小（hello/cursor_advanced 几百字节），跟 pull 共享同一条 host 让 Surge proxy
/// keep-alive 连接池复用率最高（如未来观察到差异显著再加独立 probe）。
///
/// **非 actor**——PR 3 stateless 函数式 OK；PR 4 加 coalesce 防抖时再外面包 actor
public struct SmartTransport: Sendable {
    public struct PeerDecision: Sendable, Equatable {
        public let peerIndex: Int
        /// config 里写的 `peer.url`（tailscale）。永远 ≠ nil
        public let configuredURL: URL
        /// 用户手抄的 `peer.pull_url`（如配）。nil = 没手抄
        public let manualPullURL: URL?
        /// 学到的对端 ponte_host。nil = 对端没装 Surge / 没配 Ponte / 探测失败
        public let learnedPonteHost: String?
        /// PullWorker / paste-fetcher / blob-fetcher 真正用的 baseURL
        public let chosenPullURL: URL
        /// WSNotificationClient 真正用的 baseURL（pre-WS-URL 转换；HTTP scheme）
        public let chosenWSURL: URL
        /// WS 字节层 transport 类型——为 PeerBuilder 选 NIO 还是 URLSession 实现
        public let chosenWSKind: TransportKind
        /// 每个 candidate URL 的 /health RTT（ms）。unreachable = -1。决策证据 + log
        public let httpRttMs: [URL: Int64]

        public init(
            peerIndex: Int,
            configuredURL: URL,
            manualPullURL: URL?,
            learnedPonteHost: String?,
            chosenPullURL: URL,
            chosenWSURL: URL,
            chosenWSKind: TransportKind,
            httpRttMs: [URL: Int64]
        ) {
            self.peerIndex = peerIndex
            self.configuredURL = configuredURL
            self.manualPullURL = manualPullURL
            self.learnedPonteHost = learnedPonteHost
            self.chosenPullURL = chosenPullURL
            self.chosenWSURL = chosenWSURL
            self.chosenWSKind = chosenWSKind
            self.httpRttMs = httpRttMs
        }

        /// 给日志 / mesh-doctor 打印用：`ponte (mac.sgponte:8443)` / `tailscale (mbp.tail.ts.net:8443)`
        public var transportLabel: String {
            let host = chosenPullURL.host ?? "?"
            let port = chosenPullURL.port.map { ":\($0)" } ?? ""
            let kind = chosenWSKind == .urlSession ? "ponte" : "tailscale"
            return "\(kind) (\(host)\(port))"
        }
    }

    public enum TransportKind: String, Sendable, Equatable {
        case nio
        case urlSession
    }

    /// Health probe closure 签名。生产路径 = `HTTPPeerClient.fetchPrimaryHealth` 包装 RTT 测算；
    /// 测试注入 fake 避免起真 server
    public typealias HealthProbe = @Sendable (URL) async -> (outcome: PrimaryHealthResult.Outcome, rttMs: Int64)

    /// Probe-level structured logger。每个 candidate 每次 attempt 都调一次,line 单行 grep 友好,
    /// 形如:
    ///
    ///     smart-transport: peer 0 candidate=tailscale url=https://... probe=ok rtt=43ms device_id=... ponte_host=... attempt=1/2
    ///     smart-transport: peer 0 candidate=ponte url=https://... probe=unreachable rtt=-1 reason="transport: bad URL" attempt=2/2
    ///
    /// 生产路径默认写 stderr(跟 daemon 其他日志同源);测试可注入 capture 验日志格式。
    /// 在 probe 失败时**这是唯一**能看到 reason 的地方——SmartTransport.discover 把失败折成
    /// rtts[url] = -1 + chosenPullURL fallback,reason 字符串丢了。
    public typealias ProbeLogger = @Sendable (String) -> Void

    public init() {}

    /// 启动 / DNS 变化时调一次，每个 peer 返回一个 decision。
    ///
    /// - `probe` 默认 = 真实 `HTTPPeerClient.fetchPrimaryHealth` + Date() 测 RTT；session 路由
    ///   走 `PonteSession.session(for:fallback:)` 让 ponte URL 走 Surge proxy
    /// - `rttProbeTimeoutSec` 每个 candidate 单独的 deadline；超时算 unreachable
    /// - `logger` 默认 = stderr 写入。测试 / mesh-doctor 等可注入 capture
    public func discover(
        peers: [Config.PeerConfig],
        auth: HMACAuth,
        tailscaleSession: URLSession,
        rttProbeTimeoutSec: TimeInterval = 3.0,
        cachedPonteHosts: [String?] = [],
        probe: HealthProbe? = nil,
        logger: ProbeLogger? = nil
    ) async -> [PeerDecision] {
        let actualProbe: HealthProbe = probe ?? Self.defaultProbe(
            auth: auth, tailscaleSession: tailscaleSession, timeoutSec: rttProbeTimeoutSec
        )
        let actualLogger: ProbeLogger = logger ?? Self.defaultStderrLogger
        var out: [PeerDecision] = []
        for (idx, peer) in peers.enumerated() {
            let cached = cachedPonteHosts.indices.contains(idx) ? cachedPonteHosts[idx] : nil
            let decision = await Self.decideOne(
                peerIndex: idx,
                peer: peer,
                cachedPonteHost: cached,
                probe: actualProbe,
                logger: actualLogger
            )
            out.append(decision)
        }
        // Step 3 兜底:如果**所有 peer 的所有 candidate** 都不可达,打 WARN——这是
        // "系统级 proxy 异常 / Surge 没启 / 网络栈崩"的特征,运维侧需要立刻看见
        let anyReachable = out.contains { d in d.httpRttMs.values.contains(where: { $0 >= 0 }) }
        if !anyReachable && !peers.isEmpty {
            actualLogger(
                "smart-transport: WARN all candidates unreachable across \(peers.count) peer(s) — " +
                "诊断 hint: 检查 (1) Surge / proxy 是否运行 (2) 系统 HTTP/HTTPS proxy 设置 " +
                "(3) tailnet 连通性 (`tailscale status`) (4) shared-secret 是否一致"
            )
        }
        return out
    }

    /// 默认 logger:写 stderr,带 newline。stderr 是全局 FILE *,POSIX 保证 fputs
    /// 是 thread-safe(`flockfile` 隐式同步),@Sendable closure 安全持有
    static let defaultStderrLogger: ProbeLogger = { line in
        fputs(line + "\n", stderr)
    }

    /// 单 peer 决策——可测：
    /// 1. C1 = peer.url 跑 /health 拿 ponte_host + RTT
    /// 2. C2 = peer.pullURL 如配——独立 probe
    /// 3. C3 = `https://<ponte_host>:<peer.url.port>` 如学到——独立 probe
    /// 4. 优先级 manual > ponte > tailscale
    static func decideOne(
        peerIndex: Int,
        peer: Config.PeerConfig,
        cachedPonteHost: String? = nil,
        probe: HealthProbe,
        logger: ProbeLogger? = nil
    ) async -> PeerDecision {
        // C1 — tailscale URL,永远先探(要拿 ponte_host 字段)。带 retry 防启动竞态
        let (c1Outcome, c1Rtt) = await probeWithRetry(
            probe, url: peer.url,
            peerIndex: peerIndex, candidate: "tailscale", logger: logger
        )
        var rtts: [URL: Int64] = [peer.url: (isReachable(c1Outcome) ? c1Rtt : -1)]
        var learnedPonteHost: String? = nil
        if case .ok(_, _, let ponteHost) = c1Outcome { learnedPonteHost = ponteHost }
        // C1 没学到 ponte_host（tailscale 不通）但上一轮成功学过 → 用缓存构造 C3
        if learnedPonteHost == nil, let cached = cachedPonteHost {
            learnedPonteHost = cached
            logger?("smart-transport: peer \(peerIndex) using cached ponte_host=\(cached) (tailscale unreachable)")
        }

        // C2 — manual pull_url 如有
        var manualReachable = false
        if let manualURL = peer.pullURL {
            // 同 URL 不重测
            if manualURL == peer.url {
                manualReachable = isReachable(c1Outcome)
            } else {
                let (c2Out, c2Rtt) = await probeWithRetry(
                    probe, url: manualURL,
                    peerIndex: peerIndex, candidate: "manual", logger: logger
                )
                rtts[manualURL] = isReachable(c2Out) ? c2Rtt : -1
                manualReachable = isReachable(c2Out)
            }
        }

        // C3 — learned ponte URL 如有
        var c3URL: URL? = nil
        var c3Reachable = false
        if let host = learnedPonteHost,
           let candidate = makePonteCandidateURL(forPeerURL: peer.url, ponteHost: host)
        {
            // 不重复测:peer.url 已经是 ponte host 时 c1 就是它
            if candidate == peer.url {
                c3URL = peer.url
                c3Reachable = isReachable(c1Outcome)
            } else if candidate == peer.pullURL {
                c3URL = peer.pullURL
                c3Reachable = manualReachable
            } else {
                let (c3Out, c3Rtt) = await probeWithRetry(
                    probe, url: candidate,
                    peerIndex: peerIndex, candidate: "ponte", logger: logger
                )
                rtts[candidate] = isReachable(c3Out) ? c3Rtt : -1
                c3URL = candidate
                c3Reachable = isReachable(c3Out)
            }
        }

        // 决策
        let chosenPullURL: URL
        if let manualURL = peer.pullURL, manualReachable {
            chosenPullURL = manualURL
        } else if let pURL = c3URL, c3Reachable {
            chosenPullURL = pURL
        } else {
            chosenPullURL = peer.url
        }

        // WS 跟 pull host 同步
        let wsKind: TransportKind = isPonteURL(chosenPullURL) ? .urlSession : .nio

        return PeerDecision(
            peerIndex: peerIndex,
            configuredURL: peer.url,
            manualPullURL: peer.pullURL,
            learnedPonteHost: learnedPonteHost,
            chosenPullURL: chosenPullURL,
            chosenWSURL: chosenPullURL,
            chosenWSKind: wsKind,
            httpRttMs: rtts
        )
    }

    /// `https://<ponte_host>:<peer.url.port ?? 443>`。port 沿用 tailscale URL 的端口
    /// (生产部署 daemon 默认 8443，ponte 隧道转发也用同一 port)。peer.url 没有 host 则 nil
    static func makePonteCandidateURL(forPeerURL peer: URL, ponteHost: String) -> URL? {
        var comp = URLComponents()
        comp.scheme = "https"
        comp.host = ponteHost
        comp.port = peer.port ?? 443
        return comp.url
    }

    static func isPonteURL(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        return h.hasSuffix(".sgponte")
    }

    static func isReachable(_ outcome: PrimaryHealthResult.Outcome) -> Bool {
        if case .ok = outcome { return true }
        return false
    }

    // MARK: - PeerBuilder

    /// 一站式从 PeerDecision 建 `(PullWorker, WSNotificationClient?)` pair——AppDelegate
    /// 启动 + PR 4 reconcileTransports 都调它。把"建 peer 用什么 transport"的复杂度集中
    /// 在一处，避免散落在 AppDelegate / MeshSupervisor 两边
    public struct PeerBuilder: Sendable {
        public let database: DuoPasteCore.Database
        public let blobs: BlobStore
        public let meshStatus: MeshStatus
        public let pasteSuppressions: PasteSuppressionSet?
        public let selfDeviceID: String
        public let evictOnFull: @Sendable () throws -> Bool
        public let pullWorkerConfig: PullWorker.Config
        public let wsEnabled: Bool
        public let auth: HMACAuth
        public let tailscaleSession: URLSession
        public let onCatastrophicFailure: @Sendable () -> Void
        /// peer config 列表里的 deviceID(严格模式)。索引跟 decision.peerIndex 对齐
        public let expectedPeerDeviceIDs: [String?]
        /// 每次 PullWorker /health 探测完调一次。生产路径 = AppDelegate hop @MainActor 写
        /// AppState.transports[i].httpRttMs[chosenHost],让 UI 反映 runtime 真实健康度。
        /// `>= 0` = . ok 响应的 RTT;`-1` = 任何失败(对齐 SmartTransport `isReachable` 语义)。
        /// nil = 不接(测试 / PR 3 老调用点),PullWorker 内部 callback 也 nil
        public let onHealthProbed: (@Sendable (_ peerIndex: Int, _ rttMs: Int64) -> Void)?
        /// PullWorker 连续 transient 失败到 threshold 时调一次,生产路径 = AppDelegate →
        /// MeshSupervisor.reconcileTransports() 触发 quick recovery 不等周期 5min。
        /// peerIndex 让多 peer 部署能区分哪个 peer 出问题(虽然 reconcile 是全 peer 重 discover)。
        /// nil = 不接,PullWorker 内部 callback 也 nil
        public let onChosenLikelyDown: (@Sendable (_ peerIndex: Int) -> Void)?
        public let onPinOperationsResolved: (@Sendable () -> Void)?
        public let onCredentialRevocationsMerged: (@Sendable (Int) -> Void)?

        public init(
            database: DuoPasteCore.Database,
            blobs: BlobStore,
            meshStatus: MeshStatus,
            pasteSuppressions: PasteSuppressionSet?,
            selfDeviceID: String,
            evictOnFull: @escaping @Sendable () throws -> Bool,
            pullWorkerConfig: PullWorker.Config,
            wsEnabled: Bool,
            auth: HMACAuth,
            tailscaleSession: URLSession,
            onCatastrophicFailure: @escaping @Sendable () -> Void,
            expectedPeerDeviceIDs: [String?],
            onHealthProbed: (@Sendable (_ peerIndex: Int, _ rttMs: Int64) -> Void)? = nil,
            onChosenLikelyDown: (@Sendable (_ peerIndex: Int) -> Void)? = nil,
            onPinOperationsResolved: (@Sendable () -> Void)? = nil,
            onCredentialRevocationsMerged: (@Sendable (Int) -> Void)? = nil
        ) {
            self.database = database
            self.blobs = blobs
            self.meshStatus = meshStatus
            self.pasteSuppressions = pasteSuppressions
            self.selfDeviceID = selfDeviceID
            self.evictOnFull = evictOnFull
            self.pullWorkerConfig = pullWorkerConfig
            self.wsEnabled = wsEnabled
            self.auth = auth
            self.tailscaleSession = tailscaleSession
            self.onCatastrophicFailure = onCatastrophicFailure
            self.expectedPeerDeviceIDs = expectedPeerDeviceIDs
            self.onHealthProbed = onHealthProbed
            self.onChosenLikelyDown = onChosenLikelyDown
            self.onPinOperationsResolved = onPinOperationsResolved
            self.onCredentialRevocationsMerged = onCredentialRevocationsMerged
        }

        public func build(decision: PeerDecision) -> MeshSupervisor.Peer {
            let pullURL = decision.chosenPullURL
            let httpSession = PonteSession.session(for: pullURL, fallback: tailscaleSession)
            let client = HTTPPeerClient(baseURL: pullURL, auth: auth, session: httpSession)
            let expectedPeerDeviceID = expectedPeerDeviceIDs.indices.contains(decision.peerIndex)
                ? expectedPeerDeviceIDs[decision.peerIndex]
                : nil
            // peerIndex 在闭包里 capture——SmartTransport reconcile 重建 builder 时
            // 新 decision.peerIndex 会重新 capture(MeshSupervisor 整 peer pair tear-down
            // 重 build),不会指错
            let probedCallback: (@Sendable (Int64) -> Void)? = onHealthProbed.map { outer in
                let idx = decision.peerIndex
                return { rttMs in outer(idx, rttMs) }
            }
            let downCallback: (@Sendable () -> Void)? = onChosenLikelyDown.map { outer in
                let idx = decision.peerIndex
                return { outer(idx) }
            }
            let worker = PullWorker(
                database: database,
                transport: client,
                pinTransport: client,
                selfDeviceID: selfDeviceID,
                expectedPeerDeviceID: expectedPeerDeviceID,
                meshStatus: meshStatus,
                pasteSuppressions: pasteSuppressions,
                blobFetcher: client,
                blobs: blobs,
                evictOnFull: evictOnFull,
                config: pullWorkerConfig,
                onHealthProbed: probedCallback,
                onChosenLikelyDown: downCallback,
                onPinOperationsResolved: onPinOperationsResolved,
                onCredentialRevocationsMerged: onCredentialRevocationsMerged
            )
            let wsClient: WSNotificationClient?
            if wsEnabled {
                let wsTransport: WSTransport
                switch decision.chosenWSKind {
                case .urlSession:
                    wsTransport = URLSessionWebSocketTransport(session: PonteSession.pontePool.session)
                case .nio:
                    wsTransport = NIOWebSocketTransport()
                }
                wsClient = WSNotificationClient(
                    peerURL: decision.chosenWSURL,
                    auth: auth,
                    expectedPeerDeviceID: expectedPeerDeviceID,
                    onCursorAdvanced: { [weak worker] _ in worker?.wake() },
                    onCatastrophicFailure: onCatastrophicFailure,
                    transport: wsTransport
                )
            } else {
                wsClient = nil
            }
            return MeshSupervisor.Peer(worker: worker, wsClient: wsClient)
        }
    }

    /// 单 candidate probe 的 retry wrapper——专治启动竞态(Surge HTTP CONNECT 冷启动 / tailscale
    /// DERP 抖动这种秒级瞬时不可达)。
    /// - `.ok` 立即返回(成功不重试)
    /// - `.rejected` 立即返回(应用层拒绝是确定性的,重来还是拒,白等)
    /// - `.unreachable` 才 sleep + retry,共最多 `retries+1` 次。最后一次仍 unreachable 返回最后一次结果
    /// 默认 retries=1 + backoff=1s:启动总延迟最多多 1-2s,换"启动 5s 内 Surge 才就绪"这种 case 不被永久锁死
    ///
    /// `peerIndex` / `candidate` / `logger` 三个可选参数走"诊断盲点"修复路径——每次 attempt
    /// (含中间 retry 的 transient 失败 + 最终成功/放弃)都打 structured 单行日志。生产路径由
    /// `decideOne` 始终 propagate `logger`,测试路径可不传(向后兼容 SmartTransportTests)。
    static func probeWithRetry(
        _ probe: HealthProbe,
        url: URL,
        retries: Int = 1,
        backoffSec: TimeInterval = 1.0,
        peerIndex: Int? = nil,
        candidate: String? = nil,
        logger: ProbeLogger? = nil
    ) async -> (outcome: PrimaryHealthResult.Outcome, rttMs: Int64) {
        var last: (outcome: PrimaryHealthResult.Outcome, rttMs: Int64) = (.unreachable(reason: "no probe ran"), -1)
        let totalAttempts = retries + 1
        for attempt in 0...retries {
            let r = await probe(url)
            last = r
            if let logger = logger {
                logger(formatProbeLog(
                    peerIndex: peerIndex,
                    candidate: candidate,
                    url: url,
                    attempt: attempt + 1,
                    total: totalAttempts,
                    outcome: r.outcome,
                    rttMs: r.rttMs
                ))
            }
            switch r.outcome {
            case .ok, .rejected:
                return r
            case .unreachable:
                if attempt < retries {
                    try? await Task.sleep(nanoseconds: UInt64(backoffSec * 1_000_000_000))
                }
            }
        }
        return last
    }

    /// 拼 candidate probe 单行日志。grep 友好的 key=value 格式,字段顺序固定:
    /// peer / candidate / url / probe / rtt / [reason / device_id / ponte_host] / attempt
    ///
    /// 单元测试可直接 import 这个 helper 校验格式不漂移
    static func formatProbeLog(
        peerIndex: Int?,
        candidate: String?,
        url: URL,
        attempt: Int,
        total: Int,
        outcome: PrimaryHealthResult.Outcome,
        rttMs: Int64
    ) -> String {
        var parts: [String] = ["smart-transport:"]
        if let idx = peerIndex { parts.append("peer \(idx)") }
        if let c = candidate { parts.append("candidate=\(c)") }
        parts.append("url=\(url.absoluteString)")
        switch outcome {
        case .ok(let did, _, let ph):
            parts.append("probe=ok")
            parts.append("rtt=\(rttMs)ms")
            parts.append("device_id=\(did)")
            if let ph = ph { parts.append("ponte_host=\(ph)") }
        case .unreachable(let reason):
            parts.append("probe=unreachable")
            parts.append("rtt=\(rttMs)ms")
            parts.append("reason=\(quotedReason(reason))")
        case .rejected(let reason):
            parts.append("probe=rejected")
            parts.append("rtt=\(rttMs)ms")
            parts.append("reason=\(quotedReason(reason))")
        }
        if total > 1 {
            parts.append("attempt=\(attempt)/\(total)")
        }
        return parts.joined(separator: " ")
    }

    /// reason 字符串可能含空格 / 换行 / 双引号 / tab → 单行日志 grep 时会撕裂字段。
    /// 用引号包 + 替换内部双引号为单引号 + 把换行/回车/tab 折成空格保证单行 + tab-friendly
    private static func quotedReason(_ s: String) -> String {
        let safe = s
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return "\"\(safe)\""
    }

    /// 默认 probe 实现——HTTPPeerClient.fetchPrimaryHealth + Date() RTT + per-probe deadline
    static func defaultProbe(
        auth: HMACAuth,
        tailscaleSession: URLSession,
        timeoutSec: TimeInterval
    ) -> HealthProbe {
        return { url in
            let session = PonteSession.session(for: url, fallback: tailscaleSession)
            let client = HTTPPeerClient(baseURL: url, auth: auth, session: session)
            let start = Date()
            // deadline race——避免单个 unreachable peer 卡住整个 discover
            let result: PrimaryHealthResult.Outcome = await withTaskGroup(of: PrimaryHealthResult.Outcome.self) { g in
                g.addTask {
                    do {
                        let r = try await client.fetchPrimaryHealth()
                        return r.outcome
                    } catch {
                        return .unreachable(reason: "\(error)")
                    }
                }
                g.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                    return .unreachable(reason: "probe timeout \(timeoutSec)s")
                }
                let first = await g.next() ?? .unreachable(reason: "no result")
                g.cancelAll()
                return first
            }
            let rttMs = Int64(Date().timeIntervalSince(start) * 1000)
            return (result, rttMs)
        }
    }
}

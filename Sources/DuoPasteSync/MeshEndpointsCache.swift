import Foundation
import DuoPasteCore

/// Mesh-wide endpoint 聚合缓存。本机 daemon 周期调每个 mesh peer 的 `GET /endpoints`
/// 拿对端候选 list,缓存供本机 `/endpoints` 路由聚合返回给 iOS。
///
/// 让 iOS 配对**任一**Mac 就能拿到全 mesh 所有 peer 的 endpoint 候选 → EndpointPicker
/// 探活全部 → 选全局最快。比如 iOS 跟 MBP 同 LAN 跟 mini 不同 LAN,配 mini 后仍能
/// pick 到 MBP 的 `.local` 走 LAN 最快路径。
///
/// **不变量**:
/// - 周期 60s refresh,但 `MeshSupervisor.reconcileTransports()` 完成后调 `refreshNow()`
///   让新发现的 peer 立即可见
/// - 缓存 entry 失败标 `healthy=false` 但保留 `staleAfterSec=600s` 防短暂闪断让 iOS
///   失去 fallback 候选
/// - 输出顺序按 peerDeviceID 排序保稳定(snapshot diff 不抖)
public actor MeshEndpointsCache {
    public struct FetchError: Error, Equatable, Sendable, CustomStringConvertible {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    public struct Config: Sendable {
        public var refreshIntervalSec: TimeInterval
        public var staleAfterSec: TimeInterval
        public var fetchTimeoutSec: TimeInterval

        public init(
            refreshIntervalSec: TimeInterval = 60,
            staleAfterSec: TimeInterval = 600,
            fetchTimeoutSec: TimeInterval = 5
        ) {
            self.refreshIntervalSec = refreshIntervalSec
            self.staleAfterSec = staleAfterSec
            self.fetchTimeoutSec = fetchTimeoutSec
        }
    }

    /// 拿当前 mesh peer 决策的闭包。生产 = supervisor.currentDecisions;测试注入 stub
    public typealias DecisionsProvider = @Sendable () async -> [SmartTransport.PeerDecision]
    /// 给 peer URL 拉 /endpoints 的闭包。生产 = HTTP HMAC fetch;测试 stub
    public typealias FetchProvider = @Sendable (URL) async -> Result<PeerEndpointsPage, FetchError>

    private let decisionsProvider: DecisionsProvider
    private let fetchProvider: FetchProvider
    private let selfDeviceID: String
    private let config: Config
    private let log: @Sendable (String) -> Void
    /// snapshot 变化时调,通常 wire 到 WSBroadcaster.broadcastEndpointsChanged
    private let onSnapshotChanged: @Sendable (Int64) -> Void

    private struct Entry {
        var endpoints: [PeerEndpoint]
        var learnedAtUnix: Int64
        var healthy: Bool
        var firstFailureAtUnix: Int64?
    }

    private var entries: [String: Entry] = [:]
    /// decision.chosenPullURL → 对端 deviceID 映射,记从 .success 路径学到的反查表。
    /// 失败 fetch 时通过这查 deviceID 把对应 entry 标 unhealthy
    private var urlToDeviceID: [URL: String] = [:]
    private var refreshTask: Task<Void, Never>?
    /// 上次 broadcast 出去的 snapshot hash,用于 diff 判断
    private var lastBroadcastHash: Int = 0

    public init(
        selfDeviceID: String,
        decisionsProvider: @escaping DecisionsProvider,
        fetchProvider: @escaping FetchProvider,
        config: Config = Config(),
        onSnapshotChanged: @escaping @Sendable (Int64) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("mesh-endpoints-cache: \(msg)\n".utf8))
        }
    ) {
        self.selfDeviceID = selfDeviceID
        self.decisionsProvider = decisionsProvider
        self.fetchProvider = fetchProvider
        self.config = config
        self.onSnapshotChanged = onSnapshotChanged
        self.log = log
    }

    /// 生产路径方便 builder——supervisor + HMAC fetch 注入
    public static func production(
        supervisor: MeshSupervisor,
        auth: HMACAuth,
        selfDeviceID: String,
        session: URLSession = .shared,
        config: Config = Config(),
        onSnapshotChanged: @escaping @Sendable (Int64) -> Void = { _ in }
    ) -> MeshEndpointsCache {
        let timeout = config.fetchTimeoutSec
        return MeshEndpointsCache(
            selfDeviceID: selfDeviceID,
            decisionsProvider: {
                let all = await supervisor.currentDecisions
                return all.compactMap { $0 }
            },
            fetchProvider: { url in
                await Self.fetchEndpoints(
                    from: url, auth: auth, session: session, timeoutSec: timeout
                )
            },
            config: config,
            onSnapshotChanged: onSnapshotChanged
        )
    }

    /// 当前缓存 snapshot,按 peerDeviceID 字典序排序让 wire 顺序稳定。
    /// stale-purge 在这里执行:`learnedAtUnix + staleAfterSec < now` 的整个干掉
    public func snapshot() -> [MeshPeerEntry] {
        let now = Int64(Date().timeIntervalSince1970)
        let cutoff = now - Int64(config.staleAfterSec)
        let live = entries.filter { $0.value.learnedAtUnix >= cutoff }
        return live.keys.sorted().map { key in
            let e = live[key]!
            return MeshPeerEntry(
                peerDeviceID: key,
                endpoints: e.endpoints,
                learnedAtUnix: e.learnedAtUnix,
                healthy: e.healthy
            )
        }
    }

    public func startRefreshLoop() {
        guard refreshTask == nil else { return }
        let intervalNs = UInt64(config.refreshIntervalSec * 1_000_000_000)
        log("refresh loop started · interval=\(Int(config.refreshIntervalSec))s")
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// 主动 refresh——MeshSupervisor.reconcileTransports() 完调,新 peer 发现立即 fetch
    public func refreshNow() async {
        let decisions = await decisionsProvider()
        guard !decisions.isEmpty else {
            log("refreshNow: no peers")
            return
        }
        var anyChange = false
        let now = Int64(Date().timeIntervalSince1970)

        await withTaskGroup(of: (URL, Result<PeerEndpointsPage, FetchError>).self) { group in
            for decision in decisions {
                let url = decision.chosenPullURL
                let provider = self.fetchProvider
                group.addTask {
                    let r = await provider(url)
                    return (url, r)
                }
            }
            for await (url, result) in group {
                switch result {
                case .success(let page) where page.deviceID == selfDeviceID:
                    log("skip self (\(url)) — same device_id")
                case .success(let page):
                    // 老 daemon 没 device_id → 跳过(没法 stamp 进 MeshPeerEntry,iOS
                    // 也没法判 self 防回环)
                    guard let peerDeviceID = page.deviceID else {
                        log("skip \(url) — peer daemon too old, no device_id")
                        continue
                    }
                    // 学到这个 chosenPullURL 对应的 deviceID,下次失败时能反查
                    urlToDeviceID[url] = peerDeviceID
                    let oldEntry = entries[peerDeviceID]
                    let oldEndpoints = oldEntry?.endpoints
                    let wasUnhealthy = oldEntry?.healthy == false
                    entries[peerDeviceID] = Entry(
                        endpoints: page.endpoints,
                        learnedAtUnix: now,
                        healthy: true,
                        firstFailureAtUnix: nil
                    )
                    if oldEndpoints != page.endpoints || wasUnhealthy {
                        anyChange = true
                    }
                case .failure(let err):
                    log("fetch \(url) failed: \(err)")
                    // 反查 deviceID,只有以前成功过的才有 mapping;从未成功的失败 noop
                    if let key = urlToDeviceID[url], var e = entries[key] {
                        if e.healthy { anyChange = true }
                        e.healthy = false
                        if e.firstFailureAtUnix == nil {
                            e.firstFailureAtUnix = now
                        }
                        entries[key] = e
                    }
                }
            }
        }

        // stale purge
        let cutoff = now - Int64(config.staleAfterSec)
        let beforePurge = entries.count
        entries = entries.filter { _, v in v.learnedAtUnix >= cutoff }
        if entries.count != beforePurge {
            anyChange = true
            log("purged \(beforePurge - entries.count) stale entries")
        }

        if anyChange {
            let snap = snapshot()
            let hash = computeHash(snap)
            if hash != lastBroadcastHash {
                lastBroadcastHash = hash
                onSnapshotChanged(now)
                log("snapshot changed · \(snap.count) entries · broadcast")
            }
        }
    }

    private func computeHash(_ entries: [MeshPeerEntry]) -> Int {
        var hasher = Hasher()
        for e in entries {
            hasher.combine(e.peerDeviceID)
            hasher.combine(e.healthy)
            for ep in e.endpoints {
                hasher.combine(ep.url)
                hasher.combine(ep.kind.rawValue)
            }
        }
        return hasher.finalize()
    }

    // MARK: - 内部 HTTP

    nonisolated static func fetchEndpoints(
        from baseURL: URL,
        auth: HMACAuth,
        session: URLSession,
        timeoutSec: TimeInterval
    ) async -> Result<PeerEndpointsPage, FetchError> {
        let path = "/endpoints"
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeoutSec
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let bodyHash = HMACAuth.emptyBodyHashHex
        let sig = auth.sign(timestampMs: ts, method: "GET", path: path, bodyHashHex: bodyHash)
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(bodyHash, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                return .failure(FetchError("http \(code)"))
            }
            let page = try JSONDecoder().decode(PeerEndpointsPage.self, from: data)
            return .success(page)
        } catch {
            return .failure(FetchError("\(error)"))
        }
    }
}

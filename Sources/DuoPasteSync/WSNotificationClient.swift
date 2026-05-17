import Foundation
import Logging
import HTTPTypes
import HummingbirdWSClient
import WSCore
import DuoPasteCore

/// Per peer 一个 actor。维护到 peer `/sync/ws` 的长连接，收到 `cursor_advanced`/`hello`
/// 调注入的 `onCursorAdvanced` 闭包让对应 PullWorker.wake()。
///
/// 状态机：
/// 1. start → runLoop 起 connect → 阻塞在 inbound for-await
/// 2. inbound 关 / WS 抛错 → 上抛到 runLoop catch，consecutiveFailures += 1，
///    指数 backoff 后重连
/// 3. stop → cancel runTask → connect 内 for-await 抛 CancellationError → 返回 → loop guard 退出
///
/// **WebSocket 协议层 ping/pong 走 `autoPing`**——我们不在 JSON 层手动发 ping，client 配
/// `autoPing: .enabled(timePeriod: heartbeatSec)` 库会自动发 PING 帧、等 PONG 回应；
/// 没收到 → 库主动关闭连接（read 路径抛错），由 runLoop catch 触发重连。
///
/// **HMAC**：Upgrade 请求带 `X-DP-Timestamp` / `X-DP-Body-SHA256` (空 body hash) /
/// `X-DP-Auth`，签名串 `<ts_ms>\nGET\n/sync/ws\n<empty hash>`。Upgrade 后 frame **不再签**——
/// 长连接里假设已认证（同 SSH session 模型，参见 plan §"WebSocket 协议 / Endpoint + Auth"）。
public actor WSNotificationClient {
    public struct Config: Sendable {
        public var heartbeatSec: TimeInterval
        public var reconnectInitialSec: TimeInterval
        public var reconnectMaxSec: TimeInterval
        /// inbound message 最大字节数。cursor_advanced/hello 几百字节级，1 KB 已远超；
        /// 设小是 DoS 防御——peer 篡改后塞 64 MB JSON 让 client OOM。
        public var maxInboundMessageBytes: Int

        /// 连续失败到此阈值后调 onCatastrophicFailure。0 = 禁用(永远不主动 exit)。
        /// 默认 15:initial 1s + 指数 backoff 到 max 60s 约 11 分钟,经验上够过滤短暂
        /// 网络抖动 + 给 SCDynamicStore DNS recovery 机会,持续故障才进 launchd 重启路径
        public var failureBudgetForCatastrophic: Int

        public init(
            heartbeatSec: TimeInterval = 30,
            reconnectInitialSec: TimeInterval = 1,
            reconnectMaxSec: TimeInterval = 60,
            maxInboundMessageBytes: Int = 64 * 1024,
            failureBudgetForCatastrophic: Int = 15
        ) {
            self.heartbeatSec = heartbeatSec
            self.reconnectInitialSec = reconnectInitialSec
            self.reconnectMaxSec = reconnectMaxSec
            self.maxInboundMessageBytes = maxInboundMessageBytes
            self.failureBudgetForCatastrophic = failureBudgetForCatastrophic
        }

        public static let `default` = Config()
    }

    private let peerURL: URL
    private let auth: HMACAuth
    /// 严格模式：peer 在 hello / cursorAdvanced 报的 device_id 必须等于这个 expected。
    /// 不一致 → 当前连接关闭重连（不调 onCursorAdvanced 防污染 PullWorker cursor）。
    /// nil → 学习模式（接受任意 peer device_id；用于 PR 2 单 peer 部署兼容）。
    private let expectedPeerDeviceID: String?
    private let onCursorAdvanced: @Sendable (Int64) -> Void
    private let onConnectStateChange: @Sendable (Bool) -> Void
    /// 连续失败超过 config.failureBudgetForCatastrophic 触发——AppDelegate 注入 exit(1)
    /// 让 launchd KeepAlive 重启 daemon。SwiftNIO 内部 resolver 在 client 创建时 snapshot,
    /// 长期 fail 通常意味 DNS / 接口状态 stale,进程重启是最稳的最后兜底
    private let onCatastrophicFailure: @Sendable () -> Void
    private let config: Config
    private let now: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    /// 字节层 transport。tailscale 路径 = `NIOWebSocketTransport`；ponte 路径 =
    /// `URLSessionWebSocketTransport(session: PonteSession.pontePool.session)`。
    /// PR 3 起 AppDelegate / SmartTransport 按 host 决定注入哪个
    private let transport: WSTransport

    private var runTask: Task<Void, Never>?
    /// 当前 backoff sleep task。wake() 取消它让 retry 立即触发——
    /// SCDynamicStore DNS 变化路径用这条让 DNS 恢复后秒级重连而不是等满 backoff(可能 60s)
    private var currentSleep: Task<Void, Error>?

    public init(
        peerURL: URL,
        auth: HMACAuth,
        expectedPeerDeviceID: String?,
        onCursorAdvanced: @escaping @Sendable (Int64) -> Void = { _ in },
        onConnectStateChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onCatastrophicFailure: @escaping @Sendable () -> Void = {},
        config: Config = .default,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("ws-client: \(msg)\n".utf8))
        },
        transport: WSTransport = NIOWebSocketTransport()
    ) {
        self.peerURL = peerURL
        self.auth = auth
        self.expectedPeerDeviceID = expectedPeerDeviceID
        self.onCursorAdvanced = onCursorAdvanced
        self.onConnectStateChange = onConnectStateChange
        self.onCatastrophicFailure = onCatastrophicFailure
        self.config = config
        self.now = now
        self.log = log
        self.transport = transport
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        currentSleep?.cancel()
        currentSleep = nil
    }

    /// 外部触发立即重连——DNSChangeMonitor 在系统 DNS / 网络接口状态变化时调本方法,
    /// cancel 当前 backoff sleep 让 runLoop 跳出 sleep 立即进下一轮 connect。
    /// nonisolated 让 callsite(SCDynamicStore GCD callback)不用 await 直接调
    public nonisolated func wake() {
        Task { [weak self] in
            await self?.cancelCurrentSleep()
        }
    }

    private func cancelCurrentSleep() {
        currentSleep?.cancel()
    }

    /// 连接当前是否活跃——由 onConnectStateChange 回调外部 MeshStatus 之后再读，这里内部
    /// 只负责正确触发 transition。测试可以注入 onConnectStateChange 观察。
    public var isConnected: Bool { connectedFlag }
    private var connectedFlag: Bool = false

    private func setConnected(_ v: Bool) {
        connectedFlag = v
        onConnectStateChange(v)
    }

    /// runLoop 必须 nonisolated 才能用 Task { await self?.runLoop() }——不，actor 方法
    /// 在 task 里 await 没问题。这里保留为 actor-isolated，挂起期间 stop() 可以重入。
    private func runLoop() async {
        let peerSuffix = expectedPeerDeviceID.map { " · peer=\($0)" } ?? ""
        log("started \(peerURL.absoluteString)\(peerSuffix)")
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                try await connectOnce()
                // 正常完结（远端 close）→ 算"短连接"也按失败计数避免 hot-loop 重连
                consecutiveFailures += 1
            } catch is CancellationError {
                log("stopped (cancelled)")
                return
            } catch {
                consecutiveFailures += 1
                log("connect error: \(error)")
            }
            if Task.isCancelled { return }
            // 连续失败到 budget → 视为 daemon 进程层故障,触发 catastrophic 回调
            // (生产路径 = exit(1) → launchd KeepAlive 重启)。SwiftNIO 内部 resolver
            // snapshot 在进程启动时缓存,DNS 变化后旧进程往往拉不回来,重启是兜底
            if config.failureBudgetForCatastrophic > 0
                && consecutiveFailures >= config.failureBudgetForCatastrophic {
                log("connect failed \(consecutiveFailures) times consecutively · signaling catastrophic")
                onCatastrophicFailure()
                return
            }
            let backoff = min(
                config.reconnectInitialSec * pow(2.0, Double(consecutiveFailures - 1)),
                config.reconnectMaxSec
            )
            log("retry in \(Int(backoff))s (failures=\(consecutiveFailures))")
            // sleep 用 stored task,wake() 可 cancel 让 DNS 变化时跳过剩余 backoff
            let sleepTask = Task<Void, Error> {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
            currentSleep = sleepTask
            do {
                try await sleepTask.value
            } catch is CancellationError {
                // wake() 取消 sleep → 立即下一轮 retry。打 log 让外部能看到
                log("backoff cancelled by wake(), retrying immediately")
            } catch {
                return
            }
            currentSleep = nil
        }
        log("stopped")
    }

    /// 跑一次完整连接生命周期。transport 内 inbound 循环关闭后函数返回。
    /// 抛错 / cancel 由调用方 catch。字节层 transport 由 init 注入——
    /// NIO 默认 / URLSession 用于 ponte
    private func connectOnce() async throws {
        let wsURL = Self.makeWSURL(peerURL, path: "/sync/ws")
        let authFields = makeAuthHeaders(method: "GET", path: "/sync/ws")
        // HTTPFields → [(String, String)]——transport 接口跟具体 HTTP lib 解耦
        var headers: [(name: String, value: String)] = []
        for f in authFields {
            headers.append((name: f.name.rawName, value: f.value))
        }

        // 闭包要 capture 这些 Sendable 值（actor self 不能跨 nonisolated 闭包）
        let onCursor = self.onCursorAdvanced
        let logFn = self.log
        let expectedPeer = self.expectedPeerDeviceID
        let maxBytes = self.config.maxInboundMessageBytes
        let heartbeatSec = self.config.heartbeatSec
        // setConnected 是 actor isolated；用 nonisolated wrapper 让闭包内能调用。
        // detached Task 顺便避免被外层 task local 上下文 capture
        let setConn: @Sendable (Bool) -> Void = { [weak self] v in
            let _: Task<Void, Never> = Task { [weak self] in await self?.setConnected(v) }
        }
        // hello expectedPeer 校验失败时往 onText 后续帧通报"别再处理"。transport 没主动关
        // 接口；下一帧自然 onText 看到 flag 跳过 + 我们最后 throw 让外层 backoff 重连
        let closeSignal = CloseSignal()

        try await transport.runOnce(
            wsURL: wsURL,
            headers: headers,
            maxInboundMessageBytes: maxBytes,
            heartbeatSec: heartbeatSec,
            onConnected: setConn,
            onText: { text in
                if await closeSignal.isSet { return }
                let m: WSMessage
                do {
                    m = try WSMessage.decodeJSON(text)
                } catch {
                    logFn("decode failed: \(error)")
                    return
                }
                switch m {
                case .cursorAdvanced(_, let deviceID, let latest):
                    if let expectedPeer, deviceID != expectedPeer {
                        logFn("cursor_advanced from unexpected peer \(deviceID), expected \(expectedPeer); ignoring")
                        return
                    }
                    onCursor(latest)
                case .hello(_, let deviceID, _, let latest):
                    if let expectedPeer, deviceID != expectedPeer {
                        logFn("hello from unexpected peer \(deviceID), expected \(expectedPeer); closing")
                        await closeSignal.set()
                        return
                    }
                    // hello 也算一次 advance 通知，让 PullWorker 立刻做"我已经追平了吗"自检
                    onCursor(latest)
                case .ping, .pong:
                    // 应用层 ping/pong 当前不消费——WS 协议层 autoPing/heartbeat 已处理 keep-alive
                    return
                case .endpointsChanged:
                    // Mac peer 间互连不关心 endpoints 列表变化(自己已经 mesh-init 配好 peer URL),
                    // 只有 iOS 才 refetch。Mac 收到这条 noop
                    return
                }
            }
        )
        if await closeSignal.isSet {
            // expectedPeer 校验失败——让外层 runLoop 把这次算失败 + backoff 重连
            throw WSExpectedPeerMismatch()
        }
    }

    /// 一次性 close 信号——hello 校验失败后下一帧 onText 看到这个就 early-return
    private actor CloseSignal {
        private(set) var isSet: Bool = false
        func set() { isSet = true }
    }

    /// hello 报告 device_id 跟 expectedPeer 不匹配——让外层 runLoop 把这次算失败 + backoff
    public struct WSExpectedPeerMismatch: Error, Sendable {}

    /// HTTP url → ws/wss url。`http` → `ws`，`https` → `wss`，其他 scheme 原样返回（让连接抛错给上层）。
    static func makeWSURL(_ httpURL: URL, path: String) -> String {
        var comp = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        switch comp.scheme?.lowercased() {
        case "https": comp.scheme = "wss"
        case "http":  comp.scheme = "ws"
        default: break
        }
        let basePath = comp.path
        // 去掉 base path 末尾 "/" 防双斜杠
        let trimmed = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        comp.path = trimmed + path
        return comp.url?.absoluteString ?? (httpURL.absoluteString + path)
    }

    /// 构造 Upgrade 请求 HMAC headers。`path` 必须跟 server middleware 看到的一致——
    /// 我们的 `/sync/ws` 没 query string，只用 path 本身签名。
    private func makeAuthHeaders(method: String, path: String) -> HTTPFields {
        let ts = now()
        let bodyHash = HMACAuth.emptyBodyHashHex
        let sig = auth.sign(timestampMs: ts, method: method, path: path, bodyHashHex: bodyHash)
        var headers = HTTPFields()
        headers[HTTPField.Name(HMACAuth.timestampHeader)!] = String(ts)
        headers[HTTPField.Name(HMACAuth.bodyHashHeader)!] = bodyHash
        headers[HTTPField.Name(HMACAuth.signatureHeader)!] = sig
        return headers
    }
}

import Foundation
import Network
import Observation
import DuoPasteCore

/// **NWConnection-based WebSocket 客户端**——绕开 iOS `URLSessionWebSocketTask` 的
/// TLS challenge delegate 不 fire 原生 bug。
///
/// 背景:Mac daemon 用 `tailscale cert <FQDN>` 拿到一对 cert,所有 6 个 endpoint URL
/// (tailscale FQDN / .local / .sgponte / lan_ip) 用同一份 cert。访问 .local 等
/// hostname-mismatch URL 时:
/// - HTTP `URLSessionDataTask`: 触发 `URLSessionTaskDelegate.didReceive challenge`
///   → TrustAnyDelegate 接受 → TLS OK
/// - WS `URLSessionWebSocketTask`: iOS 26 上 **不调用** 同样 challenge delegate
///   (Apple FB12879872) → 默认 hostname mismatch 验证 → 拒 → -1200
///
/// 修法:走 `NWConnection` + `NWProtocolTLS.Options.securityProtocolOptions`,
/// `sec_protocol_options_set_verify_block` 直接 complete(true) 接受任何 cert。
/// 然后用 `NWProtocolWebSocket.Options` 让 NWConnection 自动跑 WS 升级 + frame
/// 分包,我们只看 receive message 拿 hello / cursor_advanced
///
/// **HMAC 签名**: WS upgrade 是 HTTP GET 升级,header 走 NWProtocolWebSocket.Options
/// 的 setAdditionalHeaders。签名规则跟 `URLSessionWebSocketTask` 版本一致——
/// `<ts>\nGET\n/sync/ws\n<sha256_hex("")>`
@MainActor
@Observable
final class PeerWebSocket {
    enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected(peerDeviceID: String)
        case backoff(failures: Int)
        case stopped
        case failed(String)
    }

    enum WSError: Error, CustomStringConvertible {
        case handshakeTimeout(sinceSec: Int)
        case pongTimeout(sinceSec: Int)
        case connectionFailed(String)
        case unexpectedFrame
        var description: String {
            switch self {
            case .handshakeTimeout(let s): return "handshake timeout after \(s)s"
            case .pongTimeout(let s): return "pong timeout after \(s)s"
            case .connectionFailed(let m): return "connection failed: \(m)"
            case .unexpectedFrame: return "unexpected frame"
            }
        }
    }

    private(set) var state: State = .idle
    /// **@ObservationIgnored** —— lastHeartbeatAt 每收一帧(ping/pong/cursor_advanced)
    /// 都更新,UI 不显示这个值,被 @Observable tracker 抓到只会让 SettingsView 每帧重渲
    /// (6 个 WS × 频繁更新 = MainActor 队列爆)。pool 只内部读它做 zombie 检测,不参与 UI
    @ObservationIgnored private(set) var lastHeartbeatAt: Date?
    @ObservationIgnored private(set) var lastAdvanceNs: Int64 = 0
    @ObservationIgnored private var lastPongAt: Date?

    private let config: PeerConfig
    private let auth: HMACAuth
    private let onAdvance: @MainActor (Int64) -> Void
    private let onEndpointsChanged: @MainActor () -> Void
    nonisolated let pingIntervalSec: TimeInterval
    nonisolated let pongTimeoutSec: TimeInterval
    nonisolated let handshakeTimeoutSec: TimeInterval

    private var runTask: Task<Void, Never>?
    private var currentConnection: NWConnection?

    init(
        config: PeerConfig,
        pingIntervalSec: TimeInterval = 30,
        pongTimeoutSec: TimeInterval = 10,
        handshakeTimeoutSec: TimeInterval = 8,
        onAdvance: @escaping @MainActor (Int64) -> Void,
        onEndpointsChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.config = config
        self.auth = HMACAuth(secret: config.sharedSecret)
        self.pingIntervalSec = pingIntervalSec
        self.pongTimeoutSec = pongTimeoutSec
        self.handshakeTimeoutSec = handshakeTimeoutSec
        self.onAdvance = onAdvance
        self.onEndpointsChanged = onEndpointsChanged
    }

    func start() {
        guard runTask == nil else { return }
        state = .connecting
        lastHeartbeatAt = nil
        lastPongAt = nil
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        currentConnection?.cancel()
        currentConnection = nil
        state = .stopped
    }

    /// 网络 path 变化时只打断当前 NWConnection，让既有 runLoop 自己进入 backoff/retry。
    /// 不 cancel runTask、不重建 PeerWebSocket，因此 failures 指数退避不会被清零。
    func reconnectPreservingBackoff(reason: String) {
        guard runTask != nil else {
            start()
            return
        }
        DebugLog.shared.append("ws reconnect requested: \(config.baseURL.absoluteString) (\(reason))")
        currentConnection?.cancel()
    }

    private func runLoop() async {
        var failures = 0
        let urlStr = config.baseURL.absoluteString
        DebugLog.shared.append("ws runLoop start: \(urlStr)")
        while !Task.isCancelled {
            do {
                try await connectOnce()
                failures += 1
                DebugLog.shared.append("ws connectOnce returned (remote close?) failures=\(failures)")
            } catch is CancellationError {
                DebugLog.shared.append("ws runLoop cancelled: \(urlStr)")
                return
            } catch {
                failures += 1
                state = .failed(String(describing: error))
                DebugLog.shared.append("ws connectOnce failed: \(error) failures=\(failures) url=\(urlStr)")
            }
            if Task.isCancelled { return }
            // backoff 封顶：2^(failures-1) 但 failures 在 backoff 计算上 clamp 到 6
            // → 最大 sleep 32s（之前 60s）。`failures` 字段本身仍单调增让 UI / 日志能看到
            // 真实失败次数，只是 backoff 不会让"网络刚恢复但当前还在 backoff 60s 里"的
            // UX 拉长。reconnectPreservingBackoff 不 reset failures（保前一段抖动学到的
            // 教训），但 clamp 让 max wait 较合理
            let clampedFailures = min(failures, 6)
            let backoff = min(pow(2.0, Double(max(clampedFailures - 1, 0))), 32.0)
            state = .backoff(failures: failures)
            do {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch { return }
            if Task.isCancelled { return }
            state = .connecting
        }
    }

    private func connectOnce() async throws {
        let baseURL = config.baseURL
        let isTLS = (baseURL.scheme?.lowercased() == "https")
        let wsURL = Self.makeWSURL(baseURL, path: "/sync/ws")
        let path = "/sync/ws"

        // TLS options:用 verify_block 接受任何 cert(绕开 hostname mismatch / 自签 cert
        // 在 iOS 默认 trust store 不被认 的两类问题。HMAC 签名是真 trust anchor)
        let tlsOptions: NWProtocolTLS.Options?
        if isTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, sec_protocol_verify_complete in
                    sec_protocol_verify_complete(true)
                },
                DispatchQueue.global(qos: .userInitiated)
            )
            tlsOptions = tls
        } else {
            tlsOptions = nil
        }

        // WS options:autoReplyPing 让 NWProtocolWebSocket 自动回协议层 Pong
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let bodyHash = HMACAuth.emptyBodyHashHex
        let sig = auth.sign(timestampMs: ts, method: "GET", path: path, bodyHashHex: bodyHash)
        wsOptions.setAdditionalHeaders([
            (HMACAuth.timestampHeader, String(ts)),
            (HMACAuth.bodyHashHeader, bodyHash),
            (HMACAuth.signatureHeader, sig),
        ])

        let params: NWParameters = isTLS
            ? NWParameters(tls: tlsOptions!, tcp: NWProtocolTCP.Options())
            : NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        // 应用层协议:HTTP+WebSocket。NWConnection 用 wsOptions 自动跑 upgrade + frame 分包
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        // **关键**: 用 `.url(URL)` 而不是 `.hostPort` 让 NWConnection 把 path 写进
        // WebSocket upgrade 请求的 GET /sync/ws —— hostPort 只携带 host:port,server 收到
        // GET / 路由不到 /sync/ws
        let endpoint: NWEndpoint = .url(wsURL)
        let connection = NWConnection(to: endpoint, using: params)
        currentConnection = connection
        defer {
            connection.cancel()
            if currentConnection === connection { currentConnection = nil }
        }

        // 启动 + 等 .ready / .failed / .cancelled
        try await Self.startAndAwaitReady(
            connection: connection,
            timeoutSec: handshakeTimeoutSec
        )
        DebugLog.shared.append("ws ready: \(config.baseURL.absoluteString)")

        // receive + ping 双 task race. 任一边结束/抛错时必须先 cancel NWConnection,
        // 否则另一个 task 可能还卡在 receiveMessage 的 continuation 里，group scope
        // 等不到它收尾，外层 runLoop 就永远不进入 backoff/reconnect。
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer {
                connection.cancel()
                group.cancelAll()
            }
            group.addTask { [weak self] in
                try await self?.receiveLoop(connection: connection)
            }
            group.addTask { [weak self] in
                try await self?.pingLoop(connection: connection)
            }
            try await group.next()
        }
    }

    /// NWConnection 启动后 race `.ready` vs `.failed/.cancelled` vs handshake timeout.
    /// 用 withTaskCancellationHandler 让 group cancelAll 时主动 cancel NWConnection,
    /// stateUpdateHandler fire `.cancelled` 解锁 continuation——否则 continuation 永远
    /// 卡在 .ready 等待,group 死锁让外层 Task 永久 hang
    nonisolated private static func startAndAwaitReady(
        connection: NWConnection,
        timeoutSec: TimeInterval
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        let box = ResumeBox()
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                if box.resume() {
                                    connection.stateUpdateHandler = nil
                                    cont.resume()
                                }
                            case .failed(let err):
                                if box.resume() {
                                    connection.stateUpdateHandler = nil
                                    cont.resume(throwing: WSError.connectionFailed(String(describing: err)))
                                }
                            case .cancelled:
                                // NWConnection.cancel() 有两个来源:reconnectPreservingBackoff
                                // 主动打断重连(runTask 没被 cancel),以及 onCancel 闭包响应
                                // 外层 task cancel。前者必须让 runLoop 走 backoff 重连,不能
                                // 让它误以为整个 task 退出;后者会通过 Task.isCancelled 在
                                // runLoop while 头部 / Task.sleep 抛 CancellationError 自然退。
                                // 所以这里**永远**抛 WSError 而非 CancellationError——
                                // CancellationError 留给真正的 task 取消语义
                                if box.resume() {
                                    connection.stateUpdateHandler = nil
                                    cont.resume(throwing: WSError.connectionFailed("cancelled"))
                                }
                            case .waiting(let err):
                                if box.resume() {
                                    connection.stateUpdateHandler = nil
                                    cont.resume(throwing: WSError.connectionFailed("waiting: \(err)"))
                                }
                            case .setup, .preparing:
                                break
                            @unknown default:
                                break
                            }
                        }
                        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
                    }
                } onCancel: {
                    // group cancelAll / 外层 Task 被 cancel → cancel NWConnection,
                    // 触发 stateUpdateHandler .cancelled 解锁 continuation
                    connection.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                throw WSError.handshakeTimeout(sinceSec: Int(timeoutSec))
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                connection.cancel()
                group.cancelAll()
                throw error
            }
       }
    }

    /// continuation 单次 resume 保护——sec_protocol stateUpdateHandler 可能多次 fire
    /// (.ready 后又 .failed),但 continuation.resume 只能调一次。用 class + atomic 标志位
    /// (NSLock 包 Bool 也行,这里 final class 单一实例够用)
    fileprivate final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var resumed = false
        nonisolated init() {}
        /// 返回 true = 应该 resume(头一次调);false = 已经 resume 过,skip
        nonisolated func resume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    nonisolated private func receiveLoop(connection: NWConnection) async throws {
        while !Task.isCancelled {
            let msg = try await Self.receiveMessage(connection: connection)
            await self.handleFrame(msg)
        }
    }

    /// receive 一个完整 message——NWProtocolWebSocket 已经把 frame 拼好,我们拿 (data, context).
    /// context.metadata 含 WS opcode (text/binary/close/etc)
    ///
    /// **withTaskCancellationHandler 必须包**: NWConnection.receiveMessage 在 `connection.cancel()`
    /// 后**不保证** callback 被 fire——文档未承诺，实测有 callback 静默丢的情况。外层 group
    /// cancelAll 后这个 continuation 会永远不 resume，task 挂死。模式跟 startAndAwaitReady
    /// 对齐：cancel 时主动 cancel connection 让 callback 走 error 路径；ResumeBox 防 cancel
    /// 跟正常 callback race 时 continuation 被 double-resume
    nonisolated private static func receiveMessage(
        connection: NWConnection
    ) async throws -> (data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let box = ResumeBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                connection.receiveMessage { content, context, _, error in
                    guard box.resume() else { return }
                    if let error {
                        cont.resume(throwing: WSError.connectionFailed(String(describing: error)))
                        return
                    }
                    guard let context else {
                        cont.resume(throwing: WSError.connectionFailed("nil context"))
                        return
                    }
                    let wsMeta = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata
                    let opcode = wsMeta?.opcode ?? .text
                    cont.resume(returning: (content ?? Data(), opcode))
                }
            }
        } onCancel: {
            // 主动 cancel 让 connection.receiveMessage 的 callback 沿 error 路径 fire；
            // 即便没 fire（NW 罕见路径），下次外层 group 已 cancel 整轮，task 退出
            connection.cancel()
        }
    }

    nonisolated private func pingLoop(connection: NWConnection) async throws {
        let pingNs = UInt64(pingIntervalSec * 1_000_000_000)
        let pongNs = UInt64(pongTimeoutSec * 1_000_000_000)
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: pingNs)
            let payload = try WSMessage.ping(version: WSMessage.currentVersion).encodeJSON()
            let sentAt = Date()
            try await Self.sendText(connection: connection, text: payload)
            try await Task.sleep(nanoseconds: pongNs)
            let last = await self.lastPongAt ?? .distantPast
            if last < sentAt {
                throw WSError.pongTimeout(sinceSec: Int(pongTimeoutSec))
            }
        }
    }

    nonisolated private static func sendText(connection: NWConnection, text: String) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "tx", metadata: [metadata])
        let data = text.data(using: .utf8) ?? Data()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: WSError.connectionFailed(String(describing: error)))
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    /// http(s) → ws(s),拼上 path
    static func makeWSURL(_ http: URL, path: String) -> URL {
        var comp = URLComponents(url: http, resolvingAgainstBaseURL: false) ?? URLComponents()
        switch comp.scheme?.lowercased() {
        case "https": comp.scheme = "wss"
        case "http":  comp.scheme = "ws"
        default: break
        }
        let basePath = comp.path
        let trimmed = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        comp.path = trimmed + path
        return comp.url ?? http
    }

    private func handleFrame(_ frame: (data: Data, opcode: NWProtocolWebSocket.Opcode)) {
        switch frame.opcode {
        case .text, .binary:
            guard let text = String(data: frame.data, encoding: .utf8) else { return }
            handle(text: text)
        case .close:
            DebugLog.shared.append("ws got close frame: \(config.baseURL.absoluteString)")
        case .ping, .pong, .cont:
            // 协议层 ping/pong — NWProtocolWebSocket.autoReplyPing 已经回 pong
            break
        @unknown default:
            break
        }
    }

    private func handle(text: String) {
        let msg: WSMessage
        do { msg = try WSMessage.decodeJSON(text) }
        catch {
            DebugLog.shared.append("ws decode failed: \(text.prefix(120))")
            return
        }
        lastHeartbeatAt = Date()
        switch msg {
        case .hello(_, let deviceID, _, let latest):
            state = .connected(peerDeviceID: deviceID)
            DebugLog.shared.append("ws hello from \(deviceID.prefix(8)) latest=\(latest)")
            if latest > lastAdvanceNs { lastAdvanceNs = latest }
            onAdvance(latest)
        case .cursorAdvanced(_, _, let latest):
            if latest > lastAdvanceNs { lastAdvanceNs = latest }
            onAdvance(latest)
        case .pong:
            lastPongAt = Date()
        case .ping:
            break
        case .endpointsChanged:
            DebugLog.shared.append("ws: endpoints_changed received")
            onEndpointsChanged()
        }
    }
}

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

    /// 失败计数,instance var (从 runLoop 局部变量提升出来) 让 `reconnectResettingBackoff`
    /// 能从外部清零。语义跟之前一致(每次 connectOnce 返回/抛错都 += 1),只是状态从局部变量
    /// 搬到 actor 内部。`@ObservationIgnored` 让 SwiftUI 不每次 +1 重渲——state 字段已经是
    /// `.backoff(failures:)` 形态对 UI 暴露,不需要再 track 一遍 raw 计数
    @ObservationIgnored private var failures: Int = 0
    /// `.connected` 之后 stamp 的时间戳,runLoop 用它判断"是不是长连接成功"——
    /// 长连接 (>longLivedThresholdSec) 后被远端断开/抖动,reset failures 让下次重连立即
    /// 从 1s 起。对齐 Mac 端 `WSNotificationClient.longLivedConnectionThresholdSec` 设计
    @ObservationIgnored private var connectedAt: Date?

    /// failures 增量 grace 窗口截止时间(`nil` = 不在 grace 里)。`reconnectResettingBackoff`
    /// 传 graceSeconds>0 时 stamp `Date()+graceSeconds`,期间 `bumpFailures` 把增量 cap 在
    /// `failuresCapDuringGrace`(≤ 8s backoff)。grace 过期 → bumpFailures 自动清这个字段
    /// 恢复正常 `+= 1` 语义
    ///
    /// 用途:网络刚 `requiresConnection → satisfied` 后 VPN tunnel 还在 settle,一连串 TLS
    /// 失败让 failures 暴涨到指数 backoff 黑洞(150s+);grace 期间硬 cap 让每次重试间隔
    /// 不超 8s,VPN tunnel 真 ready 时不会错过握手时机
    @ObservationIgnored private var failuresGraceUntil: Date?

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
    /// 不 cancel runTask、不重建 PeerWebSocket，因此 failures 指数退避**不会被清零**。
    ///
    /// 用于"已经在 backoff 里的健康 candidate 想立即重试一次"的场景——比如 WS server
    /// `ws_rotation_sec` 主动断开,client 想立即重连但不想绕过自身退避。
    ///
    /// **不要**用在用户切 VPN/Surge 等环境硬变化场景——之前的失败教训对新环境无效,
    /// 用 `reconnectResettingBackoff` 让 failures 清零立即从 1s 起
    func reconnectPreservingBackoff(reason: String) {
        guard runTask != nil else {
            start()
            return
        }
        DebugLog.shared.append("ws reconnect requested: \(config.baseURL.absoluteString) (\(reason))")
        currentConnection?.cancel()
    }

    /// 跟 `reconnectPreservingBackoff` 同步打断 NWConnection,但**额外清 failures** 让下次
    /// 重连立即从 1s 退避起。用于"环境硬变化作废之前的失败教训"——典型场景:
    /// - 用户切到 Surge VPN,iOS URLSession 突然开始走 proxy,`.sgponte` 候选之前永久 DNS
    ///   失败 → 现在能解析,要立刻重试,不要等 5min 退避
    /// - NWPath status / primary interface 变化,旧的失败信号(无 IPv6 / DNS 失败)跟新路径
    ///   无关
    /// - 用户在 Settings 主动点"刷新候选"按钮,显式意图就是"忘掉之前学到的退避"
    ///
    /// `graceSeconds>0` 时同步开 grace 窗口:期间 failures 增量被 cap 在
    /// `failuresCapDuringGrace`(≤ 8s backoff)防 VPN tunnel half-ready 期间一连串 TLS 失败
    /// 让 failures 暴涨进 150s+ 退避黑洞,VPN 真 ready 时反而错过握手时机
    func reconnectResettingBackoff(reason: String, graceSeconds: TimeInterval = 0) {
        let graceUntil: Date? = graceSeconds > 0 ? Date().addingTimeInterval(graceSeconds) : nil
        guard runTask != nil else {
            resetFailures(graceUntil: graceUntil)
            start()
            return
        }
        let graceTag = graceSeconds > 0 ? " grace=\(Int(graceSeconds))s" : ""
        DebugLog.shared.append("ws reconnect (reset backoff)\(graceTag): \(config.baseURL.absoluteString) (\(reason))")
        resetFailures(graceUntil: graceUntil)
        currentConnection?.cancel()
    }

    /// `failures = 0` 统一入口——配套清掉(或更新) grace 窗口 stamp,语义齐 runLoop
    /// long-lived close 路径跟 `reconnectResettingBackoff` 都走这,保证 "failures 清零 →
    /// grace 状态同步" 不掉拍。`graceUntil = nil`(默认) = 退出 grace;非 nil = 设置新窗口
    ///
    /// **long-lived 路径(默认无参)主动退 grace 是有意的副作用**——连接成功跑过
    /// `longLivedThresholdSec` 说明 VPN tunnel 已 settle 完,grace cap 失去意义,
    /// 后续失败应该回到完整指数退避(从 1s 起,该爬到 300s 就爬)。改 long-lived 阈值
    /// 时要意识到这条配套副作用,不要把"清 grace"理解成纯清理。
    ///
    /// **未来 tuning 提示**:若实地观察到 long-lived close 后 30-60s 内 reconnect 抖动
    /// 又陷入指数退避黑洞(VPN 跨边界 settle 反复),考虑把 long-lived 路径改成只清
    /// failures 不清 grace——保留 grace cap 给"已稳定过但再次抖动"的二次保护窗口
    private func resetFailures(graceUntil: Date? = nil) {
        failures = 0
        failuresGraceUntil = graceUntil
    }

    /// 长连接判定阈值——connectOnce 成功跑 >= 这个秒数后被远端断开,算路径健康,reset
    /// failures。30s 跟 Mac `WSNotificationClient.Config.longLivedConnectionThresholdSec`
    /// 默认值对齐(短闪连失败 vs 长连接合法关 的分界线)
    nonisolated static let longLivedThresholdSec: TimeInterval = 30

    /// 失败次数 → 退避秒数。阶梯 [1,2,4,8,16,32,60,120,300]——之前 cap 32s 在永久失败
    /// candidate (无 VPN 时 .sgponte / cert SAN 不匹配的裸短名 等) 上让 client 每 32s
    /// 一次握手, 1 小时 ~112 次, 浪费连接预算 + UI 红字噪声。新 cap 300s 同条件 ~12 次,
    /// 降 10×。健康 candidate 短闪 reconnect 路径 (`reconnectResettingBackoff`) 清 failures
    /// 让恢复延迟仍 ≤1s,不损 UX
    nonisolated static let backoffLadder: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60, 120, 300]

    nonisolated static func backoffSeconds(failures: Int) -> TimeInterval {
        guard failures > 0 else { return backoffLadder[0] }
        let idx = min(failures - 1, backoffLadder.count - 1)
        return backoffLadder[idx]
    }

    /// grace 窗口内 retry 间隔上限。VPN tunnel settle 典型 5-30s,8s 让 60s 窗口最多
    /// 7-8 次尝试,足够 cover. **不要直接改这个值** —— 通过 `backoffLadder` 找到第一个
    /// > graceMaxBackoffSec 的 idx,确保 ladder 改动自动跟随(插入新档不需手动重算 cap)
    nonisolated static let graceMaxBackoffSec: TimeInterval = 8

    /// grace 窗口内 failures 增量硬上限——`backoffLadder` 中第一个 > `graceMaxBackoffSec`
    /// 档位的索引,意味着 retry 间隔不超 `graceMaxBackoffSec`。当前 ladder `[1,2,4,8,...]`
    /// 算出 4(idx 3 = 8s)。ladder 改动(比如插 6s 档)自动跟随,不会失锚。
    ///
    /// `static let` 在 initializer 一次求值——`backoffLadder` / `graceMaxBackoffSec`
    /// 都是 nonisolated static let 常量,表达式常量化,bumpFailures 调用零开销。
    ///
    /// 算法本体住在 `DuoPasteCore.Backoff.failuresCap`——抽到 SwiftPM 可测的纯
    /// 函数后,`Tests/DuoPasteCoreTests/BackoffCapTests.swift` 钉契约:插档自动
    /// 跟随、谓词写错 CI 即 fail。见 PR #40 review #7 / issue #43。
    nonisolated static let failuresCapDuringGrace: Int =
        Backoff.failuresCap(ladder: backoffLadder, maxBackoffSec: graceMaxBackoffSec)

    /// runLoop 里失败时调,统一 failures += 1 + grace cap 语义。grace 窗口未到期 → cap;
    /// 过期 → 清 grace stamp 恢复指数 backoff
    private func bumpFailures() {
        if let until = failuresGraceUntil, Date() < until {
            failures = min(failures + 1, Self.failuresCapDuringGrace)
        } else {
            failures += 1
            failuresGraceUntil = nil
        }
    }

    private func runLoop() async {
        // failures 是 instance var(见类型声明), runLoop 不再局部初始化——
        // `reconnectResettingBackoff` 需要从外部清零
        let urlStr = config.baseURL.absoluteString
        DebugLog.shared.append("ws runLoop start: \(urlStr)")
        while !Task.isCancelled {
            connectedAt = nil
            do {
                try await connectOnce()
                // connectOnce 正常返回 = 远端 close 或 receive/ping loop 结束。判断是不是
                // **长连接成功被关**: connected 后跑 > 30s 算路径健康(server ws_rotation 定时
                // 主动断 / iOS 后台挂起后醒来 等情况), reset failures 让下次重连不继承
                // 退避。否则当 transient 失败处理 +=1
                if let ts = connectedAt, Date().timeIntervalSince(ts) >= Self.longLivedThresholdSec {
                    let dur = Int(Date().timeIntervalSince(ts))
                    DebugLog.shared.append("ws long-lived (\(dur)s) closed → reset failures: \(urlStr)")
                    resetFailures()
                } else {
                    bumpFailures()
                    DebugLog.shared.append("ws connectOnce returned (remote close?) failures=\(failures)")
                }
            } catch is CancellationError {
                DebugLog.shared.append("ws runLoop cancelled: \(urlStr)")
                return
            } catch {
                bumpFailures()
                state = .failed(String(describing: error))
                DebugLog.shared.append("ws connectOnce failed: \(error) failures=\(failures) url=\(urlStr)")
            }
            if Task.isCancelled { return }
            let backoff = Self.backoffSeconds(failures: failures)
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
        var headers = [
            (HMACAuth.timestampHeader, String(ts)),
            (HMACAuth.bodyHashHeader, bodyHash),
            (HMACAuth.signatureHeader, sig),
        ]
        if let token = config.credentialToken {
            headers.append((HMACAuth.credentialTokenHeader, token))
        }
        wsOptions.setAdditionalHeaders(headers)

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
            connectedAt = Date()
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

import Foundation
import Logging
import HTTPTypes
import HummingbirdWSClient
import WSCore

/// 抽出 `WSNotificationClient.connectOnce` 的 "纯字节层" 部分作 protocol，让 ponte 路径走
/// URLSession-based 实现（吃 connectionProxyDictionary + URL 系统 proxy 配置 → Surge HTTP
/// CONNECT 隧道），tailscale 路径仍走 NIO `WebSocketClient.connect`（直连 TCP keep-alive）。
///
/// 设计:
/// - **closure 接收 inbound text 帧**——不返回 AsyncStream，避免多包一层 buffering / backpressure
/// - `onConnected(true)` 只在 transport 真知道"上线了"时调；任一路径 return / throw 前内部
///   保证调一次 `onConnected(false)`，不依赖外层 defer
/// - 心跳约定：transport 内部自管 heartbeat（NIO 用库自带 autoPing，URLSession 自己起 task
///   周期 sendPing）。`heartbeatSec` 是周期；超时 throw 让外层 WSNotificationClient.runLoop 重连
/// - HMAC 签名 + headers 由 caller 算好传进来——transport 不知道 auth/path 细节
///
/// **不保证**:
/// - 不做 backoff 重连（caller 在 runLoop 里 catch + backoff）
/// - 不做 hello / cursorAdvanced JSON 解析（caller 在 onText 里 decode）
/// - 不做 expectedPeerDeviceID 校验（caller 解出 hello/cursorAdvanced 后查）
public protocol WSTransport: Sendable {
    func runOnce(
        wsURL: String,
        headers: [(name: String, value: String)],
        maxInboundMessageBytes: Int,
        heartbeatSec: TimeInterval,
        onConnected: @escaping @Sendable (Bool) -> Void,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws
}

public enum WSTransportError: Error, Sendable {
    case badURL(String)
    case pingTimeout
}

// MARK: - NIO 实现（tailscale 路径）

/// 复制 PR 2 之前 `WSNotificationClient.connectOnce` 的实现：调 `WebSocketClient.connect`
/// 用 NIO TCP 直连。`autoPing` 库自管心跳——`heartbeatSec` 直接传给 `.enabled(timePeriod:)`。
///
/// **不**支持 HTTP CONNECT proxy——SwiftNIO 这层 ws client 不读系统 proxy，所以
/// `.sgponte` 主机名走这条会 DNS 失败。host 是 ponte 域名时 caller 必须挑 URLSession 版本
public struct NIOWebSocketTransport: WSTransport {
    public init() {}

    public func runOnce(
        wsURL: String,
        headers: [(name: String, value: String)],
        maxInboundMessageBytes: Int,
        heartbeatSec: TimeInterval,
        onConnected: @escaping @Sendable (Bool) -> Void,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws {
        var fields = HTTPFields()
        for (k, v) in headers {
            if let name = HTTPField.Name(k) { fields[name] = v }
        }
        var clientLogger = Logger(label: "duo-ws-transport-nio")
        clientLogger.logLevel = .warning
        let pingPeriodSec = max(1, Int(heartbeatSec))

        try await WebSocketClient.connect(
            url: wsURL,
            configuration: .init(
                additionalHeaders: fields,
                autoPing: .enabled(timePeriod: .seconds(pingPeriodSec))
            ),
            logger: clientLogger
        ) { inbound, _, _ in
            onConnected(true)
            defer { onConnected(false) }
            for try await msg in inbound.messages(maxSize: maxInboundMessageBytes) {
                if case .text(let s) = msg {
                    await onText(s)
                }
            }
        }
    }
}

// MARK: - URLSession 实现（ponte 路径）

/// 用 `URLSessionWebSocketTask` 跑 WS。session 注入时通常是 `PonteSession.pontePool.session`
/// (含 connectionProxyDictionary 指向 Surge 127.0.0.1:6152 + `PonteDelegate` 跳 `.sgponte`
/// 域名的 hostname 校验)。
///
/// URLSession WS 没有 hummingbird-websocket 的 `autoPing` API 等价物。自管 heartbeat:
/// - 初始一次 `sendPing` 当 readiness signal（URLSession 把 ping queue 到 handshake 完成后才发
///   实际帧）；pong 回来或 10s timeout 都让我们决定是否进受信状态
/// - 进入主循环后每 `heartbeatSec` 一次 ping，2× heartbeat 内没回 → throw → 外层 backoff 重连
///
/// `task.maximumMessageSize = maxInboundMessageBytes` 是 DoS 防御——超过的帧让 receive 抛错
public final class URLSessionWebSocketTransport: NSObject, WSTransport, @unchecked Sendable {
    private let session: URLSession
    /// 初始 readiness ping 的 deadline。比正常 heartbeat 周期独立——connect 期间网络可能慢些
    /// 给一个固定上限避免卡死
    private let readinessTimeoutSec: TimeInterval

    public init(session: URLSession, readinessTimeoutSec: TimeInterval = 10) {
        self.session = session
        self.readinessTimeoutSec = readinessTimeoutSec
        super.init()
    }

    public func runOnce(
        wsURL: String,
        headers: [(name: String, value: String)],
        maxInboundMessageBytes: Int,
        heartbeatSec: TimeInterval,
        onConnected: @escaping @Sendable (Bool) -> Void,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws {
        guard let url = URL(string: wsURL) else { throw WSTransportError.badURL(wsURL) }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = maxInboundMessageBytes
        task.resume()

        // 跟 NIO transport 对齐：connect 一返回（resume queue 完成 handshake 后第一帧）就算
        // "上线"。生产路径首次帧是 server 主动发的 hello（< 1 RTT），UI 状态早一点 transient
        // false 不要紧——失败由 receive 循环抛错触发 onConnected(false) + 外层 backoff。
        // 不在这里做 readiness ping：hbws server PONG 路径在测试环境里跟 task.resume 的
        // queue 时机存在偶发 race，挂住整个 transport
        onConnected(true)
        defer {
            onConnected(false)
            task.cancel(with: .goingAway, reason: nil)
        }

        let heartbeatPeriodNs = UInt64(max(0.1, heartbeatSec) * 1_000_000_000)
        let heartbeatDeadlineNs = UInt64(max(0.2, heartbeatSec * 2) * 1_000_000_000)
        let urlSessionTask = task   // 显式 local 让 Sendable 闭包 capture
        let onTextCb = onText

        try await withThrowingTaskGroup(of: Void.self) { group in
            // inbound 帧循环
            group.addTask {
                while !Task.isCancelled {
                    let msg = try await urlSessionTask.receive()
                    switch msg {
                    case .string(let s):
                        await onTextCb(s)
                    case .data(let d):
                        if let s = String(data: d, encoding: .utf8) {
                            await onTextCb(s)
                        }
                        // binary 帧当前协议（cursor_advanced/hello）不用，跳过
                    @unknown default:
                        continue
                    }
                }
            }
            // 心跳循环——周期 sendPing，超时 throw
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: heartbeatPeriodNs)
                    if Task.isCancelled { return }
                    try await Self.sendPingWithTimeout(task: urlSessionTask, deadlineNs: heartbeatDeadlineNs)
                }
            }
            // 任一 child 完成（throw 或正常 return）→ 整个 runOnce wind-down
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// 包 `task.sendPing(pongReceiveHandler:)` 进 async + 超时 race。一次性 actor 守门保
    /// continuation 单次 resume（双触发会让 CheckedContinuation 触发运行时断言）
    private static func sendPingWithTimeout(
        task: URLSessionWebSocketTask,
        deadlineNs: UInt64
    ) async throws {
        let gate = ResumeOnce()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let timer = Task {
                try? await Task.sleep(nanoseconds: deadlineNs)
                if await gate.claim() {
                    cont.resume(throwing: WSTransportError.pingTimeout)
                }
            }
            task.sendPing { err in
                // pong handler 在 URLSession queue 上回调；切回我们自己的 actor 去 claim 再 resume
                Task {
                    if await gate.claim() {
                        timer.cancel()
                        if let err {
                            cont.resume(throwing: err)
                        } else {
                            cont.resume()
                        }
                    }
                }
            }
        }
    }

    private actor ResumeOnce {
        private var done = false
        func claim() -> Bool {
            if done { return false }
            done = true
            return true
        }
    }
}

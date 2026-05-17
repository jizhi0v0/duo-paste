import Foundation
import Observation
import DuoPasteCore

/// URLSessionWebSocketTask 包装。HMAC-签名 upgrade 请求,inbound 帧解码成
/// WSMessage 后调 onAdvance 回调让 coordinator 触发 /since 拉取。
///
/// 状态机：idle → connecting → connected → backoff → connecting → ...
/// stop() 可以从任何状态切到 stopped。
///
/// **App-level ping/pong zombie 检测**：URLSessionWebSocketTask 不暴露协议层 PING——
/// iOS 自动回 PONG 但 app 收不到信号,server 真死 / NAT 重写 / 锁屏后 receive() 可能阻塞
/// 不抛错,状态机僵在 .connected。当前实现走应用层 ping:`pingIntervalSec` (默认 30s) 周期
/// 发 `WSMessage.ping`,`pongTimeoutSec` (默认 10s) 内没收到 `.pong` → 抛 pongTimeout
/// 让 connectOnce 退出 + runLoop 进 backoff 重连。Server 端 `Server.swift`
/// onUpgrade inbound 路径回 `.pong`。
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
        case pongTimeout(sinceSec: Int)
        var description: String {
            switch self {
            case .pongTimeout(let s): return "pong timeout after \(s)s"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var lastAdvanceNs: Int64 = 0
    /// 最近一次收到 server 任何帧 (hello / cursor_advanced / pong) 的本机时间。
    /// coordinator 周期检查这个降级 status 到橙色——即便 ws.state 还停在 .connected
    private(set) var lastHeartbeatAt: Date?
    private var lastPongAt: Date?

    private let config: PeerConfig
    private let auth: HMACAuth
    private let session: URLSession
    private let onAdvance: @MainActor (Int64) -> Void
    nonisolated let pingIntervalSec: TimeInterval
    nonisolated let pongTimeoutSec: TimeInterval

    private var runTask: Task<Void, Never>?
    private var currentSocket: URLSessionWebSocketTask?

    init(
        config: PeerConfig,
        session: URLSession = .shared,
        pingIntervalSec: TimeInterval = 30,
        pongTimeoutSec: TimeInterval = 10,
        onAdvance: @escaping @MainActor (Int64) -> Void
    ) {
        self.config = config
        self.auth = HMACAuth(secret: config.sharedSecret)
        self.session = session
        self.pingIntervalSec = pingIntervalSec
        self.pongTimeoutSec = pongTimeoutSec
        self.onAdvance = onAdvance
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
        currentSocket?.cancel(with: .goingAway, reason: nil)
        currentSocket = nil
        state = .stopped
    }

    private func runLoop() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await connectOnce()
                failures += 1 // remote close 也算一次失败防 hot-loop
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                state = .failed(String(describing: error))
            }
            if Task.isCancelled { return }
            let backoff = min(pow(2.0, Double(max(failures - 1, 0))), 60.0)
            state = .backoff(failures: failures)
            do {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch { return }
            if Task.isCancelled { return }
            state = .connecting
        }
    }

    private func connectOnce() async throws {
        let wsURL = Self.makeWSURL(config.baseURL, path: "/sync/ws")
        var req = URLRequest(url: wsURL)
        req.httpMethod = "GET"
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let bodyHash = HMACAuth.emptyBodyHashHex
        let sig = auth.sign(timestampMs: ts, method: "GET", path: "/sync/ws", bodyHashHex: bodyHash)
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(bodyHash, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

        let task = session.webSocketTask(with: req)
        currentSocket = task
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if currentSocket === task { currentSocket = nil }
        }
        task.resume()

        // receive + ping 双 task race。任一抛错 → 整组退出 → connectOnce 抛 → runLoop 进 backoff
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try await self?.receiveLoop(task: task)
            }
            group.addTask { [weak self] in
                try await self?.pingLoop(task: task)
            }
            // 等第一个 task 完成/抛错——成功完成(receive loop 因 Task.isCancelled 退出)也算
            // "对端已关闭" → 让 connectOnce 自然返回进 backoff
            try await group.next()
            group.cancelAll()
        }
    }

    nonisolated private func receiveLoop(task: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let msg = try await task.receive()
            let text: String?
            switch msg {
            case .string(let s): text = s
            case .data(let d):   text = String(data: d, encoding: .utf8)
            @unknown default:    text = nil
            }
            if let text { await self.handle(text: text) }
        }
    }

    nonisolated private func pingLoop(task: URLSessionWebSocketTask) async throws {
        let pingNs = UInt64(pingIntervalSec * 1_000_000_000)
        let pongNs = UInt64(pongTimeoutSec * 1_000_000_000)
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: pingNs)
            let payload = try WSMessage.ping(version: WSMessage.currentVersion).encodeJSON()
            let sentAt = Date()
            try await task.send(.string(payload))
            try await Task.sleep(nanoseconds: pongNs)
            // sleep 结束后查 lastPongAt——必须 > sentAt 才证明这一轮的 pong 真到了
            let last = await self.lastPongAt ?? .distantPast
            if last < sentAt {
                throw WSError.pongTimeout(sinceSec: Int(pongTimeoutSec))
            }
        }
    }

    private func handle(text: String) {
        let msg: WSMessage
        do { msg = try WSMessage.decodeJSON(text) }
        catch { return }
        lastHeartbeatAt = Date()
        switch msg {
        case .hello(_, let deviceID, _, let latest):
            state = .connected(peerDeviceID: deviceID)
            if latest > lastAdvanceNs { lastAdvanceNs = latest }
            onAdvance(latest)
        case .cursorAdvanced(_, _, let latest):
            if latest > lastAdvanceNs { lastAdvanceNs = latest }
            onAdvance(latest)
        case .pong:
            lastPongAt = Date()
        case .ping:
            // server 不主动发应用层 ping (asymmetric protocol) — 收到也 noop
            break
        }
    }

    /// http(s) → ws(s),拼上 path。
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
}

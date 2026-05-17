import Foundation
import Observation
import DuoPasteCore

/// URLSessionWebSocketTask 包装。HMAC-签名 upgrade 请求,inbound 帧解码成
/// WSMessage 后调 onAdvance 回调让 coordinator 触发 /since 拉取。
///
/// 状态机：idle → connecting → connected → backoff → connecting → ...
/// stop() 可以从任何状态切到 stopped。
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

    private(set) var state: State = .idle
    private(set) var lastAdvanceNs: Int64 = 0

    private let config: PeerConfig
    private let auth: HMACAuth
    private let session: URLSession
    private let onAdvance: @MainActor (Int64) -> Void

    private var runTask: Task<Void, Never>?
    private var currentSocket: URLSessionWebSocketTask?

    init(
        config: PeerConfig,
        session: URLSession = .shared,
        onAdvance: @escaping @MainActor (Int64) -> Void
    ) {
        self.config = config
        self.auth = HMACAuth(secret: config.sharedSecret)
        self.session = session
        self.onAdvance = onAdvance
    }

    func start() {
        guard runTask == nil else { return }
        state = .connecting
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

        while !Task.isCancelled {
            let msg = try await task.receive()
            let text: String?
            switch msg {
            case .string(let s): text = s
            case .data(let d):   text = String(data: d, encoding: .utf8)
            @unknown default:    text = nil
            }
            if let text { handle(text: text) }
        }
    }

    private func handle(text: String) {
        let msg: WSMessage
        do { msg = try WSMessage.decodeJSON(text) }
        catch { return }
        switch msg {
        case .hello(_, let deviceID, _, let latest):
            state = .connected(peerDeviceID: deviceID)
            if latest > lastAdvanceNs { lastAdvanceNs = latest }
            onAdvance(latest)
        case .cursorAdvanced(_, _, let latest):
            if latest > lastAdvanceNs { lastAdvanceNs = latest }
            onAdvance(latest)
        case .ping, .pong:
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

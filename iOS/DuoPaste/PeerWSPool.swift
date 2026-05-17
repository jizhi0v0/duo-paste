import Foundation
import Observation
import DuoPasteCore

/// 多 URL 并发 WS 池。**所有 endpoint 一视同仁全开 PeerWebSocket**,任一 URL 推
/// cursor_advanced 都触发 onAdvance,任一 URL 推 endpoints_changed 都触发 onEndpointsChanged。
///
/// **设计**: 6 个 endpoint = 6 个 WS。WS 握手字节 ~12KB 总,即便 cellular 也微不足道。
/// 每个 WS 自己 backoff 重连(handshake 8s 硬超时 + 指数 backoff up to 60s)。**没有
/// cooldown / topK 等花活**——pool 就是个全开 + reconcile + 聚合 state 的 thin shell。
///
/// **probe 角色**: 完全不影响 pool 决策,仅给 coordinator 选 HTTP `client` URL 用。
/// WS 本身就是"这个 URL 能不能用"的标准答案,probe 是 HTTP 角度的辅助信号。
///
/// **state 聚合**: 任一 WS .connected → pool .connected;否则按活跃度降级。
/// lastHeartbeatAt = 所有 sub WS 中最新一帧时间(给 zombie 检测兜底)
@MainActor
@Observable
final class PeerWSPool {
    struct SocketSnapshot: Equatable, Sendable {
        let url: String
        let state: PeerWebSocket.State
        let lastHeartbeatAt: Date?
    }

    enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected(peerDeviceID: String)
        case backoff(failures: Int)
        case stopped
        case failed(String)
    }

    /// **internal** —— 直接暴露给 coordinator.poolStatus(for:) 让 UI 只读单个 URL state,
    /// 不再走 snapshot() 全 6 个 sub WS 遍历(每行渲染读 78 个 Observable 让 SwiftUI 冻僵)
    var sockets: [String: PeerWebSocket] = [:]
    private let secret: Data
    private let onAdvance: @MainActor (Int64) -> Void
    private let onEndpointsChanged: @MainActor () -> Void
    private var lastEndpoints: [PeerEndpoint] = []

    init(
        secret: Data,
        onAdvance: @escaping @MainActor (Int64) -> Void,
        onEndpointsChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.secret = secret
        self.onAdvance = onAdvance
        self.onEndpointsChanged = onEndpointsChanged
    }

    /// 把当前完整 endpoint list 调和给 pool——所有 URL 全开 WS。已在 sockets 里的不动
    /// (复用现有 WS),不在 endpoints 里的 stop + remove
    func reconcile(endpoints: [PeerEndpoint]) {
        self.lastEndpoints = endpoints
        let desired = Set(endpoints.map { $0.url })
        let kinds = endpoints.map { $0.kind.rawValue }
        DebugLog.shared.append("ws-pool reconcile: keep=\(desired.count) [\(kinds.joined(separator: ","))]")

        // 1) 关掉不在 list 的——snapshot 后 mutate 防 dict iteration UB
        let toClose: [(String, PeerWebSocket)] = sockets.compactMap { (url, ws) in
            desired.contains(url) ? nil : (url, ws)
        }
        for (url, ws) in toClose {
            ws.stop()
            sockets.removeValue(forKey: url)
            DebugLog.shared.append("ws-pool drop: \(url)")
        }
        // 2) 没在 sockets 里的全开 WS
        for ep in endpoints where sockets[ep.url] == nil {
            guard let url = URL(string: ep.url) else { continue }
            let cfg = PeerConfig(baseURL: url, sharedSecret: secret)
            let ws = PeerWebSocket(
                config: cfg,
                onAdvance: { [weak self] ns in
                    self?.onAdvance(ns)
                },
                onEndpointsChanged: { [weak self] in
                    self?.onEndpointsChanged()
                }
            )
            ws.start()
            sockets[ep.url] = ws
            DebugLog.shared.append("ws-pool open: \(ep.url) (\(ep.kind.rawValue))")
        }
    }

    func stop() {
        for ws in sockets.values { ws.stop() }
        sockets.removeAll()
    }

    var state: State {
        if sockets.isEmpty { return .idle }
        var hasConnecting = false
        var minBackoff: Int = .max
        var lastFailed: String?
        var connectedPID: String?
        for ws in sockets.values {
            switch ws.state {
            case .connected(let pid):
                if connectedPID == nil { connectedPID = pid }
            case .connecting:
                hasConnecting = true
            case .backoff(let f):
                minBackoff = min(minBackoff, f)
            case .failed(let m):
                lastFailed = m
            case .stopped, .idle:
                break
            }
        }
        if let pid = connectedPID { return .connected(peerDeviceID: pid) }
        if hasConnecting { return .connecting }
        if minBackoff != .max { return .backoff(failures: minBackoff) }
        if let m = lastFailed { return .failed(m) }
        return .stopped
    }

    var lastHeartbeatAt: Date? {
        sockets.values.compactMap { $0.lastHeartbeatAt }.max()
    }

    var preferredHTTPURL: String? {
        let connected = sockets.compactMap { (url, ws) -> (url: String, ws: PeerWebSocket)? in
            if case .connected = ws.state { return (url, ws) } else { return nil }
        }
        guard !connected.isEmpty else { return nil }
        return connected
            .sorted { ($0.ws.lastHeartbeatAt ?? .distantPast) > ($1.ws.lastHeartbeatAt ?? .distantPast) }
            .first?.url
    }

    func snapshot() -> [SocketSnapshot] {
        sockets.map { url, ws in
            SocketSnapshot(url: url, state: ws.state, lastHeartbeatAt: ws.lastHeartbeatAt)
        }
    }
}

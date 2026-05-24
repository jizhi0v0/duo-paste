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

    struct ConnectedRoute: Equatable, Sendable {
        let url: String
        let peerDeviceID: String
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

    /// 旧 NWConnection 可能短时间仍报告 connected,但底层 path 已经不可用。这里只打断
    /// 当前 connection,让每个 WS 自己按现有 failures/backoff 重连;不销毁 socket 对象。
    ///
    /// **保留 failures 退避**——用于"健康 candidate 需要立即重连但不绕过自身退避"的
    /// 场景。NWPath 硬变化/手动刷新 等环境变化作废前一段失败教训 的场景用
    /// `restartAllResettingBackoff`
    func restartAll(reason: String) {
        guard !lastEndpoints.isEmpty else { return }
        DebugLog.shared.append("ws-pool reconnect preserving backoff: \(reason)")
        for ws in sockets.values {
            ws.reconnectPreservingBackoff(reason: reason)
        }
        // **不调** reconcile(endpoints: lastEndpoints)——
        // reconcile 的"sockets[ep.url] == nil 才开"分支在这里永远 no-op（reconnectPreservingBackoff
        // 不删 socket），白消耗。更糟的边界：如果 `lastEndpoints` 跟 endpoints_changed 帧同时
        // 到达（一个改 lastEndpoints，一个走 restartAll），reconcile 会用 stale lastEndpoints
        // 关掉新 endpoint 的 ws。endpoints 真变化走 reconcile(endpoints:) 自己的路径
    }

    /// 跟 `restartAll` 一样打断每个 WS 当前 connection,但**额外让每个 sub WS 清 failures**
    /// 让下次重连立即从 1s 退避起。用于环境硬变化作废之前的失败教训:
    /// - NWPath status / primary interface 真变化(`handleNetworkChange`)
    /// - 用户在 Settings 主动点"刷新候选"按钮
    ///
    /// 例: 用户切到 Surge VPN 后, `.sgponte` 候选 之前永久 DNS 失败 failures=11+ 在 300s 退避
    /// 里, 切 VPN 后立刻可用 → reset 让它从 1s 起立刻重试,UX 秒级恢复
    func restartAllResettingBackoff(reason: String) {
        guard !lastEndpoints.isEmpty else { return }
        DebugLog.shared.append("ws-pool reconnect resetting backoff: \(reason)")
        for ws in sockets.values {
            ws.reconnectResettingBackoff(reason: reason)
        }
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

    func isConnected(url: String?) -> Bool {
        guard let url, let ws = sockets[url] else { return false }
        if case .connected = ws.state { return true }
        return false
    }

    func preferredHTTPURL(prefer currentURL: String?) -> String? {
        if isConnected(url: currentURL) {
            return currentURL
        }
        let connected = sockets.compactMap { (url, ws) -> (url: String, ws: PeerWebSocket, endpoint: PeerEndpoint?)? in
            if case .connected = ws.state {
                let endpoint = lastEndpoints.first(where: { $0.url == url })
                return (url, ws, endpoint)
            }
            return nil
        }
        guard !connected.isEmpty else { return nil }
        return connected
            .sorted { a, b in
                let pa = Self.endpointPriority(a.endpoint)
                let pb = Self.endpointPriority(b.endpoint)
                if pa != pb { return pa < pb }
                return (a.ws.lastHeartbeatAt ?? .distantPast) > (b.ws.lastHeartbeatAt ?? .distantPast)
            }
            .first?.url
    }

    var preferredHTTPURL: String? {
        preferredHTTPURL(prefer: nil)
    }

    func connectedHTTPURLs(prefer currentURL: String?) -> [String] {
        let connected = sockets.compactMap { (url, ws) -> (url: String, endpoint: PeerEndpoint?)? in
            if case .connected = ws.state {
                return (url, lastEndpoints.first(where: { $0.url == url }))
            }
            return nil
        }
        return connected
            .sorted { a, b in
                if a.url == currentURL { return true }
                if b.url == currentURL { return false }
                let pa = Self.endpointPriority(a.endpoint)
                let pb = Self.endpointPriority(b.endpoint)
                if pa != pb { return pa < pb }
                return a.url < b.url
            }
            .map(\.url)
    }

    /// 返回每个 peer 设备最多一个可用 HTTP route。一个 Mac 可能同时有 local/tailscale
    /// 多条 WS 都 connected；fanout `/bump` 时重复打同一台 Mac 会把同一行 bump 多次，
    /// 造成 cursor/pull 噪声和排序抖动。
    func connectedHTTPURLsByDevice(prefer currentURL: String?) -> [String] {
        let connected = sockets.compactMap { (url, ws) -> (url: String, peerDeviceID: String, endpoint: PeerEndpoint?)? in
            if case .connected(let peerDeviceID) = ws.state {
                return (url, peerDeviceID, lastEndpoints.first(where: { $0.url == url }))
            }
            return nil
        }
        let sorted = connected.sorted { a, b in
            if a.url == currentURL { return true }
            if b.url == currentURL { return false }
            let pa = Self.endpointPriority(a.endpoint)
            let pb = Self.endpointPriority(b.endpoint)
            if pa != pb { return pa < pb }
            return a.url < b.url
        }
        var seen = Set<String>()
        var urls: [String] = []
        for route in sorted where !seen.contains(route.peerDeviceID) {
            seen.insert(route.peerDeviceID)
            urls.append(route.url)
        }
        return urls
    }

    private nonisolated static func endpointPriority(_ endpoint: PeerEndpoint?) -> Int {
        guard let endpoint else { return 99 }
        if endpoint.preferred { return 0 }
        switch endpoint.kind {
        case .ponte: return 1
        case .tailscale: return 2
        case .local: return 3
        case .lanIP: return 4
        }
    }

    func snapshot() -> [SocketSnapshot] {
        sockets.map { url, ws in
            SocketSnapshot(url: url, state: ws.state, lastHeartbeatAt: ws.lastHeartbeatAt)
        }
    }
}

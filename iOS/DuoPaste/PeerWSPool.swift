import Foundation
import Observation
import DuoPasteCore

/// 多 URL 并发 WS 池。**所有 endpoint** 全开 PeerWebSocket,任一 URL 推 cursor_advanced
/// 都触发 onAdvance,任一 URL 推 endpoints_changed 都触发 onEndpointsChanged。
///
/// 解决"WS 在一棵树上吊死"问题——iOS URLSessionWebSocketTask 在 cellular 经 Surge MITM
/// 链路上对某 URL 的 TLS challenge 会跳过 delegate(已知 iOS bug),导致 HTTP probe 过了
/// 但 WS TLS -1200 死循环;同时 Wi-Fi 上 .sgponte hostname 不通而 cellular 上 Surge 接管
/// 这些 URL 就通。两种 case 都让"挑一个最快开 WS"挂掉。
///
/// **设计**: 6 个 endpoint = 6 个 WS,握手字节预算 < 12KB(控制面 frame),即便 cellular
/// 也微不足道。每个 WS 自己 backoff 重连,**probe RTT 仅给 coordinator 选 HTTP client URL,
/// 不参与 WS pool 选择**——WS 本身就是"这个 URL 能不能用"的标准答案
///
/// **state 聚合**: 任一 WS .connected → pool .connected;否则按活跃度降级
///
/// **失败处理**: 单 URL 连续 ws-failures 达阈值 → 60s cooldown(避免持续浪费 backoff 在
/// 已知坏 URL 上)。**NetworkChangeWatcher 触发 clearCooldowns** 让网络切换瞬间重试所有 URL
@MainActor
@Observable
final class PeerWSPool {
    /// 一个子 WS 的快照——给 UI / 调试用
    struct SocketSnapshot: Equatable, Sendable {
        let url: String
        let state: PeerWebSocket.State
        let lastHeartbeatAt: Date?
    }

    /// state 聚合后的 pool 整体状态。语义跟 PeerWebSocket.State 保持一致,coordinator
    /// 可以基本上当成单个 WS 来读
    enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected(peerDeviceID: String)
        case backoff(failures: Int)
        case stopped
        case failed(String)
    }

    private(set) var sockets: [String: PeerWebSocket] = [:]
    private let secret: Data
    private let onAdvance: @MainActor (Int64) -> Void
    /// 所有 WS 都不健康 → 通知 coordinator 触发新一轮 probe(给 HTTP client URL 更新数据)
    private let onAllDown: @MainActor (String) -> Void
    private let onEndpointsChanged: @MainActor () -> Void
    /// 单 URL 连续 ws-failures 达阈值后,这个 URL 进入 cooldown 不再被选 N 秒。
    /// 默 60s——足够让 cellular NAT 重建 / Surge 路由切回正常,又不会永久封 URL.
    /// **NetworkChangeWatcher 触发 clearCooldowns** 让 Wi-Fi→cellular 立即重试所有 URL
    nonisolated let cooldownSec: TimeInterval
    /// 单 URL 当前 cooldown 解锁时间
    private var cooldownUntil: [String: Date] = [:]
    /// 最近一次 coordinator 喂的 endpoint list——sub WS 失败 / cooldown clear 时 pool
    /// 自己用这个 re-reconcile,不需 coordinator 重新喂
    private var lastEndpoints: [PeerEndpoint] = []

    init(
        secret: Data,
        cooldownSec: TimeInterval = 60,
        onAdvance: @escaping @MainActor (Int64) -> Void,
        onAllDown: @escaping @MainActor (String) -> Void = { _ in },
        onEndpointsChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.secret = secret
        self.cooldownSec = cooldownSec
        self.onAdvance = onAdvance
        self.onAllDown = onAllDown
        self.onEndpointsChanged = onEndpointsChanged
    }

    /// 把当前完整 endpoint list 调和给 pool——**所有非 cooldown 的 URL 全开 WS**。
    /// 不再做 probe / RTT 过滤——probe 数据只给 coordinator 选 HTTP client URL 用,
    /// WS 本身就是"这个 URL 能不能用"的标准。Wi-Fi 上 .sgponte 不通而 cellular 上通
    /// 这种 case,probe 永远说 -1,但 WS 真试就能发现差别。
    ///
    /// **cooldown 过滤**:连续 ws-failures 达阈值的 URL 60s 内被跳过,避免 backoff 浪费
    /// 在已知坏 URL 上。NetworkChangeWatcher 触发 clearCooldowns 让网络切换瞬间重试所有
    func reconcile(endpoints: [PeerEndpoint]) {
        self.lastEndpoints = endpoints
        let now = Date()
        let desired = Set(endpoints.compactMap { ep -> String? in
            if let until = cooldownUntil[ep.url], until > now { return nil }
            return ep.url
        })
        let cooledOut = endpoints.filter { ep in
            (cooldownUntil[ep.url] ?? .distantPast) > now
        }.map { $0.kind.rawValue }
        let coolStr = cooledOut.isEmpty ? "" : " cooldown=[\(cooledOut.joined(separator: ","))]"
        let kinds = endpoints.filter { desired.contains($0.url) }.map { $0.kind.rawValue }
        DebugLog.shared.append("ws-pool reconcile: keep=\(desired.count) [\(kinds.joined(separator: ","))]\(coolStr)")

        // 1) 关掉不在选中 list 的(主要是新被 cooldown 的 URL)——snapshot 后再 mutate 防
        //    dict iteration mutation UB
        let toClose: [(String, PeerWebSocket)] = sockets.compactMap { (url, ws) in
            desired.contains(url) ? nil : (url, ws)
        }
        for (url, ws) in toClose {
            ws.stop()
            sockets.removeValue(forKey: url)
            DebugLog.shared.append("ws-pool drop: \(url)")
        }
        // 2) 没在 sockets 里的全开 WS
        for ep in endpoints where desired.contains(ep.url) && sockets[ep.url] == nil {
            guard let url = URL(string: ep.url) else { continue }
            let cfg = PeerConfig(baseURL: url, sharedSecret: secret)
            let epURL = ep.url
            let ws = PeerWebSocket(
                config: cfg,
                onAdvance: { [weak self] ns in
                    self?.onAdvance(ns)
                },
                onReprobeNeeded: { [weak self] reason in
                    self?.handleSubFailure(url: epURL, reason: reason)
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

    /// 网络变化(NWPathMonitor 触发)→ 立刻清掉所有 cooldown,让之前失败过的 URL
    /// 在新网络环境下重试。典型场景:Wi-Fi 上 .sgponte 没 Surge 路由失败 cooldown,
    /// 切 cellular 后 Surge 接管,这些 URL 现在能工作——必须立刻给它们机会
    func clearCooldowns(reason: String) {
        guard !cooldownUntil.isEmpty else { return }
        let n = cooldownUntil.count
        cooldownUntil.removeAll()
        DebugLog.shared.append("ws-pool clearCooldowns: \(reason) (cleared=\(n))")
        if !lastEndpoints.isEmpty {
            reconcile(endpoints: lastEndpoints)
        }
    }

    func stop() {
        for ws in sockets.values { ws.stop() }
        sockets.removeAll()
    }

    /// 任一 sub WS 处于 .connected → pool 是 .connected(取 peerDeviceID).
    /// 否则按活跃度降级:.connecting > .backoff > .failed > .stopped > .idle
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

    /// 任一 sub WS 收到的最近一帧时间——zombie 检测用
    var lastHeartbeatAt: Date? {
        sockets.values.compactMap { $0.lastHeartbeatAt }.max()
    }

    /// 取当前**最优活连接** URL——HTTP `client` 用这个 URL 发 /since / blob / bump。
    /// 优先级:.connected 的 URL 中 (kind 优先级,sub WS lastHeartbeat 新近度) 排序选第一。
    /// 没活连接返 nil
    var preferredHTTPURL: String? {
        let connected = sockets.compactMap { (url, ws) -> (url: String, ws: PeerWebSocket)? in
            if case .connected = ws.state { return (url, ws) } else { return nil }
        }
        guard !connected.isEmpty else { return nil }
        // 按 url 字符串拿 kind 不稳——pool 自己不记 kind。取 lastHeartbeat 最新的一个作为
        // 最健康选项(刚刚有帧 = 链路活)。其余字段 coordinator 那边可以再排
        return connected
            .sorted { ($0.ws.lastHeartbeatAt ?? .distantPast) > ($1.ws.lastHeartbeatAt ?? .distantPast) }
            .first?.url
    }

    /// 子 WS 报告"我连续失败 N 次"——pool 把这个 URL cooldown 60s + 关掉它的 WS,
    /// 再 reconcile 一次让其他还没在 pool 里的 endpoint 有机会被开 WS。如果全部 endpoint
    /// 都 cooldown 了 → onAllDown escalate 给 coordinator 触发新一轮 probe + 提示用户
    private func handleSubFailure(url: String, reason: String) {
        cooldownUntil[url] = Date().addingTimeInterval(cooldownSec)
        DebugLog.shared.append("ws-pool cooldown \(Int(cooldownSec))s: \(url) \(reason)")
        if let ws = sockets[url] {
            ws.stop()
            sockets.removeValue(forKey: url)
        }
        if !lastEndpoints.isEmpty {
            reconcile(endpoints: lastEndpoints)
        }
        if sockets.isEmpty {
            DebugLog.shared.append("ws-pool all-down: trigger repick (\(reason))")
            onAllDown("all-down: \(reason)")
        }
    }

    /// UI / 调试用——cooldown 中的 URL 列表 + 各自解锁时间
    func cooldownSnapshot() -> [(url: String, until: Date)] {
        let now = Date()
        return cooldownUntil.compactMap { url, until in
            until > now ? (url, until) : nil
        }
    }

    /// UI 调试用——返回每个 sub WS 当前快照
    func snapshot() -> [SocketSnapshot] {
        sockets.map { url, ws in
            SocketSnapshot(url: url, state: ws.state, lastHeartbeatAt: ws.lastHeartbeatAt)
        }
    }
}

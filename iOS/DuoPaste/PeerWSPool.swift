import Foundation
import Observation
import DuoPasteCore

/// 多 URL 并发 WS 池。同时对 top-K 个 endpoint URL 起 PeerWebSocket,任一 URL 推
/// cursor_advanced 都触发 onAdvance,任一 URL 推 endpoints_changed 都触发 onEndpointsChanged。
///
/// 解决"WS 在一棵树上吊死"问题——iOS URLSessionWebSocketTask 在 cellular 经 Surge MITM
/// 链路上对某 URL 的 TLS challenge 会跳过 delegate(已知 iOS bug),导致 HTTP probe 过了
/// 但 WS TLS -1200 死循环。pool 让 tailscale wss 挂的同时 local / ponte wss 还在工作,
/// cursor_advanced 仍然能进来。
///
/// **state 聚合**: 任一 WS .connected → pool 是 .connected;否则取最"活跃"的子 state
/// (.connecting > .backoff > .failed > .stopped)
///
/// **失败处理**: 单 URL 的 WS 失败由它自己 backoff 重连(不出 pool);所有 URL 全部
/// 进 backoff/failed → onAllDown 触发上层 repick。**不再有 onReprobeNeeded per-URL** 回调,
/// pool 用 "all down" 作为 escalation 信号
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
    /// 所有 WS 都不健康(全部 backoff/failed/stopped)→ 通知 coordinator 重 probe
    private let onAllDown: @MainActor (String) -> Void
    private let onEndpointsChanged: @MainActor () -> Void
    /// 同时保持开的 WS 数。2 = 头部+次优;3 = 加三优(更冗余但 cellular 带宽稍高).
    /// 默 2 是控制面字节 trade-off 的 sweet spot
    nonisolated let topK: Int
    /// 单 URL 连续 ws-failures 达阈值后,这个 URL 进入 cooldown 不再被选 N 秒。
    /// 默 60s——足够让 cellular NAT 重建 / Surge 路由切回正常,又不会永久封 URL
    nonisolated let cooldownSec: TimeInterval
    /// 单 URL 当前 cooldown 解锁时间
    private var cooldownUntil: [String: Date] = [:]
    /// 最近一次 coordinator 喂的 probe list——sub WS 失败时 pool 自己用这个 re-reconcile
    /// 选下一候选,不用 coordinator 重 probe(probe 慢,要 5s)
    private var lastReceivedProbes: [EndpointPicker.Probe] = []

    init(
        secret: Data,
        topK: Int = 2,
        cooldownSec: TimeInterval = 60,
        onAdvance: @escaping @MainActor (Int64) -> Void,
        onAllDown: @escaping @MainActor (String) -> Void = { _ in },
        onEndpointsChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.secret = secret
        self.topK = topK
        self.cooldownSec = cooldownSec
        self.onAdvance = onAdvance
        self.onAllDown = onAllDown
        self.onEndpointsChanged = onEndpointsChanged
    }

    /// 用最新探活结果调和 pool——按 (kind 优先级,RTT) 排序后取 top-K 个 reachable URL,
    /// 删掉不在选中 list 的旧 WS,给新选中的起 WS。已在 list 里的 WS **不动**(避免每次
    /// repick 都重连)。
    ///
    /// reachable 过滤是关键:probe 失败的 URL (rttMs < 0) 不要开 WS,否则 cellular 完全
    /// 不通时全 6 个 URL 都白起白失败浪费。**cooldown 过滤**:连续 WS 失败的 URL
    /// 60s 内被跳过,让 pool 自动 rotate 到下一候选(防 iOS WS TLS 一个 URL 死循环)
    func reconcile(probes: [EndpointPicker.Probe]) {
        self.lastReceivedProbes = probes
        let now = Date()
        let reachable = probes.filter { p in
            guard p.ok else { return false }
            if let until = cooldownUntil[p.endpoint.url], until > now { return false }
            return true
        }
        let selected = Array(reachable.prefix(topK))
        let desired = Set(selected.map { $0.endpoint.url })
        let cooledOut = probes.filter { p in
            p.ok && (cooldownUntil[p.endpoint.url] ?? .distantPast) > now
        }.map { $0.endpoint.kind.rawValue }
        let coolStr = cooledOut.isEmpty ? "" : " cooldown=[\(cooledOut.joined(separator: ","))]"
        DebugLog.shared.append("ws-pool reconcile: keep=\(desired.count) [\(selected.map { $0.endpoint.kind.rawValue }.joined(separator: ","))]\(coolStr)")

        // 1) 关掉不在选中 list 的——**先 snapshot 再删**,迭代 dict 中 removeValue
        //    是 undefined behavior,实测会让 swift 6 strict concurrency 下偶发 EXC_BAD_ACCESS
        let toClose: [(String, PeerWebSocket)] = sockets.compactMap { (url, ws) in
            desired.contains(url) ? nil : (url, ws)
        }
        for (url, ws) in toClose {
            ws.stop()
            sockets.removeValue(forKey: url)
            DebugLog.shared.append("ws-pool drop: \(url)")
        }
        // 2) 给新选中的起 WS
        for probe in selected where sockets[probe.endpoint.url] == nil {
            guard let url = URL(string: probe.endpoint.url) else { continue }
            let cfg = PeerConfig(baseURL: url, sharedSecret: secret)
            let ws = PeerWebSocket(
                config: cfg,
                onAdvance: { [weak self] ns in
                    self?.onAdvance(ns)
                },
                onReprobeNeeded: { [weak self] reason in
                    // 单 URL 失败到 ws-failures 阈值——检查 pool 是否全死,全死才 escalate
                    self?.handleSubFailure(url: probe.endpoint.url, reason: reason)
                },
                onEndpointsChanged: { [weak self] in
                    self?.onEndpointsChanged()
                }
            )
            ws.start()
            sockets[probe.endpoint.url] = ws
            DebugLog.shared.append("ws-pool open: \(probe.endpoint.url) (\(probe.endpoint.kind.rawValue) \(probe.rttMs)ms)")
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

    /// 子 WS 报告"我连续失败 N 次"——pool 把这个 URL cooldown 60s + 关掉它的 WS +
    /// 用 lastReceivedProbes 立即 reconcile 选下一候选。如果备选 list 也空了或全 cooldown,
    /// onAllDown escalate 给 coordinator 触发新一轮 probe
    private func handleSubFailure(url: String, reason: String) {
        cooldownUntil[url] = Date().addingTimeInterval(cooldownSec)
        DebugLog.shared.append("ws-pool cooldown \(Int(cooldownSec))s: \(url) \(reason)")
        // 关掉这个 WS 让 reconcile 能从 sockets 里删掉重新选
        if let ws = sockets[url] {
            ws.stop()
            sockets.removeValue(forKey: url)
        }
        // 立即用 cached probe list 补一个候选——pool 内部自治,不等 coordinator probe(5s)
        if !lastReceivedProbes.isEmpty {
            reconcile(probes: lastReceivedProbes)
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

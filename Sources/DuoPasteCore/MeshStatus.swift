import Foundation

/// PullWorker → SearchProvider / UI 的非阻塞状态通道（mesh 拓扑版）。
///
/// 取代 PR 1 之前的 `MirrorStatus`（单 peer 全局单值）。mesh 拓扑下每个 peer 一个 PullWorker，
/// 各自有独立的 lastPullNs / clockSkewMs / consecutiveFailures，所以内部存成 per-peer dict。
/// SearchProvider 用聚合视图（最悲观值）判断 mesh 是否"追平"——任一 peer 还没拉过即 nil，
/// staleness = now - 所有 peer 中最旧的 lastPullNs。
///
/// 为什么不直接让 SearchProvider 持有 PullWorker：
/// - PullWorker 是 actor，跨 actor 边界读 `lastPullNs` 需要 `await`，但 SearchProvider.search
///   是同步进 actor 的，闭包形式拿不到 await
/// - SearchProvider 不该知道 mesh 是怎么填的、谁在填，只关心"现在 mesh 多新"
///
/// 频率：每个 peer 30s 一次写，用户打字时几次/秒读（聚合视图），NSLock 即可。
public final class MeshStatus: @unchecked Sendable {
    /// Per-peer 状态。PR 2 含 lastPullNs / clockSkewMs / consecutiveFailures。
    /// PR 3 加 lastWSConnectedNs 走 WS 连接状态。
    public struct PeerState: Sendable, Equatable {
        public var lastPullNs: Int64?
        public var clockSkewMs: Int64?
        public var consecutiveFailures: Int
        public init(
            lastPullNs: Int64? = nil,
            clockSkewMs: Int64? = nil,
            consecutiveFailures: Int = 0
        ) {
            self.lastPullNs = lastPullNs
            self.clockSkewMs = clockSkewMs
            self.consecutiveFailures = consecutiveFailures
        }
    }

    private let lock = NSLock()
    private var states: [String: PeerState] = [:]

    public init() {}

    /// Per-peer 读取。peer 未注册（PullWorker 还没 set 过任何字段）→ nil。
    public func peer(_ peerDeviceID: String) -> PeerState? {
        lock.lock(); defer { lock.unlock() }
        return states[peerDeviceID]
    }

    /// 上次成功完成一轮拉取（含空轮：has_more=false 收尾）的 wall-clock ns。
    /// PullWorker 在 has_more=false 且无 transient 时调用。nil → 表示这一轮没完整追平
    /// （首次启动 / 失败 / has_more=true 中途）。
    public func setLastPullNs(peerDeviceID: String, _ ns: Int64?) {
        lock.lock(); defer { lock.unlock() }
        states[peerDeviceID, default: PeerState()].lastPullNs = ns
    }

    /// 上一轮 /health 探测到的 peer wall-clock 相对本机的偏移（毫秒）。
    /// 正值 = peer 比本机快；负值 = peer 比本机慢。nil = 还没探测过 / 探测失败。
    ///
    /// HMAC 签名带 timestamp_ms 容许 ±5 分钟 skew；这个值给 UI banner 做"预警"——
    /// 偏移接近窗口边界时显式提醒用户，比 401 拒签后再排查友好。
    public func setClockSkewMs(peerDeviceID: String, _ ms: Int64?) {
        lock.lock(); defer { lock.unlock() }
        states[peerDeviceID, default: PeerState()].clockSkewMs = ms
    }

    /// 连续失败次数。PullWorker tick 失败 +1 / 成功清零，用于指数 backoff。
    public func setConsecutiveFailures(peerDeviceID: String, _ count: Int) {
        lock.lock(); defer { lock.unlock() }
        states[peerDeviceID, default: PeerState()].consecutiveFailures = count
    }

    /// 聚合视图：所有已注册 peer 中最旧的 lastPullNs（最悲观）。
    ///
    /// 返回 nil 的场景：
    /// - 没有任何 peer 已注册（PR 2 单 peer 部署首次启动 / standalone）
    /// - **任一**已注册 peer 的 lastPullNs == nil（这是关键：mesh 必须**所有** peer 都至少追平
    ///   过一轮才算"可信本地"，否则 SearchProvider 不该走 .localMirror 路径——某 peer 还没追平
    ///   时本地 item 表对该 peer 视角的全集是缺的，搜索可能漏行）
    ///
    /// 非 nil 时返回所有 lastPullNs 的 min（最悲观 = staleness 取最大值）。
    public func oldestLastPullNs() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard !states.isEmpty else { return nil }
        var minimum: Int64 = .max
        for state in states.values {
            guard let ns = state.lastPullNs else { return nil }
            if ns < minimum { minimum = ns }
        }
        return minimum == .max ? nil : minimum
    }

    /// 聚合视图：所有 peer 中绝对值最大的 clockSkewMs。UI banner 用 worst-case 触发预警。
    /// nil = 没有任何 peer 有 skew 数据。
    public func worstClockSkewMs() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        var worst: Int64? = nil
        for state in states.values {
            guard let skew = state.clockSkewMs else { continue }
            if worst == nil || abs(skew) > abs(worst!) {
                worst = skew
            }
        }
        return worst
    }

    /// 已注册的 peer device_id 列表（诊断用）。
    public func registeredPeerDeviceIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(states.keys)
    }

    /// 重置某个 peer（reconcilePeer 检测到 device_id 换了时清旧状态）。
    public func removePeer(_ peerDeviceID: String) {
        lock.lock(); defer { lock.unlock() }
        states.removeValue(forKey: peerDeviceID)
    }
}

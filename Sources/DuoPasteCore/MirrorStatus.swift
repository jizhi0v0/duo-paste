import Foundation

/// PullWorker → SearchProvider 的非阻塞状态通道。
///
/// 为什么不直接让 SearchProvider 持有 PullWorker：
/// - PullWorker 是 actor，跨 actor 边界读 `lastPullNs` 需要 `await`，但 SearchProvider.search
///   是同步进 actor 的，闭包形式拿不到 await
/// - SearchProvider 不该知道 mirror 是怎么填的、谁在填，只关心"现在 mirror 多新"
///
/// 所以引入一个轻量共享对象：PullWorker 每完成一轮成功拉取 set 一次，
/// SearchProvider 每次 search 同步 get 一次。NSLock 即可，频率低（30s 一次写，
/// 用户打字时几次/秒读），无竞争。
public final class MirrorStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastPullNs: Int64?
    private var _primaryDeviceID: String?

    public init() {}

    /// 上次成功完成一轮拉取（含空轮：has_more=false 收尾）的 wall-clock ns。
    /// nil → 还从未成功拉过（pull 未启用 / 首拉前 / 一直失败）。
    /// SearchProvider 用这个判断 mirror 是否"有效"——非 nil 即接入 .localMirror 模式。
    public func lastPullNs() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return _lastPullNs
    }

    public func setLastPullNs(_ ns: Int64?) {
        lock.lock(); defer { lock.unlock() }
        _lastPullNs = ns
    }

    /// PullWorker 通过 /health 拿到的 primary device_id。诊断用，UI 不直接展示。
    public func primaryDeviceID() -> String? {
        lock.lock(); defer { lock.unlock() }
        return _primaryDeviceID
    }

    public func setPrimaryDeviceID(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        _primaryDeviceID = id
    }
}

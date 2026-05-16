import Foundation

/// BlobStore 内存级字节占用计数器。Settings"关于"页订阅这个 actor 推送，避免每次刷新都
/// 扫整个 blobs 目录（plan 后期 blob 多了 stat 数百次/事件不便宜）。
///
/// 工作模式：
/// 1. daemon 启动时由 AppDelegate detached task 调 `Volume.directorySize` 算出 baseline →
///    `setBaseline(_:)` 一次性 commit
/// 2. baseline 建立**前**发生的 `add/sub` 进 `pendingDelta`（启动早期 capture/PullWorker
///    可能已经在写盘）；setBaseline 时 `baseline + pendingDelta` 一并落盘
/// 3. 之后所有 `BlobStore.put`（wasExisting=false）/ `evict(.deleted(size))` 直接增量更新
///    `bytes`，emit 给所有订阅者
///
/// 订阅契约：`stream()` 返回 AsyncStream，订阅时立即 yield 当前 `bytes`（可能是 nil 表示
/// baseline 未建），之后每次 add/sub/setBaseline 都 yield 新值。订阅者 task cancel 时
/// continuation onTermination 触发清理。
public actor BlobStorageStats {
    private var bytes: Int64?
    private var pendingDelta: Int64 = 0
    private var continuations: [UUID: AsyncStream<Int64?>.Continuation] = [:]

    public init() {}

    public func current() -> Int64? { bytes }

    /// 一次性安装 baseline。`b == nil` 把状态重置回 unknown（用于 Settings"重新扫盘"按钮，
    /// 当前没暴露但留给未来）。建好 baseline 时把启动早期累积的 pendingDelta 也并进去。
    public func setBaseline(_ b: Int64?) {
        if let b {
            bytes = max(0, b + pendingDelta)
            pendingDelta = 0
        } else {
            bytes = nil
        }
        emit()
    }

    /// 新 blob 写盘成功（BlobStore.put / putVerified 走"新写"分支）调。`n` = 该 blob 字节数。
    /// baseline 未建则记 pendingDelta（不 emit——避免订阅者看到半截 nil + delta 噪音）。
    public func add(_ n: Int64) {
        guard n > 0 else { return }
        if let b = bytes {
            bytes = b + n
            emit()
        } else {
            pendingDelta += n
        }
    }

    /// blob 被 evict（BlobEvictor 水位驱逐 / GC）调。`n` = 释放的字节数。
    public func sub(_ n: Int64) {
        guard n > 0 else { return }
        if let b = bytes {
            bytes = max(0, b - n)
            emit()
        } else {
            pendingDelta -= n
        }
    }

    /// 订阅。订阅瞬间会先收到一帧"当前值"（可能 nil），之后随 add/sub/setBaseline 推送。
    /// task cancel 自动 finish + 从 continuations 集合移除。
    public func stream() -> AsyncStream<Int64?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int64?>.makeStream()
        continuations[id] = continuation
        continuation.yield(bytes)
        continuation.onTermination = { @Sendable [weak self] _ in
            guard let self else { return }
            Task { await self.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit() {
        for c in continuations.values {
            c.yield(bytes)
        }
    }
}

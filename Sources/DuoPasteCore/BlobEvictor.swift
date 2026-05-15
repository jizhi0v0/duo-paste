import Foundation

/// 磁盘 ENOSPC 时的 LRU blob 驱逐器。
///
/// **核心契约**：
/// - 只驱逐 blob **文件**——`item.blob_sha256` 行保留指向 sha，`BlobStore.exists()`
///   之后返回 false → UI 走 CloudBadge "云端" 状态 → Enter 走 lazy 路径从 peer 重拉。
///   等价于把该行 per-row 降级到 `storage_mode=.optimized` 行为
/// - **永不删 text 行**（`blob_sha256 IS NULL`）——用户硬要求"保留文本"，数据本身也
///   占空间小
/// - **永不删 pinned**（`pinned=1`）—— 用户钉的硬不变量
/// - **永不删 DB 行**——驱逐 ≠ tombstone。tombstone 是用户主动删，blob GC 是空间压力
///
/// 用法：注入到 `BlobStore.putRetryingOnFull` 的 `evictor` 回调（reactive ENOSPC 路径）
/// 或 SnapshotScheduler 末尾的水位预防档（下一刀）
public struct BlobEvictor: Sendable {
    public let database: Database
    public let blobs: BlobStore
    public let log: @Sendable (String) -> Void

    public init(
        database: Database,
        blobs: BlobStore,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.database = database
        self.blobs = blobs
        self.log = log
    }

    /// 驱逐"孤儿 blob"——所有 ref 行都已 tombstone 的 sha。strictly 优于 LRU 的免费 win：
    /// 没有活跃行需要它、UI 看不到对应行、不触发 CloudBadge 云端态切换。
    ///
    /// 批量 drain：分页扫候选直到释放 `batchSize` 个 fs blob，或 DB 中已无候选。
    ///
    /// **为什么要分页**：DB 行驱逐时不动（契约硬不变量），所以已被驱逐过的 sha 仍在
    /// `tombstoneEvictableShas` 候选里——它们对 fs `.notFound`。如果 SQL `LIMIT 256`
    /// 全被这些"幻影候选"吃掉，每 round 都查到同样的 256 个返回 `freed=0`，永远摸不到
    /// 后面真有 fs 字节的 sha。分页配合 offset 让幻影 sha 被跳过去找真目标
    ///
    /// 内部 page=256，外层 `batchSize` 是目标 free 数。`freed=batchSize` 说明可能还有
    /// 更多，caller 再调一次即可（drainOrphans 这么干）
    @discardableResult
    public func evictTombstoneBlobs(batchSize: Int = 256) throws -> (freed: Int, bytes: Int64) {
        precondition(batchSize > 0, "batchSize must be > 0")
        var freed = 0
        var bytes: Int64 = 0
        var offset = 0
        let pageSize = 256
        while freed < batchSize {
            let candidates = try database.tombstoneEvictableShas(limit: pageSize, offset: offset)
            if candidates.isEmpty { break }
            offset += candidates.count
            for cand in candidates {
                if freed >= batchSize { break }
                switch blobs.evict(sha256: cand.sha) {
                case .deleted(let size):
                    freed += 1
                    bytes += size
                case .notFound:
                    continue
                case .failed(let err):
                    log("evict-tomb: rm 失败 sha=\(cand.sha.prefix(8))…: \(err)")
                    continue
                }
            }
        }
        if freed > 0 {
            log("evict-tomb: 释放 \(freed) 个孤儿 blob 共 \(bytes) bytes")
        }
        return (freed, bytes)
    }

    /// 驱逐一个 blob 文件。优先级：
    /// 1. **tombstone 先行**——孤儿 blob 是无副作用的免费 win，无 UI 切换、无 lazy 重拉
    /// 2. **LRU 兜底**——所有引用行仍活跃但需要腾空间时走这条，对应行降级到 CloudBadge
    ///    "云端"态，Enter 时 lazy 从 peer 重拉
    ///
    /// 实现：拉一批最老候选（默认 64）→ 逐个尝试 fs evict → 第一个 `.deleted` 返回
    /// true。`.notFound`（DB 行有 sha 但本机没字节，常态：optimized mode / 已被驱逐过）
    /// 跳到下一个，**不消耗** retry 配额——这种 sha 在 BlobStore 上根本不占空间，驱逐
    /// 它对解 ENOSPC 没帮助
    ///
    /// Returns: `true` 真的释放了 fs 字节；`false` 全批 candidates 都不在本机（极
    /// 少见——用户长期跑 optimized）或 DB 无 evictable 行（全 pinned / 全 text-only /
    /// 全活跃）。caller 收到 false 应放弃当前 put + 重抛原 ENOSPC
    @discardableResult
    public func evictOneOldest(batchSize: Int = 64) throws -> Bool {
        // 1) tombstone 先行——免费 win
        let tombstones = try database.tombstoneEvictableShas(limit: batchSize)
        for cand in tombstones {
            switch blobs.evict(sha256: cand.sha) {
            case .deleted(let size):
                log("evict-tomb: 释放 \(size) bytes sha=\(cand.sha.prefix(8))…")
                return true
            case .notFound:
                continue
            case .failed(let err):
                log("evict-tomb: rm 失败 sha=\(cand.sha.prefix(8))…: \(err)")
                continue
            }
        }
        // 2) LRU 兜底——有 UI 副作用（CloudBadge 切云端态）
        let candidates = try database.oldestEvictableShas(limit: batchSize)
        if candidates.isEmpty {
            log("evict: 无可驱逐 blob（全 pinned / 全 text / 全 tombstone 且本机无字节）")
            return false
        }
        var notLocalCount = 0
        for cand in candidates {
            switch blobs.evict(sha256: cand.sha) {
            case .deleted(let size):
                log("evict: 释放 \(size) bytes sha=\(cand.sha.prefix(8))…")
                return true
            case .notFound:
                notLocalCount += 1
                continue
            case .failed(let err):
                log("evict: rm 失败 sha=\(cand.sha.prefix(8))…: \(err)")
                // 不 short-circuit——可能是单文件权限问题，继续找下一个
                continue
            }
        }
        log("evict: \(candidates.count) 个 LRU 候选全部不在本机 (notLocal=\(notLocalCount))，放弃")
        return false
    }

    /// 多 round 孤儿 drain：循环调 `evictTombstoneBlobs` 直到一轮 freed=0 或达到
    /// `maxRounds`。语义"尽量清，但单次调用不无限阻塞 caller"。SnapshotScheduler 每小时
    /// tick 走这条路径，默 32 round × 256 batch = 8192 孤儿/tick；超过的留下个 tick 慢慢消化。
    ///
    /// 抛出：内部 `evictTombstoneBlobs` throw（SQL / fs 异常）会冒泡——caller 决定要不要
    /// 吞错误（hourly scheduler 选吞 + 写日志）
    @discardableResult
    public func drainOrphans(maxRounds: Int = 32) throws -> (freed: Int, bytes: Int64) {
        precondition(maxRounds > 0, "maxRounds must be > 0")
        var totalFreed = 0
        var totalBytes: Int64 = 0
        for _ in 0..<maxRounds {
            let (freed, bytes) = try evictTombstoneBlobs()
            if freed == 0 { break }
            totalFreed += freed
            totalBytes += bytes
        }
        return (totalFreed, totalBytes)
    }

    /// 水位预防档：可用空间 < `lowBytes` → 循环 evictOneOldest 直到可用空间 ≥
    /// `highBytes` 或达到 `perTickCap`。返回 `(freedCount, capHit)`。
    ///
    /// 双水位（hysteresis）避免在阈值上下抖动反复触发。`perTickCap` 防止单次 tick
    /// 卡太久—— SnapshotScheduler 是 hourly 节奏，正常情况 < 10 次 evict 足够；cap
    /// 主要兜底"用户突然清出 100GB" 这种异常 burst
    ///
    /// `availableBytes()` 返回 nil → "水位不可知，跳过驱逐" —— 启动早期临时卷查不到
    /// 值时**不**触发 aggressive GC（详见 Volume.swift）
    @discardableResult
    public func evictToWatermark(
        lowBytes: Int64,
        highBytes: Int64,
        perTickCap: Int = 500,
        availableBytes: () -> Int64?
    ) throws -> (freed: Int, capHit: Bool) {
        precondition(lowBytes <= highBytes, "lowBytes must be <= highBytes")
        precondition(perTickCap > 0, "perTickCap must be > 0")
        guard let initial = availableBytes() else {
            log("evict-watermark: availableBytes nil，跳过")
            return (0, false)
        }
        guard initial < lowBytes else {
            return (0, false)
        }
        log("evict-watermark: 可用 \(initial) bytes < low \(lowBytes)，开始驱逐")

        // 先一次性 drain 所有孤儿 blob —— 免费 win，不消耗 perTickCap
        var freed = 0
        var tombRounds = 0
        while tombRounds < 32 {
            let (tFreed, _) = try evictTombstoneBlobs()
            if tFreed == 0 { break }
            freed += tFreed
            tombRounds += 1
            if let avail = availableBytes(), avail >= highBytes {
                log("evict-watermark: tombstone drain 后已达 high，停止")
                return (freed, false)
            }
        }

        while freed < perTickCap {
            let avail = availableBytes() ?? initial
            if avail >= highBytes { break }
            let didFree = try evictOneOldest()
            if !didFree {
                log("evict-watermark: 已无可驱逐 candidates，停止 (freed=\(freed))")
                return (freed, false)
            }
            freed += 1
        }
        let capHit = freed >= perTickCap
        let finalAvail = availableBytes() ?? initial
        log("evict-watermark: freed=\(freed) capHit=\(capHit) 最终可用=\(finalAvail) bytes")
        return (freed, capHit)
    }
}

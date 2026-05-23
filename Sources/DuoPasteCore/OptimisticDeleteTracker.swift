import Foundation

/// iOS HistoryStore 乐观删除路径的状态机——把"删 fold 卡片立刻消失,不闪回"+"网络
/// 失败兜底 banner"两层语义拆出来单测.
///
/// **背景**:server `softDelete`(plan hashed-allen §C / PR #32)把同 text_full 所有 active
/// sibling 一起 tombstone(跨 origin).iOS 端 fold by text_full,但旧 `removeOptimistic(id:)`
/// 只删单 id → 同 text_full sibling 仍在内存里,fold 立刻 elect 另一条当代表 → 用户感觉
/// "卡片没删掉,几秒后才消失"(等 server cascade tombstones 通过 /since 拉回).
///
/// **本 tracker 提供两个原语**:
/// 1. [markDeleted]:返回 caller 应当从 items 移除的所有 id(text-kind cascade,blob-kind
///    单 id).同时按 id + text_full 双维度记 pending 让后续 [observeIncoming] 用.
/// 2. [observeIncoming]:扫 incoming 批,返回 (skipIds, resurrectedIds).skip 让 caller 把
///    in-flight `/since` 带回的同 text_full sibling 屏蔽在 grace 窗口内不入库;resurrected
///    让 caller 弹"删除未送达"banner.tombstone 自动清对应 pending entry.
///
/// **不变量**:
/// - cascade 范围跟 server `Database.softDelete` 严格对齐——`blob_sha256 == nil &&
///   text_full 非空`(text / url / rtf / html / 无 blob 的 file 路径)
/// - 所有 cascade 出来的 id 都进 pendingIds——sibling 后续在 grace 后回流时 banner 也算
/// - pendingTextFulls 命中 + 未超 grace → skip(不闪回);超 grace → resurrected(banner)
/// - tombstone 行到达永远清两边 pending entry(server 真删除了,后续 sibling 不再 skip)
/// - 60s 后 prune,防 dict 无限增长 + "等够久"的 entry 不再弹 banner
public struct OptimisticDeleteTracker: Sendable {
    public var gracePeriod: TimeInterval
    public var prunePeriod: TimeInterval

    private var pendingIds: [String: Date] = [:]
    private var pendingTextFulls: [String: Date] = [:]

    public init(gracePeriod: TimeInterval = 3, prunePeriod: TimeInterval = 60) {
        self.gracePeriod = gracePeriod
        self.prunePeriod = prunePeriod
    }

    /// caller 长按删除路径调.返回应当从 items 立即移除的所有 id(含 target 自己).
    /// text-kind(`blob_sha256 == nil && text_full 非空`)→ cascade 同 text_full 所有
    /// active sibling;否则单 id.同时按 id + text_full 双维度记 pending.
    public mutating func markDeleted(
        _ target: Item,
        in items: [Item],
        now: Date = Date()
    ) -> Set<String> {
        prune(now: now)

        var ids: Set<String> = [target.id]
        pendingIds[target.id] = now

        let isTextKind = target.blobSha256 == nil
            && (target.textFull?.isEmpty == false)
        if isTextKind, let text = target.textFull {
            pendingTextFulls[text] = now
            for it in items where it.id != target.id
                && it.blobSha256 == nil
                && it.textFull == text
                && it.deletedAtNs == nil {
                ids.insert(it.id)
                pendingIds[it.id] = now
            }
        }
        return ids
    }

    /// caller 的 merge() 入口调.tombstone 清 pending;非 tombstone:
    /// - text_full 命中且未超 grace → skip(防 in-flight /since 带回 sibling 闪回)
    /// - id 命中且超 grace → resurrected(server DELETE 没送达)
    /// - text_full 命中且超 grace → resurrected(server cascade 没送达)
    public mutating func observeIncoming(
        _ incoming: [Item],
        now: Date = Date()
    ) -> ObserveOutcome {
        prune(now: now)

        var skipIds = Set<String>()
        var resurrectedIds = Set<String>()

        for it in incoming {
            if it.deletedAtNs != nil {
                pendingIds.removeValue(forKey: it.id)
                if let t = it.textFull, !t.isEmpty {
                    pendingTextFulls.removeValue(forKey: t)
                }
                continue
            }
            if let pendingAt = pendingIds[it.id],
               now.timeIntervalSince(pendingAt) > gracePeriod {
                resurrectedIds.insert(it.id)
                pendingIds.removeValue(forKey: it.id)
            }
            if let t = it.textFull, !t.isEmpty,
               let pendingAt = pendingTextFulls[t] {
                if now.timeIntervalSince(pendingAt) <= gracePeriod {
                    skipIds.insert(it.id)
                } else {
                    resurrectedIds.insert(it.id)
                    pendingTextFulls.removeValue(forKey: t)
                }
            }
        }
        return ObserveOutcome(skipIds: skipIds, resurrectedIds: resurrectedIds)
    }

    /// 测试 / 诊断用——pending 表当前条数.
    public var pendingCount: (ids: Int, textFulls: Int) {
        (pendingIds.count, pendingTextFulls.count)
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-prunePeriod)
        pendingIds = pendingIds.filter { $0.value > cutoff }
        pendingTextFulls = pendingTextFulls.filter { $0.value > cutoff }
    }

    public struct ObserveOutcome: Equatable, Sendable {
        public let skipIds: Set<String>
        public let resurrectedIds: Set<String>

        public init(skipIds: Set<String>, resurrectedIds: Set<String>) {
            self.skipIds = skipIds
            self.resurrectedIds = resurrectedIds
        }
    }
}

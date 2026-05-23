import Testing
import Foundation
@testable import DuoPasteCore

/// 覆盖 `OptimisticDeleteTracker` 的契约——iOS HistoryStore 乐观删除路径状态机.
///
/// 背景见 `OptimisticDeleteTracker` doc:server `softDelete` cascade 同 text_full
/// 所有 sibling(PR #32),iOS 端 fold by text_full,旧 `removeOptimistic(id:)` 只删
/// 单 id → 同 text sibling 被 fold 立刻 elect 当代表 → "卡片删了又出现"几秒.
/// 本 suite 钉死 fold-aware cascade + grace 内 sibling skip + 60s prune 五条契约.
@Suite("OptimisticDeleteTracker (iOS fold-aware delete)")
struct OptimisticDeleteTrackerTests {

    private func makeText(
        id: String,
        origin: String,
        capturedAtNs: Int64 = 100,
        text: String,
        pinned: Bool = false
    ) -> Item {
        Item(
            id: id,
            originDevice: origin,
            capturedAtNs: capturedAtNs,
            kind: .text,
            preview: text,
            textFull: text,
            pinned: pinned
        )
    }

    private func makeImage(
        id: String,
        origin: String,
        capturedAtNs: Int64 = 100,
        sha: String
    ) -> Item {
        Item(
            id: id,
            originDevice: origin,
            capturedAtNs: capturedAtNs,
            kind: .image,
            blobSha256: sha
        )
    }

    /// **C1**:删 fold 代表 → `items` 里所有同 text_full sibling(不同 id / origin)
    /// 全部返回让 caller remove.cascade 范围跟 server `Database.softDelete` 对齐——
    /// fold-aware cascade 是修复"删了又出现"的核心.
    @Test("删 fold 代表 → 同 text_full 所有 sibling 全部 cascade")
    func cascadesAcrossTextFullSiblings() {
        var tracker = OptimisticDeleteTracker()
        let a = makeText(id: "a-self", origin: "self", text: "shared")
        let b = makeText(id: "b-peer", origin: "peer", text: "shared")
        let c = makeText(id: "c-other", origin: "self", text: "other")
        let target = b // 用户在 fold 卡上长按删除,实际拿到的是 fold winner(常为 peer 行)

        let ids = tracker.markDeleted(target, in: [a, b, c])

        #expect(ids == ["a-self", "b-peer"], "同 text 'shared' 的 a + b 全 cascade,c 不动")
    }

    /// **C2**:pendingTextFulls 命中且未超 grace → 后续 merge 把同 text_full sibling
    /// 进来时 skip 不入库.防 in-flight `/since` 在 server cascade tombstone 还没到达
    /// 时,把 mirror sibling 带回 UI 触发 fold 闪回.
    @Test("grace 内 in-flight sibling 进来 → skip 不入库")
    func skipsSiblingWithinGrace() {
        var tracker = OptimisticDeleteTracker(gracePeriod: 3)
        let now = Date()
        let target = makeText(id: "target", origin: "self", text: "shared")

        _ = tracker.markDeleted(target, in: [target], now: now)

        // 1s 后 in-flight /since 把同 text 的 mirror sibling(不同 id)带回来
        let inflight = makeText(id: "mirror", origin: "peer", text: "shared")
        let outcome = tracker.observeIncoming([inflight], now: now.addingTimeInterval(1))

        #expect(outcome.skipIds == ["mirror"], "grace 内同 text 的 mirror 必须被 skip")
        #expect(outcome.resurrectedIds.isEmpty, "grace 内不算 resurrected,不弹 banner")
    }

    /// **C3**:tombstone 行到达 → 清对应 pendingTextFulls + pendingIds entry.
    /// server 真删除成功后,后续同 text 的(罕见——可能 race 同步而来的全新 capture)
    /// 不再被 skip,正常入库.
    @Test("tombstone 到达 → 清 pending entry,后续同 text 不 skip")
    func tombstoneClearsPendingEntry() {
        var tracker = OptimisticDeleteTracker(gracePeriod: 3)
        let now = Date()
        let target = makeText(id: "target", origin: "self", text: "shared")

        _ = tracker.markDeleted(target, in: [target], now: now)
        #expect(tracker.pendingCount.textFulls == 1)
        #expect(tracker.pendingCount.ids == 1)

        // server cascade tombstone 到达(deletedAtNs 非 nil)
        var tombstone = makeText(id: "target", origin: "self", text: "shared")
        tombstone.deletedAtNs = Int64(now.addingTimeInterval(0.5).timeIntervalSince1970 * 1e9)
        _ = tracker.observeIncoming([tombstone], now: now.addingTimeInterval(0.5))

        #expect(tracker.pendingCount.textFulls == 0, "tombstone 清 pendingTextFulls")
        #expect(tracker.pendingCount.ids == 0, "tombstone 清 pendingIds")

        // 0.5s 后(仍在 grace 内)有个新 capture 同 text 进来——不应被 skip
        let fresh = makeText(id: "fresh", origin: "peer", text: "shared")
        let outcome = tracker.observeIncoming([fresh], now: now.addingTimeInterval(1))

        #expect(outcome.skipIds.isEmpty, "tombstone 已清 pending,新行不再被 skip")
        #expect(outcome.resurrectedIds.isEmpty)
    }

    /// **C4**:text-kind(`blob_sha256 == nil && text_full 非空`)才 cascade.
    /// blob-kind(image)按 id 单删——跟 server `Database.softDelete` cascade 范围
    /// 对齐(同 sha 多次复制可能是用户故意保留时间线,不折叠也不 cascade 删除).
    @Test("blob-kind 不 cascade,只删单 id")
    func blobKindNoCascade() {
        var tracker = OptimisticDeleteTracker()
        let img1 = makeImage(id: "img1", origin: "self", sha: "abc")
        let img2 = makeImage(id: "img2", origin: "peer", sha: "abc")  // 同 sha sibling

        let ids = tracker.markDeleted(img1, in: [img1, img2])

        #expect(ids == ["img1"], "blob-kind 不参与 cascade,同 sha sibling img2 留着")
        #expect(tracker.pendingCount.textFulls == 0, "blob-kind 不进 pendingTextFulls")
        #expect(tracker.pendingCount.ids == 1, "只有 img1 进 pendingIds")
    }

    /// **C5**:60s 后 pending entry 被 prune.防 dict 无限增长 + Mac 长时间不可达
    /// 用户已经"等够久"再看到行不该再弹 banner(假设用户已接受这条状态).
    @Test("60s 后 prune,sibling 不再 skip / 不弹 banner")
    func pruneAfter60s() {
        var tracker = OptimisticDeleteTracker(gracePeriod: 3, prunePeriod: 60)
        let now = Date()
        let target = makeText(id: "target", origin: "self", text: "shared")

        _ = tracker.markDeleted(target, in: [target], now: now)
        #expect(tracker.pendingCount.textFulls == 1)
        #expect(tracker.pendingCount.ids == 1)

        // 61s 后 in-flight /since 把同 text sibling 带回
        let later = now.addingTimeInterval(61)
        let sibling = makeText(id: "mirror", origin: "peer", text: "shared")
        let outcome = tracker.observeIncoming([sibling], now: later)

        #expect(outcome.skipIds.isEmpty, "60s 后 prune,sibling 不再被 skip")
        #expect(outcome.resurrectedIds.isEmpty, "60s 后 prune,不再当 resurrected 弹 banner")
        #expect(tracker.pendingCount.textFulls == 0, "pendingTextFulls 已被 prune")
        #expect(tracker.pendingCount.ids == 0, "pendingIds 已被 prune")
    }
}

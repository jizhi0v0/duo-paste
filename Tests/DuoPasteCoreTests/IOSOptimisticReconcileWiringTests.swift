import Foundation
import Testing
@testable import DuoPasteCore

/// iOS `HistoryStore` 是 `@MainActor @Observable` + UIKit-adjacent，SwiftPM 测试拉不起来，
/// 但这两条 bug 的本质都是**一处接线**，可以直接对源码断言（沿用
/// `DocumentationContractTests` 读仓库文件的做法）。
///
/// 背景：R2.1 把 item 所有权搬进 SQLite mirror 后，`HistoryStore.merge(_:)` 的调用方
/// `applyPage(items:nextCursor:)` 被 `MetadataMirrorStore.synchronize` 取代，两个函数一起
/// 成了死代码。`merge` 里"把 incoming 并进内存数组"那半边确实被 `refreshFromMirror()`
/// 取代了，但它同时承担的三件对账工作没有任何替代品，于是静默失效：
///   1. 删除未送达 → `optimisticallyDeletedIDs` 永不释放，橙色 banner 永不出现
///   2. 非 owner pin → 「等待同步」永不清除（`markPinApplied` 只在 `applied` 时调）
///   3. tombstone → overlay 表无界增长
private func historyStoreSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent("iOS/DuoPaste/HistoryStore.swift"),
        encoding: .utf8
    )
}

@Test func historyStoreWiresPerPageReconciliationIntoProductionSync() throws {
    let source = try historyStoreSource()

    #expect(
        source.contains("func reconcileOptimisticState(with incoming: [Item])"),
        "乐观状态对账函数不见了"
    )
    #expect(
        source.contains("onPageApplied:"),
        """
        `synchronizeMetadata` 没把 onPageApplied 传给 MetadataMirrorStore.synchronize —— \
        canonical 行不再经过任何本地对账，删除未送达 banner 与 pin「等待同步」会再次静默失效
        """
    )
    #expect(
        source.contains("await self.reconcileOptimisticState(with: pageItems)"),
        "onPageApplied 必须真的调 reconcileOptimisticState，而不是挂个空闭包"
    )

    // 对账必须覆盖三类：resurrected（banner）、pin 达成目标值、tombstone 清场
    #expect(source.contains("outcome.resurrectedIds"))
    #expect(source.contains("deleteFailureMessage ="))
    #expect(source.contains("pendingPinTargets.removeValue"))
}

/// 死代码不能回来：`merge` / `applyPage` 一旦复活，就会再次出现"看起来有人处理了"
/// 的假象，而真正的生产路径依然不经过它们。
@Test func deadMergePathIsNotResurrected() throws {
    let source = try historyStoreSource()
    #expect(
        !source.contains("func merge(_ incoming: [Item])"),
        "HistoryStore.merge 已被 reconcileOptimisticState 取代；恢复它会重新制造死代码假象"
    )
    #expect(
        !source.contains("func applyPage(items incoming:"),
        "HistoryStore.applyPage 没有生产调用方；同步统一走 MetadataMirrorStore.synchronize"
    )
}

/// 取消后不得把 activity 留在 `.syncing`——那会让 `reloadSyncCheckpoint` 开头的
/// `guard activity != .syncing` 永久短路，用户只能重启 app。
@Test func cancelledSyncNeverLeavesActivitySyncing() throws {
    let source = try historyStoreSource()

    #expect(
        source.contains("guard !Task.isCancelled else { return }"),
        "applySyncProgress 缺少取消守卫：取消瞬间刚提交的一页会把 activity 推回 .syncing"
    )
    #expect(
        source.contains("private func resolveCancelledSyncActivity()"),
        "缺少取消收尾兜底"
    )
    // 两条取消出口都要收尾
    let occurrences = source.components(separatedBy: "resolveCancelledSyncActivity()").count - 1
    #expect(
        occurrences >= 3,
        "定义 + 两条 CancellationError 出口都要调用，实际出现 \(occurrences) 次"
    )
    // 兜底绝不能写 UserDefaults —— route 切换不是用户的暂停意图。
    // 只截取该函数自身的 body（到第一个 4 空格缩进的收尾花括号），别误伤紧随其后的
    // `markSyncPaused()` 定义。
    if let declaration = source.range(of: "private func resolveCancelledSyncActivity()") {
        let afterDeclaration = source[declaration.upperBound...]
        let body = afterDeclaration.range(of: "\n    }").map {
            String(afterDeclaration[..<$0.lowerBound])
        } ?? String(afterDeclaration)
        #expect(
            !body.contains("markSyncPaused"),
            "兜底调 markSyncPaused 会写 syncPausedDefaultsKey，把用户级自动同步一起关掉"
        )
        #expect(body.contains("syncStatus.activity = .idle"))
        #expect(body.contains("guard syncStatus.activity == .syncing"))
    }
}

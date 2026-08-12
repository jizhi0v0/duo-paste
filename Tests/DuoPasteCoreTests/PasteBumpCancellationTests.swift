import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

/// paste 收尾路径的两条契约。
///
/// 背景：paste 成功后要 `panel.hide(immediate: true)` 同步让出 key window，而 `hide` 会
/// 同步走 `finalizeHideImmediate → onDismiss → cancelLazyPasteIfAny`，取消
/// `currentPasteTask`——那一刻它指向的正是**执行这段收尾代码的 task 自己**。于是随后的
/// `await bumpUsedItems(...)` 跑在已取消的 task 里，GRDB 抛 `CancellationError` 被 `try?`
/// 吞掉，"用过即顶" + `state.refresh()` 双双静默失效。
///
/// 第一条钉住机制（GRDB 确实遵循 task cancellation），第二条钉住 AppDelegate 的接线。

// MARK: - 机制：已取消的 task 里 GRDB 写入不会发生

@Test func selfCancelledTaskSkipsBumpEntirely() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-paste-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let db = try Database(path: dir.appendingPathComponent("main.sqlite"))
    let item = Item(
        id: UUIDv7.generateString(),
        originDevice: "self-mac",
        capturedAtNs: 1_000,
        ingestedAtNs: 1_000,
        kind: .text,
        preview: "hi",
        textFull: "hi"
    )
    try await db.pool.write { try item.insert($0) }

    // 复刻 AppDelegate 的形状：task 取消自己，然后继续 await 一次 DB 写
    let outcome = await Task { () -> String in
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try await db.bumpCapturedAt(id: item.id, now: 9_000)
            return "bumped"
        } catch is CancellationError {
            return "cancelled"
        } catch {
            return "other: \(error)"
        }
    }.value

    #expect(outcome == "cancelled", "GRDB async 写入必须遵循 task cancellation")
    let after = try await db.pool.read { try Item.fetchOne($0, key: item.id) }
    #expect(
        after?.capturedAtNs == 1_000,
        "写入没被跳过的话本条契约就不成立了——detachCompletedPasteTask 也就没必要存在"
    )
}

/// 对照组：没有自我取消时同一次 bump 必须真的发生。防止上面那条被"bump 本来就坏了"
/// 这种原因误判成通过。
@Test func uncancelledTaskDoesBump() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-paste-cancel-ok-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let db = try Database(path: dir.appendingPathComponent("main.sqlite"))
    let item = Item(
        id: UUIDv7.generateString(),
        originDevice: "self-mac",
        capturedAtNs: 1_000,
        ingestedAtNs: 1_000,
        kind: .text,
        preview: "hi",
        textFull: "hi"
    )
    try await db.pool.write { try item.insert($0) }

    _ = try await Task { try await db.bumpCapturedAt(id: item.id, now: 9_000) }.value

    let after = try await db.pool.read { try Item.fetchOne($0, key: item.id) }
    #expect(after?.capturedAtNs == 9_000)
}

// MARK: - 接线：每条注册了 currentPasteTask 的 paste 路径都要先注销再 hide

/// 源码级契约。AppDelegate 是 `@MainActor` + AppKit 全家桶，单测拉不起来；但这条 bug 的
/// 本质是**一行接线**，可以直接对源码断言：凡是在 `currentPasteTask = Task { … }` 里调
/// `bumpUsedItems` 的路径，块内必须出现 `detachCompletedPasteTask()`。
///
/// 不受约束的是 `pasteBackSingle` 快路径——它用裸 `Task {}`，从没注册进 currentPasteTask，
/// 因此不会自我取消（这也解释了为什么日常单条 Enter 粘贴看不出问题）。
@Test func everyRegisteredPastePathDetachesBeforeHiding() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Sources/duo-pasted/AppDelegate.swift"),
        encoding: .utf8
    )
    let lines = source.components(separatedBy: "\n")

    var registeredPaths = 0
    var unregisteredPaths = 0
    for (index, line) in lines.enumerated() where line.contains("await self.bumpUsedItems(") {
        guard let taskStart = (0..<index).reversed().first(where: {
            lines[$0].contains("Task { @MainActor")
        }) else {
            Issue.record("bumpUsedItems 调用点 (line \(index + 1)) 找不到所属 Task 起始行")
            continue
        }
        let body = lines[taskStart...index]
        guard lines[taskStart].contains("currentPasteTask = Task") else {
            unregisteredPaths += 1
            continue
        }
        registeredPaths += 1
        #expect(
            body.contains(where: { $0.contains("detachCompletedPasteTask()") }),
            """
            AppDelegate.swift line \(index + 1)：这条 paste 路径把 task 存进了 currentPasteTask，
            却没在 panel.hide 之前调 detachCompletedPasteTask()——hide 会同步触发 onDismiss
            取消这个 task 自己，随后的 bumpUsedItems 会被 GRDB 的 CancellationError 静默吞掉
            """
        )
        // 注销必须发生在 hide **之前**，否则 task 已经被取消了才注销，无济于事
        if let detachAt = body.firstIndex(where: { $0.contains("detachCompletedPasteTask()") }),
           let hideAt = body.firstIndex(where: { $0.contains("panel.hide(immediate: true)") }) {
            #expect(detachAt < hideAt, "detachCompletedPasteTask() 必须在 panel.hide 之前")
        }
    }

    #expect(registeredPaths == 5, "注册型 paste 路径数量变了（现为 \(registeredPaths)）——新增路径也要遵守本契约")
    #expect(unregisteredPaths == 1, "快路径 pasteBackSingle 应当仍是唯一不注册 currentPasteTask 的路径")
}

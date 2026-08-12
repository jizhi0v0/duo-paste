import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

/// `PullWorker.applyPage` 写 peer 行必须走 `ON CONFLICT(id) DO UPDATE`，不能是
/// `INSERT OR REPLACE`。REPLACE 为满足 PK 约束先 DELETE 冲突行，带来三个错误副作用：
///
/// 1. `ON DELETE CASCADE` 把该 item 的 v13 `pin_operation` 队列行删掉（pin 命令丢失）
/// 2. 不触发 `item_ad`（SQLite：REPLACE 删行时 delete trigger 只在 `recursive_triggers`
///    打开才 fire），FTS5 留下永不回收的孤儿行
/// 3. 走 `item_ai` 而非 `item_au`，只标 new group dirty，老 search_fold group 不重算
///
/// 三条各钉一个测试。
private func makeDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-upsert-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func peerItem(
    id: String,
    ingestedAtNs: Int64,
    text: String,
    pinned: Bool = false
) -> Item {
    Item(
        id: id,
        originDevice: "peer-b",
        capturedAtNs: ingestedAtNs,
        ingestedAtNs: ingestedAtNs,
        kind: .text,
        sourceAppName: "Test",
        preview: text,
        textFull: text,
        pinned: pinned
    )
}

private func replayPage(_ items: [Item]) -> SincePageWire {
    SincePageWire(
        ok: true,
        count: items.count,
        items: items,
        nextCursor: SinceCursor(ingestedAtNs: items.last?.ingestedAtNs ?? 0, id: items.last?.id ?? ""),
        hasMore: false
    )
}

private actor OnePageTransport: SinceTransport {
    private var pages: [SincePageWire]
    init(_ pages: [SincePageWire]) { self.pages = pages }

    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        await pop()
    }

    private func pop() -> RemoteSinceResult {
        guard !pages.isEmpty else {
            return RemoteSinceResult(outcome: .unreachable(reason: "drained"))
        }
        return RemoteSinceResult(outcome: .ok(pages.removeFirst()))
    }

    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        PrimaryHealthResult(outcome: .ok(deviceID: "peer-b", nowMs: 1_000, ponteHost: nil))
    }
}

private func runWorker(db: DuoDB, pages: [SincePageWire]) async {
    let worker = PullWorker(
        database: db,
        transport: OnePageTransport(pages),
        selfDeviceID: "self-mac",
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60),
        nowNs: { 5_000 }
    )
    await runPullWorkerToCompletion(worker)
}

/// #1 —— 核心回归：排队中的 owner-routed pin 命令不能被 `/since` 重放冲掉。
@Test func peerRowReplayPreservesQueuedPinOperation() async throws {
    let db = try makeDB()
    // peer-b 的行先入表（首次 mirror）
    await runWorker(db: db, pages: [replayPage([
        peerItem(id: "x-1", ingestedAtNs: 100, text: "shared text"),
    ])])

    // 本机（非 owner）提交 pin 意图 → 写 pin_operation + 乐观改 pinned
    let submitted = try await db.submitPinIntent(
        id: "x-1",
        pinned: true,
        operationID: "op-1",
        selfDeviceID: "self-mac",
        now: 2_000
    )
    guard case .pending = submitted else {
        Issue.record("非 owner 提交应该是 pending，实际 \(submitted)")
        return
    }
    let queuedBefore = try await db.pendingPinOperations(originDevice: "peer-b")
    #expect(queuedBefore.count == 1)

    // 命令还没投递成功，peer 的 /since 又把同一行重放回来（OCR / bump / 三设备 mesh）
    await runWorker(db: db, pages: [replayPage([
        peerItem(id: "x-1", ingestedAtNs: 300, text: "shared text"),
    ])])

    let queuedAfter = try await db.pendingPinOperations(originDevice: "peer-b")
    #expect(queuedAfter.count == 1, "canonical replay 不得删除排队中的 pin_operation")
    #expect(queuedAfter.first?.operationID == "op-1")
    // 乐观值也必须保住——applyPage 用 activePin.desiredPinned 写 pinned
    let pinned = try await db.pool.read { conn in
        try Bool.fetchOne(conn, sql: "SELECT pinned FROM item WHERE id = 'x-1'")
    }
    #expect(pinned == true)
}

/// #2 —— FTS5 孤儿行：重放同一 id 不能让索引里留下旧正文。
@Test func peerRowReplayDoesNotLeakOrphanFTSRows() async throws {
    let db = try makeDB()
    await runWorker(db: db, pages: [replayPage([
        peerItem(id: "x-1", ingestedAtNs: 100, text: "zebrafish marker"),
    ])])
    // 同 id 重放三次（模拟 pin / bump / OCR 回放）
    for (i, ns) in [200, 300, 400].enumerated() {
        await runWorker(db: db, pages: [replayPage([
            peerItem(id: "x-1", ingestedAtNs: Int64(ns), text: "zebrafish marker \(i)"),
        ])])
    }

    let (itemRows, ftsHits) = try await db.pool.read { conn in
        (
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item WHERE id = 'x-1'") ?? -1,
            try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(*) FROM item_fts WHERE item_fts MATCH 'zebrafish'"
            ) ?? -1
        )
    }
    #expect(itemRows == 1)
    #expect(ftsHits == 1, "每次重放都泄漏一条 FTS 行 = 回退到了 INSERT OR REPLACE")
}

/// #3 —— search_fold dirty：text_full 变化时**老** group key 也必须进 dirty 队列，
/// 否则老的折叠展示行留在 projection 里，空搜索会看到已经不存在的内容。
@Test func peerRowReplayMarksOldFoldGroupDirty() async throws {
    let db = try makeDB()
    await runWorker(db: db, pages: [replayPage([
        peerItem(id: "x-1", ingestedAtNs: 100, text: "old body"),
    ])])
    try db.rebuildSearchFoldProjection()

    // 正文变了（例如对端修正后重推）→ group key 从 "old body" 变成 "new body"
    await runWorker(db: db, pages: [replayPage([
        peerItem(id: "x-1", ingestedAtNs: 200, text: "new body"),
    ])])

    let dirtyKeys = try await db.pool.read { conn in
        try String.fetchAll(
            conn,
            sql: "SELECT group_key FROM search_fold_dirty WHERE group_type = 'text' ORDER BY group_key"
        )
    }
    #expect(dirtyKeys.contains("old body"), "老 fold group 没被标 dirty，projection 会留下陈旧行")
    #expect(dirtyKeys.contains("new body"))

    // 刷新后 projection 只剩新内容
    let hits = try SearchAPI(database: db).searchSummary(SearchQuery(limit: 50))
    #expect(hits.hits.count == 1)
    #expect(hits.hits.first?.0.textFull == "new body")
}

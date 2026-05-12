import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

private func makeClientDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-audit-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB, role: .client)
}

private func insertItem(
    _ db: DuoDB,
    id: String,
    origin: String,
    pushState: PushState,
    pushAttempts: Int = 0,
    lastError: String? = nil
) async throws {
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
               push_state, push_attempts, last_push_error)
            VALUES (?, ?, ?, ?, 'text', NULL, NULL, ?, ?, NULL, NULL, NULL, 0, NULL,
                    ?, ?, ?)
        """, arguments: [id, origin, 100, 100, id, id,
                         pushState.rawValue, pushAttempts, lastError])
    }
}

private func pageOf(_ ids: [String]) -> SincePageWire {
    let items = ids.enumerated().map { (i, id) in
        Item(id: id, originDevice: "other",
             capturedAtNs: Int64(i + 1), ingestedAtNs: Int64(i + 1),
             kind: .text, preview: id, textFull: id,
             pushState: .acked)
    }
    return SincePageWire(
        ok: true, count: items.count, items: items,
        nextCursor: SinceCursor(ingestedAtNs: Int64(items.count), id: ids.last ?? ""),
        hasMore: false
    )
}

@Test func auditDetectsMissingOwnItemsOnPrimary() async throws {
    let db = try makeClientDB()
    let self_ = "mbp"
    try await insertItem(db, id: "own-1", origin: self_, pushState: .acked)
    try await insertItem(db, id: "own-2", origin: self_, pushState: .pending)
    try await insertItem(db, id: "own-3", origin: self_, pushState: .failed, pushAttempts: 5, lastError: "timeout")
    try await insertItem(db, id: "other-x", origin: "mini", pushState: .acked)  // 不该参与 audit

    // primary 只承认 own-1，own-2 / own-3 还没到达
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: self_,
        fetchPage: { _, _ in pageOf(["own-1"]) }
    )

    #expect(report.localOwnTotal == 3)
    #expect(report.acked == 1)
    #expect(report.pending == 1)
    #expect(report.failed == 1)
    #expect(report.primaryItemTotal == 1)
    #expect(report.missingTotal == 2)
    #expect(Set(report.missingOnPrimary) == Set(["own-2", "own-3"]))
    #expect(report.failedSamples.count == 1)
    #expect(report.failedSamples.first?.id == "own-3")
    #expect(report.failedSamples.first?.lastError == "timeout")
    #expect(report.failedSamples.first?.attempts == 5)
}

@Test func auditCleanWhenAllAcked() async throws {
    let db = try makeClientDB()
    try await insertItem(db, id: "a", origin: "self", pushState: .acked)
    try await insertItem(db, id: "b", origin: "self", pushState: .acked)

    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "self",
        fetchPage: { _, _ in pageOf(["a", "b", "extra-from-primary"]) }
    )
    #expect(report.missingTotal == 0)
    #expect(report.failed == 0)
    #expect(report.pending == 0)
    #expect(report.acked == 2)
    #expect(report.primaryItemTotal == 3)
}

@Test func auditFollowsPaginationUntilHasMoreFalse() async throws {
    let db = try makeClientDB()
    try await insertItem(db, id: "p1", origin: "s", pushState: .acked)
    try await insertItem(db, id: "p2", origin: "s", pushState: .acked)
    try await insertItem(db, id: "p3", origin: "s", pushState: .acked)

    // 三页 /since，cursor 严格推进，模拟真实 server 行为
    actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
    let counter = Counter()
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "s",
        fetchPage: { _, _ in
            let n = await counter.next()
            switch n {
            case 1:
                return SincePageWire(ok: true, count: 1,
                    items: [Item(id: "p1", originDevice: "s", capturedAtNs: 1, ingestedAtNs: 1,
                                 kind: .text, preview: "p1", textFull: "p1", pushState: .acked)],
                    nextCursor: SinceCursor(ingestedAtNs: 1, id: "p1"), hasMore: true)
            case 2:
                return SincePageWire(ok: true, count: 1,
                    items: [Item(id: "p2", originDevice: "s", capturedAtNs: 2, ingestedAtNs: 2,
                                 kind: .text, preview: "p2", textFull: "p2", pushState: .acked)],
                    nextCursor: SinceCursor(ingestedAtNs: 2, id: "p2"), hasMore: true)
            default:
                return SincePageWire(ok: true, count: 1,
                    items: [Item(id: "p3", originDevice: "s", capturedAtNs: 3, ingestedAtNs: 3,
                                 kind: .text, preview: "p3", textFull: "p3", pushState: .acked)],
                    nextCursor: SinceCursor(ingestedAtNs: 3, id: "p3"), hasMore: false)
            }
        }
    )
    #expect(report.primaryItemTotal == 3)
    #expect(report.missingTotal == 0)
}

@Test func auditAbortsOnStuckCursor() async throws {
    // server bug 模拟：hasMore=true 但 cursor 不推进 → 应该报 pageLoopGuard，不能死循环
    let db = try makeClientDB()
    try await insertItem(db, id: "a", origin: "s", pushState: .acked)
    let stuck = SincePageWire(
        ok: true, count: 0, items: [],
        nextCursor: SinceCursor.zero, hasMore: true
    )
    await #expect(throws: AuditPush.AuditError.self) {
        _ = try await AuditPush.run(
            database: db,
            selfDeviceID: "s",
            fetchPage: { _, _ in stuck }
        )
    }
}

@Test func auditTruncatesSamplesAtLimit() async throws {
    let db = try makeClientDB()
    for i in 0..<10 {
        try await insertItem(db, id: "m-\(i)", origin: "self", pushState: .pending)
    }
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "self",
        fetchPage: { _, _ in pageOf([]) },
        sampleLimit: 3
    )
    #expect(report.missingTotal == 10)
    #expect(report.missingOnPrimary.count == 3)
}

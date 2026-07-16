import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

private typealias PinDB = DuoPasteCore.Database

private func makePinOperationDB(_ prefix: String = "duo-pin-op") throws -> (PinDB, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return (try PinDB(path: paths.mainDB), paths.mainDB)
}

private func insertPinItem(
    _ database: PinDB,
    id: String = "item-1",
    origin: String,
    pinned: Bool = false,
    ingested: Int64 = 100
) async throws {
    let item = Item(
        id: id,
        originDevice: origin,
        capturedAtNs: 100,
        ingestedAtNs: ingested,
        kind: .text,
        preview: "pin me",
        textFull: "pin me",
        pinned: pinned
    )
    try await database.pool.write { db in try item.insert(db) }
}

@Suite("Owner-routed pin operations")
struct PinOperationTests {
    @Test func v13MigrationCreatesQueueAndReceiptTables() async throws {
        let (database, _) = try makePinOperationDB()
        let tables = try await database.pool.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name LIKE 'pin_operation%'
            """))
        }
        #expect(tables.contains("pin_operation"))
        #expect(tables.contains("pin_operation_receipt"))

        await #expect(throws: (any Error).self) {
            try await database.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO pin_operation
                      (operation_id, item_id, origin_device, desired_pinned, state,
                       created_at_ns, updated_at_ns)
                    VALUES ('invalid', 'missing-item', 'owner', 2, 'pending', 1, 1)
                """)
            }
        }
    }

    @Test func ownerAppliesOnceAndDuplicateOperationDoesNotBumpAgain() async throws {
        let (database, path) = try makePinOperationDB()
        try await insertPinItem(database, origin: "owner")

        let first = try await database.submitPinIntent(
            id: "item-1",
            pinned: true,
            operationID: "op-stable",
            selfDeviceID: "owner",
            now: 1_000
        )
        guard case .applied(_, let firstNs, let duplicate) = first else {
            Issue.record("owner command should apply")
            return
        }
        #expect(!duplicate)
        #expect(firstNs > 100)

        let retry = try await database.submitPinIntent(
            id: "item-1",
            pinned: true,
            operationID: "op-stable",
            selfDeviceID: "owner",
            now: 9_000
        )
        guard case .applied(_, let retryNs, let retryDuplicate) = retry else {
            Issue.record("retry should return receipt")
            return
        }
        #expect(retryDuplicate)
        #expect(retryNs == firstNs)
        let item = try await database.pool.read { db in
            try Item.filter(Column("id") == "item-1").fetchOne(db)!
        }
        #expect(item.pinned)
        #expect(item.ingestedAtNs == firstNs)

        let reopenedOwner = try PinDB(path: path)
        let afterRestart = try await reopenedOwner.pool.read { db in
            try Item.filter(Column("id") == "item-1").fetchOne(db)!
        }
        #expect(afterRestart.pinned, "owner daemon restart must preserve canonical pin")
        #expect(afterRestart.ingestedAtNs == firstNs)

        // OCR / metadata workers update the owner row and advance its canonical cursor, but
        // must never reconstruct the row with a default pinned=false value.
        let metadataNs = try await reopenedOwner.pool.write { db in
            let ns = try PinDB.nextIngestNs(db, now: 12_000)
            try db.execute(
                sql: """
                    UPDATE item
                    SET ocr_state = 'done',
                        extracted_text = 'recognized text',
                        extracted_text_source = 'ocr',
                        ingested_at_ns = ?
                    WHERE id = ?
                    """,
                arguments: [ns, "item-1"]
            )
            return ns
        }
        let afterMetadataUpdate = try await reopenedOwner.pool.read { db in
            try Item.filter(Column("id") == "item-1").fetchOne(db)!
        }
        #expect(afterMetadataUpdate.pinned, "owner OCR/metadata update must preserve canonical pin")
        #expect(afterMetadataUpdate.ingestedAtNs == metadataNs)

        await #expect(throws: PinOperationError.operationIDConflict) {
            try await database.submitPinIntent(
                id: "item-1",
                pinned: false,
                operationID: "op-stable",
                selfDeviceID: "owner",
                now: 10_000
            )
        }
    }

    @Test func mirrorQueuesOptimisticallyWithoutForgingCanonicalCursorAndSurvivesReopen() async throws {
        let (database, path) = try makePinOperationDB()
        try await insertPinItem(database, origin: "owner-a", ingested: 333)
        let result = try await database.submitPinIntent(
            id: "item-1",
            pinned: true,
            operationID: "queued-op",
            selfDeviceID: "mirror-b",
            now: 2_000
        )
        guard case .pending(let operation) = result else {
            Issue.record("mirror command should queue")
            return
        }
        #expect(operation.originDevice == "owner-a")
        let local = try await database.pool.read { db in
            try Item.filter(Column("id") == "item-1").fetchOne(db)!
        }
        #expect(local.pinned)
        #expect(local.ingestedAtNs == 333, "mirror optimistic update must not advance /since cursor")

        // 第二个 Database 实例模拟 daemon reopen；queue 是 SQLite 持久态，不依赖内存 task。
        let reopened = try PinDB(path: path)
        let pending = try await reopened.pendingPinOperations(originDevice: "owner-a")
        #expect(pending.map(\.operationID) == ["queued-op"])
        #expect(try await reopened.pendingPinItemIDs() == ["item-1"])
    }

    @Test func rapidReverseReplacesOlderIntentWithLastAbsoluteTarget() async throws {
        let (database, _) = try makePinOperationDB()
        try await insertPinItem(database, origin: "owner-a")

        _ = try await database.submitPinIntent(
            id: "item-1", pinned: true, operationID: "older-pin",
            selfDeviceID: "mirror-b", now: 200
        )
        _ = try await database.submitPinIntent(
            id: "item-1", pinned: false, operationID: "newer-unpin",
            selfDeviceID: "mirror-b", now: 201
        )

        let pending = try await database.pendingPinOperations(originDevice: "owner-a")
        #expect(pending.map(\.operationID) == ["newer-unpin"])
        #expect(pending.map(\.desiredPinned) == [false])
        let item = try await database.pool.read { db in
            try Item.filter(Column("id") == "item-1").fetchOne(db)!
        }
        #expect(!item.pinned)
    }

    @Test func canonicalReplayClearsPendingOnlyAfterReceiptCursorIsObserved() async throws {
        let (database, _) = try makePinOperationDB()
        try await insertPinItem(database, origin: "owner-a", ingested: 100)
        _ = try await database.submitPinIntent(
            id: "item-1", pinned: true, operationID: "op-replay",
            selfDeviceID: "mirror-b", now: 200
        )
        try await database.markPinOperationDelivered(
            operationID: "op-replay", ownerIngestedAtNs: 500, now: 300
        )

        let stale = Item(
            id: "item-1", originDevice: "owner-a", capturedAtNs: 100,
            ingestedAtNs: 499, kind: .text, preview: "pin me", textFull: "pin me",
            pinned: false
        )
        try await database.pool.write { db in
            let operation = try PinDB.activePinOperation(db, itemID: stale.id)
            _ = try PinDB.resolvePinOperationReplayIfNeeded(db, operation: operation, incoming: stale, now: 400)
        }
        #expect(try await database.pendingPinItemIDs() == ["item-1"])

        let replay = Item(
            id: "item-1", originDevice: "owner-a", capturedAtNs: 100,
            ingestedAtNs: 500, kind: .text, preview: "pin me", textFull: "pin me",
            pinned: true
        )
        try await database.pool.write { db in
            let operation = try PinDB.activePinOperation(db, itemID: replay.id)
            _ = try PinDB.resolvePinOperationReplayIfNeeded(db, operation: operation, incoming: replay, now: 500)
        }
        #expect(try await database.pendingPinItemIDs().isEmpty)

        let retry = try await database.submitPinIntent(
            id: "item-1", pinned: true, operationID: "op-replay",
            selfDeviceID: "mirror-b", now: 600
        )
        guard case .applied(_, let ns, let duplicate) = retry else {
            Issue.record("converged mirror should retain receipt")
            return
        }
        #expect(duplicate)
        #expect(ns == 500)
    }
}

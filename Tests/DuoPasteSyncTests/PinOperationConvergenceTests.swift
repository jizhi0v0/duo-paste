import Foundation
import GRDB
import Testing
import DuoPasteCore
@testable import DuoPasteSync

private typealias ConvergenceDB = DuoPasteCore.Database

private func convergenceItem(pinned: Bool = false, ingested: Int64 = 100) -> Item {
    Item(
        id: "shared-item",
        originDevice: "owner-a",
        capturedAtNs: 100,
        ingestedAtNs: ingested,
        kind: .text,
        preview: "shared",
        textFull: "shared",
        pinned: pinned
    )
}

private func makeConvergenceMirror() throws -> ConvergenceDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-pin-convergence-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try ConvergenceDB(path: paths.mainDB)
}

@Suite(.serialized)
struct PinOperationConvergenceTests {
    @Test func mirrorRoutesPinAndUnpinToOwnerAndConvergesWithoutDuplicateApply() async throws {
        let fixture = try TestSyncServerFixture(
            prefix: "duo-pin-owner",
            items: [convergenceItem()],
            secretByte: 0x71
        )
        let ownerServer = SyncServer(
            deviceID: "owner-a",
            database: fixture.database,
            blobs: fixture.blobs,
            host: "127.0.0.1",
            port: 0,
            auth: fixture.auth
        )
        try await fixture.withServer(ownerServer) { baseURL in
            let mirror = try makeConvergenceMirror()
            try await mirror.pool.write { db in try convergenceItem().insert(db) }
            let queued = try await mirror.submitPinIntent(
                id: "shared-item",
                pinned: true,
                operationID: "ios-shared-operation",
                selfDeviceID: "mirror-b",
                now: 200
            )
            guard case .pending(let operation) = queued else {
                Issue.record("mirror should queue owner-routed operation")
                return
            }
            let client = HTTPPeerClient(baseURL: baseURL, auth: fixture.auth)
            let worker = PullWorker(
                database: mirror,
                transport: client,
                pinTransport: client,
                selfDeviceID: "mirror-b",
                expectedPeerDeviceID: "owner-a",
                meshStatus: MeshStatus(),
                config: .init(intervalSec: 60, storageMode: .optimized)
            )
            await worker.start()
            try await Task.sleep(for: .milliseconds(450))
            await worker.stop()

            let ownerPinned = try await fixture.database.pool.read { db in
                try Item.filter(Column("id") == "shared-item").fetchOne(db)!
            }
            let mirrorPinned = try await mirror.pool.read { db in
                try Item.filter(Column("id") == "shared-item").fetchOne(db)!
            }
            #expect(ownerPinned.pinned)
            #expect(mirrorPinned.pinned)
            #expect(try await mirror.pendingPinItemIDs().isEmpty)

            // iOS fan-out / network retry sends same operation ID to owner again: receipt returns
            // same cursor and must not perform a second write.
            let retry = try await client.submitPinOperation(operation)
            guard case .applied(let retryNs) = retry.outcome else {
                Issue.record("owner retry should return applied receipt")
                return
            }
            #expect(retryNs == ownerPinned.ingestedAtNs)
            let receiptCount = try await fixture.database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pin_operation_receipt") ?? 0
            }
            #expect(receiptCount == 1)

            // owner 后续 bump 只改时间/cursor，canonical pinned 必须保留。
            _ = try await fixture.database.bumpCapturedAt(id: "shared-item", now: retryNs + 10)
            let afterBump = try await fixture.database.pool.read { db in
                try Item.filter(Column("id") == "shared-item").fetchOne(db)!
            }
            #expect(afterBump.pinned)

            _ = try await mirror.submitPinIntent(
                id: "shared-item",
                pinned: false,
                operationID: "unpin-operation",
                selfDeviceID: "mirror-b",
                now: retryNs + 20
            )
            await worker.start()
            try await Task.sleep(for: .milliseconds(450))
            await worker.stop()
            let finalOwner = try await fixture.database.pool.read { db in
                try Item.filter(Column("id") == "shared-item").fetchOne(db)!
            }
            let finalMirror = try await mirror.pool.read { db in
                try Item.filter(Column("id") == "shared-item").fetchOne(db)!
            }
            #expect(!finalOwner.pinned)
            #expect(!finalMirror.pinned)
            #expect(try await mirror.pendingPinItemIDs().isEmpty)
        }
    }
}

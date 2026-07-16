import Foundation
import GRDB
import Testing
import DuoPasteCore
@testable import DuoPasteSync

private typealias RecoveryDB = DuoPasteCore.Database

private func drItem(
    id: String,
    origin: String,
    captured: Int64,
    ingested: Int64,
    kind: ItemKind = .text,
    sha: String? = nil,
    deleted: Int64? = nil
) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: captured,
        ingestedAtNs: ingested,
        kind: kind,
        preview: id,
        textFull: kind == .text ? id : nil,
        blobSha256: sha,
        blobSize: sha == nil ? nil : 0,
        blobMime: sha == nil ? nil : "image/png",
        deletedAtNs: deleted
    )
}

private struct FailingDRTransport: SinceTransport, BlobFetcher {
    func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        PrimaryHealthResult(outcome: .unreachable(reason: "offline"))
    }

    func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        RemoteSinceResult(outcome: .unreachable(reason: "offline"))
    }

    func getBlob(sha256: String) async throws -> GetBlobOutcome { .notFound }
}

@Suite(.serialized)
struct DisasterRecoveryTests {
    @Test func corruptDBRestoresSnapshotRefillsOwnOriginTombstoneAndBlobThenRestarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duo-dr-e2e-\(UUID().uuidString)", isDirectory: true)
        let livePaths = Paths(root: root)
        livePaths.ensureExists()
        let liveDatabase = try RecoveryDB(path: livePaths.mainDB)

        let ownOld = drItem(
            id: "own-old", origin: "self-a", captured: 100, ingested: 100
        )
        let peerBeforeDelete = drItem(
            id: "peer-dead", origin: "peer-b", captured: 150, ingested: 150
        )
        try await liveDatabase.pool.write { db in
            try ownOld.insert(db)
            try peerBeforeDelete.insert(db)
        }
        let snapshot = try Snapshot.takeSnapshot(
            database: liveDatabase,
            paths: livePaths,
            now: Date(timeIntervalSince1970: 1_800_010_000)
        )
        try liveDatabase.pool.close()

        let blobData = Data("peer recovery blob".utf8)
        let sha = HMACAuth.sha256Hex(blobData)
        let ownNew = drItem(
            id: "own-new", origin: "self-a", captured: 200, ingested: 200,
            kind: .image, sha: sha
        )
        let peerTombstone = drItem(
            id: "peer-dead", origin: "peer-b", captured: 150, ingested: 300,
            deleted: 300
        )
        let fixture = try TestSyncServerFixture(
            prefix: "duo-dr-peer",
            items: [ownOld, ownNew, peerTombstone],
            secretByte: 0xD3
        )
        _ = try fixture.blobs.putVerified(blobData, expectedSha256: sha, ext: "png")
        let server = SyncServer(
            deviceID: "peer-b",
            database: fixture.database,
            blobs: fixture.blobs,
            host: "127.0.0.1",
            port: 0,
            auth: fixture.auth
        )

        let corruptBytes = Data("corrupt live sqlite".utf8)
        try corruptBytes.write(to: livePaths.mainDB)

        try await fixture.withServer(server) { baseURL in
            let client = HTTPPeerClient(baseURL: baseURL, auth: fixture.auth)

            func restoreCycle(expectCorruptLive: Bool) async throws -> Snapshot.CommitReport {
                let prepared = try Snapshot.prepareRecovery(
                    from: snapshot,
                    livePaths: livePaths
                )
                let liveBlobs = BlobStore(root: livePaths.blobsDir)
                let stagedBlobs = BlobStore(root: prepared.stagingPaths.blobsDir)
                let first = try await DisasterRecovery.refill(
                    databasePath: prepared.stagingPaths.mainDB,
                    selfDeviceID: "self-a",
                    expectedPeerDeviceID: "peer-b",
                    existingBlobs: liveBlobs,
                    stagingBlobs: stagedBlobs,
                    transport: client,
                    batchLimit: 2
                )
                #expect(first.pages == 2)
                #expect(first.rowsSeen == 3)
                #expect(first.inserted == 1)
                #expect(first.updated == 1)
                #expect(first.skippedOlderOrEqual == 1)
                #expect(first.ownOriginRecovered == 1)
                #expect(first.final.itemCount == 3)
                #expect(first.final.tombstoneCount == 1)
                #expect(first.final.missingBlobCount == 0)
                if expectCorruptLive {
                    #expect(try Data(contentsOf: livePaths.mainDB) == corruptBytes)
                    #expect(first.fetchedBlobs == 1)
                }

                // 同一 candidate 从 zero 再扫一次：所有 canonical cursor 相同，不能重复写。
                let second = try await DisasterRecovery.refill(
                    databasePath: prepared.stagingPaths.mainDB,
                    selfDeviceID: "self-a",
                    expectedPeerDeviceID: "peer-b",
                    existingBlobs: liveBlobs,
                    stagingBlobs: stagedBlobs,
                    transport: client,
                    batchLimit: 2
                )
                #expect(second.inserted == 0)
                #expect(second.updated == 0)
                #expect(second.skippedOlderOrEqual == 3)
                #expect(second.fetchedBlobs == 0)

                return try Snapshot.commitRecovery(
                    prepared,
                    daemonRunning: false,
                    daemonLabel: "io.duopaste.agent"
                )
            }

            let firstCommit = try await restoreCycle(expectCorruptLive: true)
            #expect(firstCommit.restored.itemCount == 3)
            #expect(firstCommit.restored.tombstoneCount == 1)
            #expect(firstCommit.restored.activeBlobCount == 1)
            #expect(firstCommit.restored.missingBlobCount == 0)
            #expect(firstCommit.mergedBlobCount == 1)
            #expect(FileManager.default.fileExists(atPath: firstCommit.safetyBackup.path))

            // 模拟 daemon restart：新 Database 实例会再跑 migration，恢复库必须可直接打开。
            let restarted = try RecoveryDB(path: livePaths.mainDB)
            let firstIDs = try await restarted.pool.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM item ORDER BY id")
            }
            #expect(firstIDs == ["own-new", "own-old", "peer-dead"])
            try restarted.pool.close()
            #expect(BlobStore(root: livePaths.blobsDir).exists(sha256: sha))

            // 双 Mac 运维重复执行完整 restore，最终统计和唯一 ID 仍完全一致。
            let secondCommit = try await restoreCycle(expectCorruptLive: false)
            #expect(secondCommit.restored.itemCount == firstCommit.restored.itemCount)
            #expect(secondCommit.restored.tombstoneCount == firstCommit.restored.tombstoneCount)
            #expect(secondCommit.restored.activeBlobCount == firstCommit.restored.activeBlobCount)
            #expect(secondCommit.mergedBlobCount == 0)
            let reopenedAgain = try RecoveryDB(path: livePaths.mainDB)
            let uniqueCounts = try await reopenedAgain.pool.read { db -> (Int, Int) in
                let row = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS total, COUNT(DISTINCT id) AS unique_ids FROM item
                """)!
                return (row["total"], row["unique_ids"])
            }
            #expect(uniqueCounts.0 == 3)
            #expect(uniqueCounts.1 == 3)
        }
    }

    @Test func peerFailureLeavesLiveDatabaseByteForByteUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duo-dr-failure-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(root: root)
        paths.ensureExists()
        let database = try RecoveryDB(path: paths.mainDB)
        try await database.pool.write { db in
            try drItem(id: "keep-live", origin: "self-a", captured: 100, ingested: 100).insert(db)
        }
        let snapshot = try Snapshot.takeSnapshot(database: database, paths: paths)
        try database.checkpoint()
        try database.pool.close()
        let before = try Data(contentsOf: paths.mainDB)
        let prepared = try Snapshot.prepareRecovery(from: snapshot, livePaths: paths)
        defer { Snapshot.discardRecovery(prepared) }

        await #expect(throws: DisasterRecovery.RecoveryError.self) {
            _ = try await DisasterRecovery.refill(
                databasePath: prepared.stagingPaths.mainDB,
                selfDeviceID: "self-a",
                existingBlobs: BlobStore(root: paths.blobsDir),
                stagingBlobs: BlobStore(root: prepared.stagingPaths.blobsDir),
                transport: FailingDRTransport()
            )
        }
        #expect(try Data(contentsOf: paths.mainDB) == before)
        let reopened = try RecoveryDB(path: paths.mainDB)
        #expect(try await reopened.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") } == 1)
    }
}

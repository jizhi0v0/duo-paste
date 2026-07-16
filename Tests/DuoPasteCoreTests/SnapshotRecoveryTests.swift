import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

private func makeSnapshotRecoveryPaths(_ prefix: String = "duo-snapshot-recovery") -> Paths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return paths
}

private func recoveryItem(
    id: String,
    origin: String = "self",
    ingested: Int64,
    kind: ItemKind = .text,
    sha: String? = nil,
    deleted: Int64? = nil
) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: ingested,
        ingestedAtNs: ingested,
        kind: kind,
        preview: id,
        textFull: kind == .text ? id : nil,
        blobSha256: sha,
        blobSize: sha == nil ? nil : 10,
        blobMime: sha == nil ? nil : "image/png",
        deletedAtNs: deleted
    )
}

@Suite(.serialized)
struct SnapshotRecoveryTests {
    @Test func listAndVerifyReportIntegrityCountsAndMissingBlobs() async throws {
        let paths = makeSnapshotRecoveryPaths()
        let database = try Database(path: paths.mainDB)
        let missingSHA = String(repeating: "a", count: 64)
        try await database.pool.write { db in
            try recoveryItem(id: "active", ingested: 100).insert(db)
            try recoveryItem(
                id: "image", ingested: 200, kind: .image, sha: missingSHA
            ).insert(db)
            try recoveryItem(id: "dead", ingested: 300, deleted: 301).insert(db)
        }
        let snapshot = try Snapshot.takeSnapshot(
            database: database,
            paths: paths,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let report = try Snapshot.verify(
            at: snapshot,
            blobStores: [BlobStore(root: paths.blobsDir)]
        )
        #expect(report.integrityResult == "ok")
        #expect(report.itemCount == 3)
        #expect(report.activeItemCount == 2)
        #expect(report.tombstoneCount == 1)
        #expect(report.activeBlobCount == 1)
        #expect(report.missingBlobCount == 1)
        #expect(report.missingBlobSamples == [missingSHA])

        let entries = try Snapshot.list(snapshotsDir: paths.snapshotsDir)
        #expect(entries.map(\.url.lastPathComponent) == [snapshot.lastPathComponent])
        #expect(
            try Snapshot.resolve(nil, snapshotsDir: paths.snapshotsDir).lastPathComponent
                == snapshot.lastPathComponent
        )
        #expect(
            try Snapshot.resolve("latest", snapshotsDir: paths.snapshotsDir).lastPathComponent
                == snapshot.lastPathComponent
        )

        let corrupt = paths.snapshotsDir.appendingPathComponent(
            Snapshot.filename(for: Date(timeIntervalSince1970: 1_800_000_100))
        )
        try Data("not sqlite".utf8).write(to: corrupt)
        #expect(throws: (any Error).self) {
            _ = try Snapshot.verify(at: corrupt)
        }
        #expect(throws: (any Error).self) {
            _ = try Snapshot.prepareRecovery(from: corrupt, livePaths: paths)
        }
        #expect(try await database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item")
        } == 3)
    }

    @Test func prepareIsDryRunSafeAndDaemonGuardPreservesLiveDatabase() async throws {
        let paths = makeSnapshotRecoveryPaths()
        let database = try Database(path: paths.mainDB)
        try await database.pool.write { db in
            try recoveryItem(id: "snapshot-row", ingested: 100).insert(db)
        }
        let snapshot = try Snapshot.takeSnapshot(
            database: database,
            paths: paths,
            now: Date(timeIntervalSince1970: 1_800_001_000)
        )
        try await database.pool.write { db in
            try recoveryItem(id: "live-only", ingested: 200).insert(db)
        }
        try database.checkpoint()
        try database.pool.close()
        let liveBefore = try Data(contentsOf: paths.mainDB)

        let prepared = try Snapshot.prepareRecovery(from: snapshot, livePaths: paths)
        defer { Snapshot.discardRecovery(prepared) }
        let candidate = try Snapshot.verify(at: prepared.stagingPaths.mainDB)
        #expect(candidate.itemCount == 1)
        #expect(try Data(contentsOf: paths.mainDB) == liveBefore)

        #expect(throws: Snapshot.RecoveryError.self) {
            _ = try Snapshot.commitRecovery(
                prepared,
                daemonRunning: true,
                daemonLabel: "io.duopaste.agent"
            )
        }
        #expect(try Data(contentsOf: paths.mainDB) == liveBefore)
        let reopened = try Database(path: paths.mainDB)
        #expect(try await reopened.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item") } == 2)
    }

    @Test func atomicCommitRestoresCorruptLiveDatabaseAndKeepsSafetyCopy() async throws {
        let paths = makeSnapshotRecoveryPaths()
        let database = try Database(path: paths.mainDB)
        try await database.pool.write { db in
            try recoveryItem(id: "survivor", ingested: 100).insert(db)
        }
        let snapshot = try Snapshot.takeSnapshot(
            database: database,
            paths: paths,
            now: Date(timeIntervalSince1970: 1_800_002_000)
        )
        try database.pool.close()

        let corruptBytes = Data("damaged live database".utf8)
        try corruptBytes.write(to: paths.mainDB)
        let prepared = try Snapshot.prepareRecovery(from: snapshot, livePaths: paths)
        let commit = try Snapshot.commitRecovery(
            prepared,
            daemonRunning: false,
            daemonLabel: "io.duopaste.agent",
            now: Date(timeIntervalSince1970: 1_800_003_000)
        )

        #expect(commit.restored.integrityResult == "ok")
        #expect(commit.restored.itemCount == 1)
        let safetyDB = commit.safetyBackup.appendingPathComponent("db/main.sqlite")
        #expect(try Data(contentsOf: safetyDB) == corruptBytes)
        let restarted = try Database(path: paths.mainDB)
        let ids = try await restarted.pool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM item ORDER BY id")
        }
        #expect(ids == ["survivor"])
    }
}

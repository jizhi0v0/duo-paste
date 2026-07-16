import Foundation
import GRDB
import DuoPasteCore

/// 一次性、显式启用的 mesh 灾后回填器。
///
/// 与普通 PullWorker 的边界：这里从 cursor zero 扫健康 peer，并允许恢复
/// `origin_device == selfDeviceID` 的 active row；不写 `pull_cursor`，也不会被 daemon
/// 自动启动。调用者必须把 `databasePath` 指向 snapshot staging candidate，而不是 live DB。
public enum DisasterRecovery {
    public struct Report: Sendable, Equatable {
        public let peerDeviceID: String
        public let pages: Int
        public let rowsSeen: Int
        public let inserted: Int
        public let updated: Int
        public let skippedOlderOrEqual: Int
        public let ownOriginRecovered: Int
        public let fetchedBlobs: Int
        public let peerMissingBlobs: Int
        public let final: Snapshot.VerificationReport
    }

    public enum RecoveryError: Error, CustomStringConvertible, Sendable {
        case healthUnreachable(String)
        case healthRejected(String)
        case emptyPeerDeviceID
        case unexpectedPeerDeviceID(expected: String, actual: String)
        case sinceUnreachable(String)
        case sinceRejected(String)
        case cursorDidNotAdvance(SinceCursor)

        public var description: String {
            switch self {
            case .healthUnreachable(let reason): return "DR peer /health unreachable：\(reason)"
            case .healthRejected(let reason): return "DR peer /health rejected：\(reason)"
            case .emptyPeerDeviceID: return "DR peer /health 返回空 device_id"
            case .unexpectedPeerDeviceID(let expected, let actual):
                return "DR peer device_id 不匹配：expected=\(expected) actual=\(actual)"
            case .sinceUnreachable(let reason): return "DR peer /since unreachable：\(reason)"
            case .sinceRejected(let reason): return "DR peer /since rejected：\(reason)"
            case .cursorDidNotAdvance(let cursor):
                return "DR peer has_more=true 但 cursor 未推进：ns=\(cursor.ingestedAtNs) id=\(cursor.id)"
            }
        }
    }

    public static func refill(
        databasePath: URL,
        selfDeviceID: String,
        expectedPeerDeviceID: String? = nil,
        existingBlobs: BlobStore,
        stagingBlobs: BlobStore,
        transport: any SinceTransport & BlobFetcher,
        batchLimit: Int = SinceAPI.defaultLimit
    ) async throws -> Report {
        let health = try await transport.fetchPrimaryHealth()
        let peerDeviceID: String
        switch health.outcome {
        case .ok(let deviceID, _, _):
            guard !deviceID.isEmpty else { throw RecoveryError.emptyPeerDeviceID }
            if let expectedPeerDeviceID, expectedPeerDeviceID != deviceID {
                throw RecoveryError.unexpectedPeerDeviceID(
                    expected: expectedPeerDeviceID,
                    actual: deviceID
                )
            }
            peerDeviceID = deviceID
        case .unreachable(let reason):
            throw RecoveryError.healthUnreachable(reason)
        case .rejected(let reason):
            throw RecoveryError.healthRejected(reason)
        }

        let database = try DuoPasteCore.Database(path: databasePath)
        defer { try? database.pool.close() }
        var cursor = SinceCursor.zero
        var pages = 0
        var rowsSeen = 0
        var inserted = 0
        var updated = 0
        var skipped = 0
        var ownOriginRecovered = 0

        while true {
            let response = try await transport.fetchSince(
                cursor: cursor,
                limit: max(1, min(batchLimit, SinceAPI.maxLimit))
            )
            let page: SincePageWire
            switch response.outcome {
            case .ok(let value): page = value
            case .unreachable(let reason): throw RecoveryError.sinceUnreachable(reason)
            case .rejected(let reason): throw RecoveryError.sinceRejected(reason)
            }
            pages += 1
            rowsSeen += page.items.count

            let pageCounts = try await database.pool.write { db -> (Int, Int, Int, Int) in
                var pageInserted = 0
                var pageUpdated = 0
                var pageSkipped = 0
                var pageOwn = 0
                for item in page.items {
                    let existing = try Item.filter(Column("id") == item.id).fetchOne(db)
                    if let existing {
                        let incomingNs = item.ingestedAtNs ?? 0
                        let existingNs = existing.ingestedAtNs ?? 0
                        guard incomingNs > existingNs else {
                            pageSkipped += 1
                            continue
                        }
                        try item.update(db)
                        pageUpdated += 1
                        if item.originDevice == selfDeviceID { pageOwn += 1 }
                    } else {
                        try item.insert(db)
                        pageInserted += 1
                        if item.originDevice == selfDeviceID { pageOwn += 1 }
                    }
                }
                return (pageInserted, pageUpdated, pageSkipped, pageOwn)
            }
            inserted += pageCounts.0
            updated += pageCounts.1
            skipped += pageCounts.2
            ownOriginRecovered += pageCounts.3

            if !page.hasMore {
                cursor = page.nextCursor
                break
            }
            guard page.nextCursor != cursor else {
                throw RecoveryError.cursorDidNotAdvance(cursor)
            }
            cursor = page.nextCursor
        }

        let activeShas = try await database.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT blob_sha256 FROM item
                WHERE blob_sha256 IS NOT NULL
                  AND deleted_at_ns IS NULL
                  AND kind IN ('image', 'file')
                ORDER BY blob_sha256
            """)
        }
        var fetchedBlobs = 0
        var peerMissingBlobs = 0
        for sha in activeShas {
            if existingBlobs.exists(sha256: sha) || stagingBlobs.exists(sha256: sha) {
                continue
            }
            switch try await transport.getBlob(sha256: sha) {
            case .found(let data):
                _ = try stagingBlobs.putVerified(data, expectedSha256: sha)
                fetchedBlobs += 1
            case .notFound:
                peerMissingBlobs += 1
            }
        }

        try database.checkpoint()
        try database.pool.close()
        let final = try Snapshot.verify(
            at: databasePath,
            blobStores: [existingBlobs, stagingBlobs]
        )
        return Report(
            peerDeviceID: peerDeviceID,
            pages: pages,
            rowsSeen: rowsSeen,
            inserted: inserted,
            updated: updated,
            skippedOlderOrEqual: skipped,
            ownOriginRecovered: ownOriginRecovered,
            fetchedBlobs: fetchedBlobs,
            peerMissingBlobs: peerMissingBlobs,
            final: final
        )
    }
}

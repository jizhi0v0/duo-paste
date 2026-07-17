import Foundation

/// Durable proof that one iOS metadata pull reached `has_more=false` and completed the source-count
/// audit. It intentionally lives outside the evictable SQLite cache so a system cache purge can be
/// distinguished from a first install instead of presenting a partial refill as a complete archive.
public struct MetadataMirrorSyncCheckpoint: Codable, Sendable, Equatable {
    public let lastSuccessAt: Date
    public let lastPeerDeviceID: String?
    public let lastLocalItemCount: Int
    public let lastSourceTrackedItemCount: Int?
    public let lastServerTotalCount: Int?
    public let finalCursor: SinceCursor

    public init(
        lastSuccessAt: Date,
        lastPeerDeviceID: String?,
        lastLocalItemCount: Int,
        lastSourceTrackedItemCount: Int?,
        lastServerTotalCount: Int?,
        finalCursor: SinceCursor
    ) {
        self.lastSuccessAt = lastSuccessAt
        self.lastPeerDeviceID = lastPeerDeviceID
        self.lastLocalItemCount = max(0, lastLocalItemCount)
        self.lastSourceTrackedItemCount = lastSourceTrackedItemCount
        self.lastServerTotalCount = lastServerTotalCount
        self.finalCursor = finalCursor
    }
}

/// Atomic JSON persistence for `MetadataMirrorSyncCheckpoint`.
///
/// The caller chooses the location. iOS uses Application Support, not Caches; Core keeps the type
/// platform-neutral and directly testable.
public struct MetadataMirrorSyncCheckpointStore: Sendable {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public func load() throws -> MetadataMirrorSyncCheckpoint? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(MetadataMirrorSyncCheckpoint.self, from: data)
    }

    public func save(_ checkpoint: MetadataMirrorSyncCheckpoint) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(checkpoint).write(to: path, options: .atomic)
    }
}

/// Launch-time interpretation of the evictable mirror plus its durable completion proof.
public enum MetadataMirrorBootstrapDisposition: Sendable, Equatable {
    /// No previous strict completion proof and no usable local archive.
    case initialSync
    /// R2.1-era mirror exists but predates the durable R2.2 proof; verify it once against a peer.
    case verifyingExistingCache
    /// A previous complete archive was evicted or rolled back and is now only partially present.
    case rebuilding
    /// Local mirror contains at least the rows and cursor covered by the durable proof.
    case ready(MetadataMirrorSyncCheckpoint)

    public static func classify(
        mirrorFileExisted: Bool,
        localItemCount: Int,
        cursor: SinceCursor,
        checkpoint: MetadataMirrorSyncCheckpoint?
    ) -> Self {
        guard let checkpoint else {
            if mirrorFileExisted, localItemCount > 0 || cursor != .zero {
                return .verifyingExistingCache
            }
            return .initialSync
        }
        guard mirrorFileExisted,
              localItemCount >= checkpoint.lastLocalItemCount,
              !cursorIsBefore(cursor, checkpoint.finalCursor) else {
            return .rebuilding
        }
        return .ready(checkpoint)
    }

    private static func cursorIsBefore(_ lhs: SinceCursor, _ rhs: SinceCursor) -> Bool {
        lhs.ingestedAtNs < rhs.ingestedAtNs
            || (lhs.ingestedAtNs == rhs.ingestedAtNs && lhs.id < rhs.id)
    }
}

/// Which pass emitted a progress update. A backfill is non-destructive and does not regress the
/// persisted cursor, but it must still be surfaced because it is rebuilding missing old rows.
public enum MetadataMirrorSyncPass: String, Codable, Sendable, Equatable {
    case incremental
    case backfill
}

/// Exact, post-commit progress for one `/since` page.
public struct MetadataMirrorSyncProgress: Sendable, Equatable {
    public let pass: MetadataMirrorSyncPass
    public let pageNumber: Int
    public let localItemCount: Int
    public let sourceTrackedItemCount: Int?
    public let serverTotalCount: Int?
    public let sourceDeviceID: String?
    public let cursor: SinceCursor
    public let hasMore: Bool

    public init(
        pass: MetadataMirrorSyncPass,
        pageNumber: Int,
        localItemCount: Int,
        sourceTrackedItemCount: Int?,
        serverTotalCount: Int?,
        sourceDeviceID: String?,
        cursor: SinceCursor,
        hasMore: Bool
    ) {
        self.pass = pass
        self.pageNumber = pageNumber
        self.localItemCount = max(0, localItemCount)
        self.sourceTrackedItemCount = sourceTrackedItemCount
        self.serverTotalCount = serverTotalCount
        self.sourceDeviceID = sourceDeviceID
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

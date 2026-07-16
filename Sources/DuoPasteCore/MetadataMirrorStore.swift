import Foundation
import GRDB

/// Client-side full-history metadata mirror.
///
/// iOS uses this instead of the old bounded `items.json` cache. The store deliberately reuses the
/// production `Database` schema and `SearchAPI`: there is one FTS/fold/qualifier implementation for
/// Mac and iOS, while blob bytes remain in the independent client LRU cache.
public struct MetadataMirrorStore: Sendable {
    /// One logical aggregate history stream. Mesh peers expose the same canonical item set, so route
    /// failover must not create parallel cursors and duplicate a full pull.
    public static let defaultStreamID = "ios-metadata-mirror"

    let database: Database

    public init(path: URL) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        database = try Database(path: path)
    }

    /// Applies one `/since` page and advances its cursor in the same SQLite writer transaction.
    ///
    /// Cursor updates are lexicographic and monotonic. A foreground pull and BGAppRefreshTask may
    /// race with the same page; both item writes and cursor advancement remain idempotent, and a late
    /// older response can neither overwrite a newer item revision nor move the watermark backwards.
    @discardableResult
    public func applyPage(
        items: [Item],
        nextCursor: SinceCursor,
        streamID: String = Self.defaultStreamID,
        sourceDeviceID: String? = nil
    ) throws -> SinceCursor {
        try database.pool.write { db in
            for item in items {
                try Self.upsertCanonical(item, in: db)
                if let sourceDeviceID = Self.normalizedSourceDeviceID(sourceDeviceID) {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO mirror_source_item (source_device_id, item_id)
                        VALUES (?, ?)
                        """, arguments: [sourceDeviceID, item.id])
                }
            }

            let existing = try Self.cursor(in: db, streamID: streamID)
            let persisted = Self.isAfter(nextCursor, existing) ? nextCursor : existing
            if persisted != existing || existing == .zero {
                let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
                try db.execute(sql: """
                    INSERT INTO pull_cursor (peer_device_id, cursor_ns, cursor_id, updated_at_ns)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(peer_device_id) DO UPDATE SET
                        cursor_ns = excluded.cursor_ns,
                        cursor_id = excluded.cursor_id,
                        updated_at_ns = excluded.updated_at_ns
                    """, arguments: [streamID, persisted.ingestedAtNs, persisted.id, nowNs])
            }
            return persisted
        }
    }

    public func cursor(streamID: String = Self.defaultStreamID) throws -> SinceCursor {
        try database.pool.read { db in
            try Self.cursor(in: db, streamID: streamID)
        }
    }

    /// Imports the bounded pre-R2.1 JSON cache for instant upgrade UI.
    ///
    /// This is intentionally `INSERT OR IGNORE`: a retry after a crash between SQLite commit and JSON
    /// deletion cannot overwrite newer canonical pages. It also intentionally does not accept or
    /// advance a cursor—the legacy cursor may describe history that the 1000-row JSON cap discarded,
    /// so the first SQLite sync must start from zero and refill the complete archive.
    @discardableResult
    public func importLegacyItems(_ items: [Item]) throws -> Int {
        try database.pool.write { db in
            var inserted = 0
            for item in items {
                try Self.insertLegacyIfMissing(item, in: db)
                inserted += db.changesCount
            }
            return inserted
        }
    }

    /// A bounded recent display page. The full archive remains in SQLite and is searchable; loading
    /// 100k Swift models on every cold start would defeat the purpose of the mirror.
    public func recentItems(limit: Int = 1_000) throws -> [Item] {
        let hits = try SearchAPI(database: database).searchHits(
            SearchQuery(limit: max(0, limit), offset: 0)
        )
        return hits.map(\.0)
    }

    public func activeItemCount() throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE deleted_at_ns IS NULL") ?? 0
        }
    }

    public func totalItemCount() throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0
        }
    }

    public func trackedItemCount(sourceDeviceID: String) throws -> Int {
        guard let sourceDeviceID = Self.normalizedSourceDeviceID(sourceDeviceID) else { return 0 }
        return try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM mirror_source_item WHERE source_device_id = ?",
                arguments: [sourceDeviceID]
            ) ?? 0
        }
    }

    /// 增量追平后若 server raw row count 大于本地，说明 source 曾在 client cursor 之后
    /// 补进更老的行。普通 `(ingested_at_ns,id) > cursor` 永远看不到它们；从 zero 做一次
    /// **非破坏性 backfill**，upsert 缺行且保持已持久化 cursor 单调不回退。
    public func synchronize(
        pageLimit: Int = 500,
        maxPages: Int = 200,
        fetchPage: @escaping @Sendable (SinceCursor, Int) async throws -> SincePageWire
    ) async throws -> MetadataMirrorSyncReport {
        let startCursor = try cursor()
        let incremental = try await pullPass(
            from: startCursor,
            pageLimit: pageLimit,
            maxPages: maxPages,
            fetchPage: fetchPage
        )

        var serverTotalCount = incremental.serverTotalCount
        var sourceDeviceID = incremental.sourceDeviceID
        let beforeRepair = try totalItemCount()
        var backfillPages = 0
        let needsBackfill: Bool
        if let sourceDeviceID, let expected = serverTotalCount {
            needsBackfill = try trackedItemCount(sourceDeviceID: sourceDeviceID) != expected
        } else if let expected = serverTotalCount {
            // Rolling upgrade fallback for an old server without source_device_id. This cannot
            // distinguish a single source from a multi-peer union, but preserves old wire support.
            needsBackfill = beforeRepair < expected
        } else {
            needsBackfill = false
        }

        if needsBackfill {
            if let sourceDeviceID {
                try resetTrackedItems(sourceDeviceID: sourceDeviceID)
            }
            let backfill = try await pullPass(
                from: .zero,
                pageLimit: pageLimit,
                maxPages: maxPages,
                expectedSourceDeviceID: sourceDeviceID,
                fetchPage: fetchPage
            )
            backfillPages = backfill.pages
            if let refreshedTotal = backfill.serverTotalCount {
                serverTotalCount = refreshedTotal
            }
            if let refreshedSource = backfill.sourceDeviceID {
                sourceDeviceID = refreshedSource
            }
        }

        let localTotalCount = try totalItemCount()
        var sourceTrackedItemCount: Int?
        if let sourceDeviceID, let expected = serverTotalCount {
            let actual = try trackedItemCount(sourceDeviceID: sourceDeviceID)
            sourceTrackedItemCount = actual
            if backfillPages > 0, actual != expected {
                throw MetadataMirrorSyncError.countMismatch(expected: expected, actual: actual)
            }
        } else if backfillPages > 0,
                  let expected = serverTotalCount,
                  localTotalCount < expected {
            throw MetadataMirrorSyncError.countMismatch(expected: expected, actual: localTotalCount)
        }
        return MetadataMirrorSyncReport(
            startedAt: startCursor,
            finalCursor: try cursor(),
            incrementalPages: incremental.pages,
            backfillPages: backfillPages,
            serverTotalCount: serverTotalCount,
            localTotalCount: localTotalCount,
            sourceDeviceID: sourceDeviceID,
            sourceTrackedItemCount: sourceTrackedItemCount
        )
    }

    private struct PullPassResult {
        let pages: Int
        let serverTotalCount: Int?
        let sourceDeviceID: String?
    }

    private func pullPass(
        from startCursor: SinceCursor,
        pageLimit: Int,
        maxPages: Int,
        expectedSourceDeviceID: String? = nil,
        fetchPage: @escaping @Sendable (SinceCursor, Int) async throws -> SincePageWire
    ) async throws -> PullPassResult {
        var requestCursor = startCursor
        var observedSourceDeviceID = Self.normalizedSourceDeviceID(expectedSourceDeviceID)
        for pageNumber in 1...max(1, maxPages) {
            try Task.checkCancellation()
            let page = try await fetchPage(requestCursor, max(1, pageLimit))
            let pageSourceDeviceID = Self.normalizedSourceDeviceID(page.sourceDeviceID)
            if let observedSourceDeviceID {
                guard pageSourceDeviceID == observedSourceDeviceID else {
                    throw MetadataMirrorSyncError.sourceChanged(
                        expected: observedSourceDeviceID,
                        actual: pageSourceDeviceID
                    )
                }
            } else {
                observedSourceDeviceID = pageSourceDeviceID
            }
            _ = try applyPage(
                items: page.items,
                nextCursor: page.nextCursor,
                sourceDeviceID: pageSourceDeviceID
            )
            if !page.hasMore {
                return PullPassResult(
                    pages: pageNumber,
                    serverTotalCount: page.totalCount,
                    sourceDeviceID: observedSourceDeviceID
                )
            }
            guard Self.isAfter(page.nextCursor, requestCursor) else {
                throw MetadataMirrorSyncError.cursorDidNotAdvance(requestCursor)
            }
            // backfill 时 persisted cursor 可能比本页更靠后，下一次请求必须跟 page cursor，
            // 不能跟 applyPage 返回的单调持久化 cursor，否则会重新跳过缺口。
            requestCursor = page.nextCursor
        }
        throw MetadataMirrorSyncError.pageLimitExceeded(maxPages: max(1, maxPages))
    }

    private func resetTrackedItems(sourceDeviceID: String) throws {
        guard let sourceDeviceID = Self.normalizedSourceDeviceID(sourceDeviceID) else { return }
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM mirror_source_item WHERE source_device_id = ?",
                arguments: [sourceDeviceID]
            )
        }
    }

    /// Upgrade verification used before deleting the legacy JSON file. Chunking keeps the query
    /// below conservative SQLite bind-parameter limits on older iOS releases.
    public func containsItemIDs(_ ids: Set<String>) throws -> Bool {
        guard !ids.isEmpty else { return true }
        return try database.pool.read { db in
            let ordered = Array(ids)
            var found = 0
            for start in stride(from: 0, to: ordered.count, by: 400) {
                let chunk = Array(ordered[start..<min(start + 400, ordered.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                found += try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM item WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                ) ?? 0
            }
            return found == ids.count
        }
    }

    /// Executes the exact Mac `SearchAPI` path locally, including FTS snippets, cross-origin folding,
    /// pin aggregation, qualifier OR semantics, and ordering.
    public func search(
        text: String?,
        qualifiers: [QueryQualifier] = [],
        limit: Int = 200,
        offset: Int = 0
    ) throws -> MetadataMirrorSearchResult {
        let fields = Self.searchFields(for: qualifiers)
        let query = SearchQuery(
            text: text,
            kinds: fields.kinds,
            fileSubKinds: fields.fileSubKinds,
            textFullSuffixes: fields.textSuffixes,
            limit: max(0, limit),
            offset: max(0, offset)
        )
        // The iOS result grid does not display an exact global count. Use the bounded SearchAPI hit
        // path so broad FTS queries do not materialize every match merely to compute a hidden count.
        // Qualifier/fold semantics remain the same; `totalCount` is the locally loaded result count.
        let hits = try SearchAPI(database: database).searchHits(query)
        var snippets: [String: String] = [:]
        for (item, snippet) in hits {
            if let snippet { snippets[item.id] = snippet }
        }
        return MetadataMirrorSearchResult(
            items: hits.map(\.0),
            snippets: snippets,
            totalCount: hits.count
        )
    }

    private static func cursor(in db: GRDB.Database, streamID: String) throws -> SinceCursor {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT cursor_ns, cursor_id FROM pull_cursor WHERE peer_device_id = ?",
            arguments: [streamID]
        ) else {
            return .zero
        }
        return SinceCursor(
            ingestedAtNs: row["cursor_ns"],
            id: row["cursor_id"]
        )
    }

    private static func isAfter(_ lhs: SinceCursor, _ rhs: SinceCursor) -> Bool {
        lhs.ingestedAtNs > rhs.ingestedAtNs
            || (lhs.ingestedAtNs == rhs.ingestedAtNs && lhs.id > rhs.id)
    }

    private static func normalizedSourceDeviceID(_ sourceDeviceID: String?) -> String? {
        guard let sourceDeviceID else { return nil }
        let normalized = sourceDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func upsertCanonical(_ item: Item, in db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT INTO item (
                id, origin_device, captured_at_ns, ingested_at_ns, kind,
                source_app, source_app_name, preview, text_full,
                blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
                ocr_state, extracted_text, extracted_text_source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                origin_device = excluded.origin_device,
                captured_at_ns = excluded.captured_at_ns,
                ingested_at_ns = excluded.ingested_at_ns,
                kind = excluded.kind,
                source_app = excluded.source_app,
                source_app_name = excluded.source_app_name,
                preview = excluded.preview,
                text_full = excluded.text_full,
                blob_sha256 = excluded.blob_sha256,
                blob_size = excluded.blob_size,
                blob_mime = excluded.blob_mime,
                pinned = excluded.pinned,
                deleted_at_ns = excluded.deleted_at_ns,
                ocr_state = excluded.ocr_state,
                extracted_text = excluded.extracted_text,
                extracted_text_source = excluded.extracted_text_source
            WHERE item.ingested_at_ns IS NULL
               OR excluded.ingested_at_ns >= item.ingested_at_ns
            """, arguments: Self.arguments(for: item))
    }

    private static func insertLegacyIfMissing(_ item: Item, in db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO item (
                id, origin_device, captured_at_ns, ingested_at_ns, kind,
                source_app, source_app_name, preview, text_full,
                blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
                ocr_state, extracted_text, extracted_text_source
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: Self.arguments(for: item))
    }

    private static func arguments(for item: Item) -> StatementArguments {
        StatementArguments([
            item.id,
            item.originDevice,
            item.capturedAtNs,
            item.ingestedAtNs,
            item.kind.rawValue,
            item.sourceApp,
            item.sourceAppName,
            item.preview,
            item.textFull,
            item.blobSha256,
            item.blobSize,
            item.blobMime,
            item.pinned ? 1 : 0,
            item.deletedAtNs,
            item.ocrState?.rawValue,
            item.extractedText,
            item.extractedTextSource?.rawValue,
        ])
    }

    private static func searchFields(
        for qualifiers: [QueryQualifier]
    ) -> (kinds: [ItemKind], fileSubKinds: [FileSubKind], textSuffixes: [String]) {
        var kinds: [ItemKind] = []
        var subKinds: [FileSubKind] = []
        var suffixes: [String] = []
        for qualifier in qualifiers {
            switch qualifier {
            case .kind(let kind):
                if !kinds.contains(kind) { kinds.append(kind) }
            case .fileSubKind(let subKind):
                if !subKinds.contains(subKind) { subKinds.append(subKind) }
            case .textSuffix(let suffix):
                let normalized = suffix.lowercased()
                if !normalized.isEmpty, !suffixes.contains(normalized) { suffixes.append(normalized) }
            case .imageMerged:
                if !kinds.contains(.image) { kinds.append(.image) }
                if !subKinds.contains(.imageFile) { subKinds.append(.imageFile) }
            }
        }
        return (kinds, subKinds, suffixes)
    }
}

public struct MetadataMirrorSyncReport: Sendable, Equatable {
    public let startedAt: SinceCursor
    public let finalCursor: SinceCursor
    public let incrementalPages: Int
    public let backfillPages: Int
    public let serverTotalCount: Int?
    public let localTotalCount: Int
    public let sourceDeviceID: String?
    public let sourceTrackedItemCount: Int?
}

public enum MetadataMirrorSyncError: LocalizedError, Sendable, Equatable {
    case cursorDidNotAdvance(SinceCursor)
    case pageLimitExceeded(maxPages: Int)
    case countMismatch(expected: Int, actual: Int)
    case sourceChanged(expected: String, actual: String?)

    public var errorDescription: String? {
        switch self {
        case .cursorDidNotAdvance(let cursor):
            return "server has_more=true 但 cursor 未推进：\(cursor.ingestedAtNs)/\(cursor.id)"
        case .pageLimitExceeded(let maxPages):
            return "metadata sync 超过页数上限 \(maxPages)"
        case .countMismatch(let expected, let actual):
            return "metadata backfill 后仍缺行：server=\(expected) local=\(actual)"
        case .sourceChanged(let expected, let actual):
            let actualLabel = actual ?? "missing"
            return "metadata 分页期间 source 改变：expected=\(expected) actual=\(actualLabel)"
        }
    }
}

public struct MetadataMirrorSearchResult: Sendable, Equatable {
    public let items: [Item]
    public let snippets: [String: String]
    public let totalCount: Int

    public init(items: [Item], snippets: [String: String], totalCount: Int) {
        self.items = items
        self.snippets = snippets
        self.totalCount = totalCount
    }
}

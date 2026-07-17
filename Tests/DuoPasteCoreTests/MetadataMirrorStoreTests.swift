import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

private func makeMetadataMirror() throws -> (MetadataMirrorStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-ios-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.appendingPathComponent("mirror.sqlite")
    return (try MetadataMirrorStore(path: path), path)
}

private func mirrorItem(
    id: String,
    origin: String = "mac-a",
    capturedAtNs: Int64,
    ingestedAtNs: Int64? = nil,
    kind: ItemKind = .text,
    text: String? = nil,
    pinned: Bool = false,
    deletedAtNs: Int64? = nil
) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedAtNs,
        ingestedAtNs: ingestedAtNs ?? capturedAtNs,
        kind: kind,
        preview: text,
        textFull: text,
        pinned: pinned,
        deletedAtNs: deletedAtNs
    )
}

private actor LateOlderRowSource {
    private let old = mirrorItem(id: "late-old", capturedAtNs: 100, text: "late old")
    private let newest = mirrorItem(id: "newest", capturedAtNs: 200, text: "newest")
    private(set) var requestedCursors: [SinceCursor] = []

    func fetch(cursor: SinceCursor, limit: Int) -> SincePageWire {
        requestedCursors.append(cursor)
        if cursor == .zero {
            return SincePageWire(
                ok: true,
                count: 2,
                items: [old, newest],
                nextCursor: SinceCursor(ingestedAtNs: 200, id: newest.id),
                hasMore: false,
                totalCount: 2,
                sourceDeviceID: "mac-a"
            )
        }
        // 模拟 source 在 client cursor 已到 200 后，才补进 ingested_at_ns=100 的旧行。
        // 普通增量为空，但 total_count 会暴露 client 永久漏了一行。
        return SincePageWire(
            ok: true,
            count: 0,
            items: [],
            nextCursor: cursor,
            hasMore: false,
            totalCount: 2,
            sourceDeviceID: "mac-a"
        )
    }
}

private actor GrowingSource {
    private var items: [Item]
    private(set) var requestedCursors: [SinceCursor] = []

    init(items: [Item]) {
        self.items = items
    }

    func append(_ item: Item) {
        items.append(item)
    }

    func fetch(cursor: SinceCursor, limit: Int) -> SincePageWire {
        requestedCursors.append(cursor)
        let remaining = items.sorted {
            ($0.ingestedAtNs ?? 0, $0.id) < ($1.ingestedAtNs ?? 0, $1.id)
        }.filter { item in
            let candidate = SinceCursor(ingestedAtNs: item.ingestedAtNs ?? 0, id: item.id)
            return candidate.ingestedAtNs > cursor.ingestedAtNs
                || (candidate.ingestedAtNs == cursor.ingestedAtNs && candidate.id > cursor.id)
        }
        let pageItems = Array(remaining.prefix(limit))
        let nextCursor = pageItems.last.map {
            SinceCursor(ingestedAtNs: $0.ingestedAtNs ?? 0, id: $0.id)
        } ?? cursor
        return SincePageWire(
            ok: true,
            count: pageItems.count,
            items: pageItems,
            nextCursor: nextCursor,
            hasMore: remaining.count > pageItems.count,
            totalCount: items.count,
            sourceDeviceID: "mac-a"
        )
    }
}

private actor SyncProgressRecorder {
    private(set) var values: [MetadataMirrorSyncProgress] = []

    func append(_ value: MetadataMirrorSyncProgress) {
        values.append(value)
    }
}

private actor ResumablePagedSource {
    private let items: [Item] = (1...5).map { index in
        mirrorItem(
            id: "resume-\(index)",
            capturedAtNs: Int64(index),
            text: "resume \(index)"
        )
    }
    private var interruptAfterFirstPage = true
    private(set) var requestedCursors: [SinceCursor] = []

    func fetch(cursor: SinceCursor, limit: Int) throws -> SincePageWire {
        requestedCursors.append(cursor)
        if interruptAfterFirstPage, cursor != .zero {
            interruptAfterFirstPage = false
            throw CancellationError()
        }
        let remaining = items.filter { item in
            let candidate = SinceCursor(ingestedAtNs: item.ingestedAtNs ?? 0, id: item.id)
            return candidate.ingestedAtNs > cursor.ingestedAtNs
                || (candidate.ingestedAtNs == cursor.ingestedAtNs && candidate.id > cursor.id)
        }
        let pageItems = Array(remaining.prefix(limit))
        let nextCursor = pageItems.last.map {
            SinceCursor(ingestedAtNs: $0.ingestedAtNs ?? 0, id: $0.id)
        } ?? cursor
        return SincePageWire(
            ok: true,
            count: pageItems.count,
            items: pageItems,
            nextCursor: nextCursor,
            hasMore: remaining.count > pageItems.count,
            totalCount: items.count,
            sourceDeviceID: "resume-mac"
        )
    }
}

@Suite("iOS metadata mirror")
struct MetadataMirrorStoreTests {
    @Test func foregroundAndBackgroundWritersConvergeOnOneCursor() async throws {
        let (mirror, _) = try makeMetadataMirror()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try mirror.applyPage(
                    items: [mirrorItem(id: "foreground", capturedAtNs: 200, text: "foreground")],
                    nextCursor: SinceCursor(ingestedAtNs: 200, id: "foreground")
                )
            }
            group.addTask {
                _ = try mirror.applyPage(
                    items: [mirrorItem(id: "background", capturedAtNs: 100, text: "background")],
                    nextCursor: SinceCursor(ingestedAtNs: 100, id: "background")
                )
            }
            try await group.waitForAll()
        }

        #expect(try mirror.activeItemCount() == 2)
        #expect(try mirror.cursor() == SinceCursor(ingestedAtNs: 200, id: "foreground"))
    }

    @Test func pageAndCursorCommitAtomicallyAndCursorNeverRegresses() throws {
        let (mirror, _) = try makeMetadataMirror()
        try mirror.database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_bad_mirror_item
                BEFORE INSERT ON item
                WHEN NEW.id = 'bad'
                BEGIN
                    SELECT RAISE(ABORT, 'injected page failure');
                END;
                """)
        }

        do {
            _ = try mirror.applyPage(
                items: [
                    mirrorItem(id: "good", capturedAtNs: 1, text: "good"),
                    mirrorItem(id: "bad", capturedAtNs: 2, text: "bad"),
                ],
                nextCursor: SinceCursor(ingestedAtNs: 2, id: "bad"),
                sourceDeviceID: "mac-a"
            )
            Issue.record("injected SQLite failure should abort the page")
        } catch {
            // expected
        }
        #expect(try mirror.activeItemCount() == 0)
        #expect(try mirror.cursor() == .zero)
        #expect(try mirror.trackedItemCount(sourceDeviceID: "mac-a") == 0)

        try mirror.database.pool.write { db in
            try db.execute(sql: "DROP TRIGGER reject_bad_mirror_item")
        }
        let advanced = try mirror.applyPage(
            items: [mirrorItem(id: "new", capturedAtNs: 20, text: "new")],
            nextCursor: SinceCursor(ingestedAtNs: 20, id: "new")
        )
        #expect(advanced == SinceCursor(ingestedAtNs: 20, id: "new"))

        let afterOldRetry = try mirror.applyPage(
            items: [
                mirrorItem(id: "old", capturedAtNs: 10, text: "old"),
                mirrorItem(id: "new", capturedAtNs: 10, ingestedAtNs: 10, text: "stale overwrite"),
            ],
            nextCursor: SinceCursor(ingestedAtNs: 10, id: "old")
        )
        #expect(afterOldRetry == advanced)
        #expect(try mirror.cursor() == advanced)
        #expect(try mirror.activeItemCount() == 2)
        #expect(try mirror.search(text: "stale overwrite").items.isEmpty)
        #expect(try mirror.search(text: "new").items.map(\.id) == ["new"])
    }

    @Test func unionExtrasCannotMaskLateOlderRowsFromOneSource() async throws {
        let (mirror, _) = try makeMetadataMirror()
        let newest = mirrorItem(id: "newest", capturedAtNs: 200, text: "newest")
        let otherPeerExtra = mirrorItem(
            id: "other-peer-extra",
            origin: "mac-b",
            capturedAtNs: 300,
            text: "already in union from another peer"
        )
        _ = try mirror.applyPage(
            items: [newest, otherPeerExtra],
            nextCursor: SinceCursor(ingestedAtNs: 300, id: otherPeerExtra.id)
        )
        let source = LateOlderRowSource()

        let progress = SyncProgressRecorder()
        let report = try await mirror.synchronize(
            progress: { await progress.append($0) },
            fetchPage: { cursor, limit in
                await source.fetch(cursor: cursor, limit: limit)
            }
        )

        #expect(report.incrementalPages == 1)
        #expect(report.backfillPages == 1)
        #expect(report.serverTotalCount == 2)
        #expect(report.localTotalCount == 3)
        #expect(report.sourceDeviceID == "mac-a")
        #expect(report.sourceTrackedItemCount == 2)
        #expect(try mirror.trackedItemCount(sourceDeviceID: "mac-a") == 2)
        #expect(try mirror.cursor() == SinceCursor(ingestedAtNs: 300, id: otherPeerExtra.id))
        #expect(try mirror.search(text: "late old").items.map(\.id) == ["late-old"])
        #expect(await source.requestedCursors == [
            SinceCursor(ingestedAtNs: 300, id: otherPeerExtra.id),
            .zero,
        ])
        #expect(await progress.values.map(\.pass) == [.incremental, .backfill])
        #expect(await progress.values.last?.sourceTrackedItemCount == 2)
        #expect(await progress.values.last?.serverTotalCount == 2)
    }

    @Test func interruptedInitialSyncResumesFromTheAtomicallyPersistedPage() async throws {
        let (mirror, _) = try makeMetadataMirror()
        let source = ResumablePagedSource()
        let progress = SyncProgressRecorder()

        do {
            _ = try await mirror.synchronize(
                pageLimit: 2,
                progress: { await progress.append($0) },
                fetchPage: { cursor, limit in
                    try await source.fetch(cursor: cursor, limit: limit)
                }
            )
            Issue.record("the first run should be interrupted after its first committed page")
        } catch is CancellationError {
            // Expected: the first page and cursor must remain durable for a later resume.
        }

        #expect(try mirror.totalItemCount() == 2)
        #expect(try mirror.cursor() == SinceCursor(ingestedAtNs: 2, id: "resume-2"))
        #expect(await progress.values.map(\.localItemCount) == [2])
        #expect(await progress.values.first?.hasMore == true)

        let report = try await mirror.synchronize(
            pageLimit: 2,
            progress: { await progress.append($0) },
            fetchPage: { cursor, limit in
                try await source.fetch(cursor: cursor, limit: limit)
            }
        )

        #expect(report.localTotalCount == 5)
        #expect(report.sourceTrackedItemCount == 5)
        #expect(report.finalCursor == SinceCursor(ingestedAtNs: 5, id: "resume-5"))
        #expect(await progress.values.map(\.localItemCount) == [2, 4, 5])
        #expect(await progress.values.last?.hasMore == false)
        #expect(await source.requestedCursors == [
            .zero,
            SinceCursor(ingestedAtNs: 2, id: "resume-2"),
            SinceCursor(ingestedAtNs: 2, id: "resume-2"),
            SinceCursor(ingestedAtNs: 4, id: "resume-4"),
        ])
    }

    @Test func ordinaryNewRowsAdvanceSourceLedgerWithoutFullBackfill() async throws {
        let (mirror, _) = try makeMetadataMirror()
        let first = mirrorItem(id: "first", capturedAtNs: 100, text: "first")
        let second = mirrorItem(id: "second", capturedAtNs: 200, text: "second")
        let source = GrowingSource(items: [first])

        let initial = try await mirror.synchronize { cursor, limit in
            await source.fetch(cursor: cursor, limit: limit)
        }
        #expect(initial.backfillPages == 0)
        #expect(initial.sourceTrackedItemCount == 1)

        await source.append(second)
        let incremental = try await mirror.synchronize { cursor, limit in
            await source.fetch(cursor: cursor, limit: limit)
        }
        #expect(incremental.incrementalPages == 1)
        #expect(incremental.backfillPages == 0)
        #expect(incremental.sourceTrackedItemCount == 2)
        #expect(incremental.localTotalCount == 2)
        #expect(await source.requestedCursors == [
            .zero,
            SinceCursor(ingestedAtNs: 100, id: first.id),
        ])
    }

    @Test func storesAndSearchesHistoryBeyondTheOldJSONLimitAcrossRestart() throws {
        let (mirror, path) = try makeMetadataMirror()
        for pageIndex in 0..<3 {
            let start = pageIndex * 500
            let items = (start..<(start + 500)).map { index in
                mirrorItem(
                    id: "archive-\(index)",
                    capturedAtNs: Int64(index + 1),
                    text: index == 0 ? "offline oldest needle" : "archive record \(index)"
                )
            }
            _ = try mirror.applyPage(
                items: items,
                nextCursor: SinceCursor(ingestedAtNs: Int64(start + 500), id: "archive-\(start + 499)")
            )
        }

        #expect(try mirror.activeItemCount() == 1_500)
        #expect(try mirror.recentItems(limit: 1_000).count == 1_000)
        #expect(try mirror.search(text: "offline oldest needle").items.map(\.id) == ["archive-0"])

        let reopened = try MetadataMirrorStore(path: path)
        #expect(try reopened.activeItemCount() == 1_500)
        #expect(try reopened.cursor().ingestedAtNs == 1_500)
        #expect(try reopened.search(text: "offline oldest needle").items.map(\.id) == ["archive-0"])
    }

    @Test func legacyImportIsInsertOnlyIdempotentAndDoesNotAdvanceCursor() throws {
        let (mirror, _) = try makeMetadataMirror()
        let stale = mirrorItem(id: "same", capturedAtNs: 1, text: "legacy stale")
        let other = mirrorItem(id: "legacy-only", capturedAtNs: 2, text: "legacy only")

        #expect(try mirror.importLegacyItems([stale, other]) == 2)
        #expect(try mirror.importLegacyItems([stale, other]) == 0)
        #expect(try mirror.cursor() == .zero)

        var canonical = stale
        canonical.capturedAtNs = 100
        canonical.ingestedAtNs = 100
        canonical.textFull = "canonical fresh"
        canonical.preview = "canonical fresh"
        _ = try mirror.applyPage(
            items: [canonical],
            nextCursor: SinceCursor(ingestedAtNs: 100, id: canonical.id)
        )
        #expect(try mirror.importLegacyItems([stale]) == 0)
        #expect(try mirror.search(text: "canonical fresh").items.map(\.id) == ["same"])
        #expect(try mirror.search(text: "legacy stale").items.isEmpty)
    }

    @Test func localQueryMatchesSearchAPIFoldAndQualifierSemantics() throws {
        let (mirror, _) = try makeMetadataMirror()
        let items = [
            mirrorItem(id: "hello-old", origin: "mac-a", capturedAtNs: 10, text: "hello world", pinned: true),
            mirrorItem(id: "hello-new", origin: "mac-b", capturedAtNs: 20, text: "hello world"),
            mirrorItem(id: "swift", capturedAtNs: 30, kind: .file, text: "/tmp/Thing.swift"),
            mirrorItem(id: "pdf", capturedAtNs: 40, kind: .file, text: "/tmp/Guide.pdf"),
            mirrorItem(id: "url", capturedAtNs: 50, kind: .url, text: "https://example.com/hello"),
        ]
        _ = try mirror.applyPage(
            items: items,
            nextCursor: SinceCursor(ingestedAtNs: 50, id: "url")
        )

        let local = try mirror.search(
            text: "hello",
            qualifiers: [.kind(.text), .kind(.url)],
            limit: 200
        )
        let direct = try SearchAPI(database: mirror.database).searchHitsAndCount(
            SearchQuery(text: "hello", kinds: [.text, .url], limit: 200)
        )

        #expect(local.items.map(\.id) == direct.hits.map(\.0.id))
        #expect(local.totalCount == direct.total)
        #expect(local.items.first(where: { $0.id == "hello-new" })?.pinned == true)
        #expect(!local.items.contains(where: { $0.id == "hello-old" }))

        let suffixLocal = try mirror.search(text: nil, qualifiers: [.textSuffix(".swift")])
        let suffixDirect = try SearchAPI(database: mirror.database).searchHits(
            SearchQuery(textFullSuffixes: [".swift"], limit: 200)
        )
        #expect(suffixLocal.items.map(\.id) == suffixDirect.map(\.0.id))
    }

    @Test(.timeLimit(.minutes(1)))
    func hundredThousandRowsColdOpenAndFTSStayInteractive() throws {
        let (mirror, path) = try makeMetadataMirror()
        let pageSize = 2_000
        for start in stride(from: 0, to: 100_000, by: pageSize) {
            let items = (start..<(start + pageSize)).map { index in
                mirrorItem(
                    id: String(format: "perf-%06d", index),
                    capturedAtNs: Int64(index + 1),
                    text: index == 99_999
                        ? "uniqueofflineperformance needle"
                        : "ordinary clipboard metadata \(index)"
                )
            }
            _ = try mirror.applyPage(
                items: items,
                nextCursor: SinceCursor(
                    ingestedAtNs: Int64(start + pageSize),
                    id: String(format: "perf-%06d", start + pageSize - 1)
                )
            )
        }

        let clock = ContinuousClock()
        let coldStart = clock.now
        let reopened = try MetadataMirrorStore(path: path)
        let recent = try reopened.recentItems(limit: 1_000)
        let coldDuration = coldStart.duration(to: clock.now)

        let searchStart = clock.now
        let result = try reopened.search(text: "uniqueofflineperformance")
        let searchDuration = searchStart.duration(to: clock.now)

        let qualifierStart = clock.now
        let emptyURLResult = try reopened.search(text: nil, qualifiers: [.kind(.url)])
        let qualifierDuration = qualifierStart.duration(to: clock.now)

        #expect(recent.count == 1_000)
        #expect(result.items.map(\.id) == ["perf-099999"])
        #expect(emptyURLResult.items.isEmpty)
        // Generous anti-flake gates: either duration would be a visible UI stall on an M-series host.
        #expect(coldDuration < .seconds(2), "cold open + recent page took \(coldDuration)")
        #expect(searchDuration < .seconds(1), "local FTS search took \(searchDuration)")
        #expect(qualifierDuration < .seconds(2), "100k qualifier search took \(qualifierDuration)")
    }
}

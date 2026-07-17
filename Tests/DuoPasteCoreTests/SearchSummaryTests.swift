import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

private typealias SummaryDB = DuoPasteCore.Database

private func makeSummaryDB() throws -> SummaryDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-search-summary-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try SummaryDB(path: paths.mainDB)
}

private func summaryItem(
    id: String,
    origin: String = "local",
    captured: Int64,
    kind: ItemKind = .text,
    text: String? = nil,
    sha: String? = nil,
    mime: String? = nil,
    pinned: Bool = false
) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: captured,
        ingestedAtNs: captured,
        kind: kind,
        preview: text,
        textFull: text,
        blobSha256: sha,
        blobSize: sha == nil ? nil : 32,
        blobMime: mime,
        pinned: pinned
    )
}

private func insertSummaryItems(_ items: [Item], into database: SummaryDB) throws {
    try database.pool.write { db in
        for item in items { try item.insert(db) }
    }
}

private func expectSummaryMatchesLegacy(
    _ api: SearchAPI,
    query: SearchQuery,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let summary = try api.searchSummary(query)
    let hits = try api.searchHits(query)
    let total = try api.count(query)
    let kinds = try api.countByKind(query)
    let fileKinds = try api.countByFileSubKind(query)

    #expect(summary.hits.map(\.0.id) == hits.map(\.0.id), sourceLocation: sourceLocation)
    #expect(summary.hits.map(\.1) == hits.map(\.1), sourceLocation: sourceLocation)
    #expect(summary.totalCount == total, sourceLocation: sourceLocation)
    #expect(summary.kindCounts == kinds, sourceLocation: sourceLocation)
    #expect(summary.fileSubKindCounts == fileKinds, sourceLocation: sourceLocation)
}

@Test("search summary 保持 fold、facet、qualifier 和分页四路等价")
func searchSummaryMatchesLegacyPaths() throws {
    let database = try makeSummaryDB()
    let imageSHA = String(repeating: "a", count: 64)
    try insertSummaryItems([
        summaryItem(id: "text-old", origin: "a", captured: 100, kind: .text,
                    text: "shared", pinned: true),
        summaryItem(id: "text-new", origin: "b", captured: 500, kind: .url,
                    text: "shared"),
        summaryItem(id: "swift", captured: 450, kind: .file,
                    text: "/tmp/App.swift", mime: "text/x-swift"),
        summaryItem(id: "video", captured: 400, kind: .file,
                    text: "/tmp/movie.mp4", mime: "video/mp4"),
        summaryItem(id: "literal-percent", captured: 390, kind: .file,
                    text: "/tmp/literal%"),
        summaryItem(id: "image-a", origin: "a", captured: 200, kind: .image,
                    sha: imageSHA, mime: "image/png"),
        summaryItem(id: "image-b", origin: "b", captured: 205, kind: .image,
                    sha: imageSHA, mime: "image/png"),
        summaryItem(id: "image-repeat", origin: "a", captured: 210, kind: .image,
                    sha: imageSHA, mime: "image/png"),
    ], into: database)
    // 显式走 bulk rebuild，覆盖旧库 migration / benchmark restore 会使用的流式路径；
    // 后续逐项查询再验证它与增量 projection 语义一致。
    try database.rebuildSearchFoldProjection()
    let api = SearchAPI(database: database)

    try expectSummaryMatchesLegacy(api, query: SearchQuery(limit: 3, offset: 1))
    try expectSummaryMatchesLegacy(api, query: SearchQuery(kinds: [.url], limit: 20))
    try expectSummaryMatchesLegacy(api, query: SearchQuery(
        kinds: [.text], fileSubKinds: [.video], textFullSuffixes: [".swift"], limit: 20
    ))
    try expectSummaryMatchesLegacy(api, query: SearchQuery(pinnedOnly: true, limit: 20))
    try expectSummaryMatchesLegacy(api, query: SearchQuery(textFullSuffixes: [".swift"], limit: 20))
    try expectSummaryMatchesLegacy(api, query: SearchQuery(textFullSuffixes: ["%"], limit: 20))
}

@Test("search summary 非空 FTS 与时间范围走一次 fold fallback 且保留 snippet")
func searchSummaryFallbackMatchesLegacy() throws {
    let database = try makeSummaryDB()
    try insertSummaryItems([
        summaryItem(id: "old", origin: "a", captured: 100, text: "alpha needle"),
        summaryItem(id: "new", origin: "b", captured: 500, text: "alpha needle", pinned: true),
        summaryItem(id: "other", captured: 300, kind: .url, text: "needle elsewhere"),
    ], into: database)
    let api = SearchAPI(database: database)

    try expectSummaryMatchesLegacy(api, query: SearchQuery(text: "needle", limit: 20))
    try expectSummaryMatchesLegacy(api, query: SearchQuery(fromNs: 50, toNs: 350, limit: 20))
}

@Test("v16 projection 由 dirty group 增量刷新并可跨 reopen 复用")
func searchFoldProjectionRefreshesIncrementally() throws {
    let database = try makeSummaryDB()
    try insertSummaryItems([
        summaryItem(id: "a", origin: "a", captured: 100, text: "same"),
        summaryItem(id: "unique", captured: 90, text: "unique"),
    ], into: database)
    let api = SearchAPI(database: database)

    let first = try api.searchSummary(SearchQuery())
    #expect(first.totalCount == 2)
    let firstState = try database.pool.read { db in
        (
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fold_dirty") ?? -1,
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fold") ?? -1
        )
    }
    #expect(firstState.0 == 0)
    #expect(firstState.1 == 2)

    try insertSummaryItems([
        summaryItem(id: "b", origin: "b", captured: 200, kind: .url,
                    text: "same", pinned: true),
    ], into: database)
    let dirtyBefore = try database.pool.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fold_dirty") ?? 0
    }
    #expect(dirtyBefore == 1)

    let refreshed = try api.searchSummary(SearchQuery())
    #expect(refreshed.totalCount == 2)
    #expect(refreshed.hits.first?.0.id == "b")
    #expect(refreshed.hits.first?.0.pinned == true)
    #expect(refreshed.kindCounts[.url] == 1)
    #expect(refreshed.kindCounts[.text] == 1)

    let projectionAfter = try database.pool.read { db in
        (
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fold_dirty") ?? -1,
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fold") ?? -1
        )
    }
    #expect(projectionAfter.0 == 0)
    #expect(projectionAfter.1 == 2)

    let databasePath = try database.pool.read { db -> String in
        let rows = try Row.fetchAll(db, sql: "PRAGMA database_list")
        return rows.first { ($0["name"] as String?) == "main" }?["file"] ?? ""
    }
    #expect(!databasePath.isEmpty)
    let reopened = try SummaryDB(path: URL(fileURLWithPath: databasePath))
    let afterReopen = try SearchAPI(database: reopened).searchSummary(SearchQuery())
    #expect(afterReopen.hits.map(\.0.id) == refreshed.hits.map(\.0.id))
    #expect(afterReopen.totalCount == refreshed.totalCount)
}

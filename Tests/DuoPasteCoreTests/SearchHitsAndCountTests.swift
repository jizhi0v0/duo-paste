import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

/// `SearchAPI.searchHitsAndCount` 单次 pass 等价性回归——必须跟 `searchHits + count`
/// 两条独立路径在所有维度上对齐。HTTP `/search` handler 切到 single-pass 版本,
/// 这条钉死避免后续重构破坏 fold-aware 不变量(跨 origin 同 text fold,pinned OR 聚合)

private typealias DuoDB = DuoPasteCore.Database

private func makeDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-hitsAndCount-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func insertText(_ db: DuoDB, id: String, origin: String, text: String, capturedAtNs: Int64, pinned: Bool = false) throws {
    let it = Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedAtNs,
        ingestedAtNs: capturedAtNs,
        kind: .text,
        preview: text,
        textFull: text,
        pinned: pinned
    )
    try db.pool.write { try it.insert($0) }
}

@Test func hitsAndCountMatchesSeparatePaths_textQuery() async throws {
    let db = try makeDB()
    try insertText(db, id: "a", origin: "mac-1", text: "hello world",   capturedAtNs: 100)
    try insertText(db, id: "b", origin: "mac-1", text: "goodbye world", capturedAtNs: 200)
    try insertText(db, id: "c", origin: "mac-1", text: "another item",  capturedAtNs: 300)
    let api = SearchAPI(database: db)

    let q = SearchQuery(text: "world", limit: 200, offset: 0)
    let (hits, total) = try api.searchHitsAndCount(q)
    let separateHits = try api.searchHits(q)
    let separateTotal = try api.count(q)

    #expect(total == separateTotal)
    #expect(hits.count == separateHits.count)
    #expect(hits.map(\.0.id) == separateHits.map(\.0.id))
    // snippet 也对齐(STX/ETX 一致)
    #expect(hits.map(\.1) == separateHits.map(\.1))
}

@Test func hitsAndCountMatchesSeparatePaths_emptyQuery() async throws {
    let db = try makeDB()
    try insertText(db, id: "old", origin: "mac-1", text: "old",    capturedAtNs: 100)
    try insertText(db, id: "mid", origin: "mac-1", text: "middle", capturedAtNs: 200)
    try insertText(db, id: "new", origin: "mac-1", text: "newest", capturedAtNs: 300)
    let api = SearchAPI(database: db)

    let q = SearchQuery(text: nil, limit: 200, offset: 0)
    let (hits, total) = try api.searchHitsAndCount(q)
    let separateTotal = try api.count(q)
    let separateHits = try api.searchHits(q)

    #expect(total == 3)
    #expect(total == separateTotal)
    #expect(hits.map(\.0.id) == separateHits.map(\.0.id))
    #expect(hits.first?.0.id == "new")  // 时间倒序
}

@Test func hitsAndCountFoldsCrossOriginSameText() async throws {
    let db = try makeDB()
    try insertText(db, id: "own",  origin: "mac-self",  text: "duplicate", capturedAtNs: 100)
    try insertText(db, id: "peer", origin: "mac-other", text: "duplicate", capturedAtNs: 200)
    let api = SearchAPI(database: db)

    let (hits, total) = try api.searchHitsAndCount(SearchQuery(text: "duplicate", limit: 200))
    #expect(total == 1)
    #expect(hits.count == 1)
}

@Test func hitsAndCountHonorsLimitAndOffset() async throws {
    let db = try makeDB()
    for i in 1...10 {
        try insertText(db, id: "row-\(i)", origin: "mac-1", text: "tag-\(i)", capturedAtNs: Int64(i))
    }
    let api = SearchAPI(database: db)

    // 取第 2 页 (offset=3, limit=3) → 应该返 7 6 5 (按 captured DESC)
    let q = SearchQuery(text: nil, limit: 3, offset: 3)
    let (hits, total) = try api.searchHitsAndCount(q)
    #expect(total == 10)                                  // 全集大小不受 limit/offset 影响
    #expect(hits.count == 3)
    #expect(hits.map(\.0.id) == ["row-7", "row-6", "row-5"])
}

@Test func hitsAndCountWhenOffsetExceedsTotal() async throws {
    let db = try makeDB()
    try insertText(db, id: "a", origin: "mac-1", text: "x", capturedAtNs: 100)
    let api = SearchAPI(database: db)

    let q = SearchQuery(text: nil, limit: 10, offset: 50)
    let (hits, total) = try api.searchHitsAndCount(q)
    #expect(total == 1)
    #expect(hits.isEmpty)
}

import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private typealias DuoDB = DuoPasteCore.Database

/// 非空搜索：prefix group → contains group；每组 captured_at_ns DESC，pin 不参与相关性。
/// 空搜索：pinned DESC → captured_at_ns DESC。
private func makeDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-prefix-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func insertOwn(
    _ db: DuoDB,
    id: String,
    capturedAtNs: Int64,
    text: String,
    pinned: Bool = false
) throws {
    let it = Item(
        id: id,
        originDevice: "self",
        capturedAtNs: capturedAtNs,
        kind: .text,
        sourceAppName: "T",
        preview: text,
        textFull: text,
        pinned: pinned
    )
    try db.pool.write { conn in try it.insert(conn) }
}

/// v7 合表后 peer 行直接落 item 表（origin != self，PullWorker 写时强制 push_state='acked'）。
/// 名字保留 `insertMirror` 让测试语义可读，实际写 item 表。
private func insertMirror(
    _ db: DuoDB,
    id: String,
    capturedAtNs: Int64,
    text: String,
    pinned: Bool = false
) throws {
    let it = Item(
        id: id,
        originDevice: "primary",
        capturedAtNs: capturedAtNs,
        ingestedAtNs: capturedAtNs,
        kind: .text,
        sourceAppName: "T",
        preview: text,
        textFull: text,
        pinned: pinned
    )
    try db.pool.write { conn in try it.insert(conn) }
}

private func nowNs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000_000)
}

@Test func prefixHitWinsOverNewerNonPrefixInSingleTable() throws {
    // older prefix match 应排到 newer non-prefix match 前面，纯时间倒序会反过来
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "older-prefix",
                  capturedAtNs: now - 60_000_000_000,   // 60s ago
                  text: "git status output")
    try insertOwn(db, id: "newer-noprefix",
                  capturedAtNs: now - 30_000_000_000,   // 30s ago, 更新
                  text: "the git command was nice")     // git 不在起始位置
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(text: "git", limit: 10))
    #expect(hits.map(\.0.id) == ["older-prefix", "newer-noprefix"])
}

@Test func prefixRelevanceBeatsPinnedContains() throws {
    // 搜索相关性优先：pinned 的包含命中不能压过未 pinned 的前缀命中。
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "pinned-noprefix",
                  capturedAtNs: now - 90_000_000_000,
                  text: "see git inside",
                  pinned: true)
    try insertOwn(db, id: "unpinned-prefix",
                  capturedAtNs: now - 30_000_000_000,
                  text: "git status")
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(text: "git", limit: 10))
    #expect(hits.map(\.0.id) == ["unpinned-prefix", "pinned-noprefix"])
}

@Test func prefixRelevanceHasNoAgeWindow() throws {
    // 前缀相关性不设 24h 窗：两天前 prefix 仍排在 1h 前 contains 前。
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "old-prefix",
                  capturedAtNs: now - 48 * 3600 * 1_000_000_000,   // 48h ago, 出窗
                  text: "git ancient note")
    try insertOwn(db, id: "recent-noprefix",
                  capturedAtNs: now - 3600 * 1_000_000_000,         // 1h ago, 窗内
                  text: "look the git is here")
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(text: "git", limit: 10))
    #expect(hits.map(\.0.id) == ["old-prefix", "recent-noprefix"])
}

@Test func pinnedDoesNotReorderContainsGroup() throws {
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "older-pinned",
                  capturedAtNs: now - 90_000_000_000,
                  text: "contains git here",
                  pinned: true)
    try insertOwn(db, id: "newer-unpinned",
                  capturedAtNs: now - 30_000_000_000,
                  text: "newer git here")
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(text: "git", limit: 10))
    #expect(hits.map(\.0.id) == ["newer-unpinned", "older-pinned"])
}

@Test func emptyQueryStillSortsPinnedBeforeTime() throws {
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "older-pinned",
                  capturedAtNs: now - 90_000_000_000,
                  text: "old",
                  pinned: true)
    try insertOwn(db, id: "newer-unpinned",
                  capturedAtNs: now - 30_000_000_000,
                  text: "new")
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(limit: 10))
    #expect(hits.map(\.0.id) == ["older-pinned", "newer-unpinned"])
}

@Test func previewAndFullTextPrefixesShareOneRelevanceTier() throws {
    let db = try makeDB()
    let now = nowNs()
    let olderPreviewPrefix = Item(
        id: "older-preview-prefix", originDevice: "self",
        capturedAtNs: now - 90_000_000_000, kind: .text,
        preview: "git old", textFull: "contains git old"
    )
    let newerFullTextPrefix = Item(
        id: "newer-full-prefix", originDevice: "self",
        capturedAtNs: now - 30_000_000_000, kind: .text,
        preview: "contains git new", textFull: "git new"
    )
    try db.pool.write { conn in
        try olderPreviewPrefix.insert(conn)
        try newerFullTextPrefix.insert(conn)
    }
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(text: "git", limit: 10))
    #expect(hits.map(\.0.id) == ["newer-full-prefix", "older-preview-prefix"])
}

@Test func unionPrefixBoostMatchesSingleTableOrdering() throws {
    // 跨表 union 排序必须复现单表 fetchHits 的 prefix 优先级。
    // own 表 prefix-match 较老 + mirror 表 non-prefix 较新 → prefix 仍应胜出。
    // 反例：如果 fetchUnion 的 Swift dedup 排序漏掉 prefix-score 步骤，时间更新的 mirror 会赢
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "own-prefix",
                  capturedAtNs: now - 30 * 60 * 1_000_000_000,    // 30min ago
                  text: "git diff main")
    try insertMirror(db, id: "mir-noprefix",
                     capturedAtNs: now - 15 * 60 * 1_000_000_000, // 15min ago, 更新
                     text: "tracking git issues")
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(text: "git", limit: 10))
    #expect(hits.map(\.0.id) == ["own-prefix", "mir-noprefix"])
}

@Test func directSearchAndFoldedHitsShareRelevanceOrdering() throws {
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "pinned-contains",
                  capturedAtNs: now - 10_000_000_000,
                  text: "contains git",
                  pinned: true)
    try insertOwn(db, id: "older-prefix",
                  capturedAtNs: now - 30_000_000_000,
                  text: "git older")
    try insertOwn(db, id: "newer-prefix",
                  capturedAtNs: now - 20_000_000_000,
                  text: "git newer")
    let query = SearchQuery(text: "git", limit: 10)
    let api = SearchAPI(database: db)

    #expect(try api.search(query).map(\.id) == ["newer-prefix", "older-prefix", "pinned-contains"])
    #expect(try api.searchHits(query).map(\.0.id) == ["newer-prefix", "older-prefix", "pinned-contains"])
}

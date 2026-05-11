import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private typealias DuoDB = DuoPasteCore.Database

private func makeDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-union-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB, role: .client)
}

/// 直接拿 SQL 往 item_mirror 写——CaptureService 不写 mirror，只能手写 schema。
private func insertMirror(
    _ db: DuoDB,
    id: String,
    origin: String,
    capturedAtNs: Int64,
    ingestedAtNs: Int64? = nil,
    kind: ItemKind = .text,
    text: String = "",
    sourceAppName: String? = "Mirror App",
    pinned: Bool = false,
    deletedAtNs: Int64? = nil
) throws {
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item_mirror (
                id, origin_device, captured_at_ns, ingested_at_ns, kind,
                source_app, source_app_name, preview, text_full,
                blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, mirrored_at_ns
            ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?)
        """, arguments: [
            id, origin, capturedAtNs, ingestedAtNs ?? capturedAtNs, kind.rawValue,
            sourceAppName, text, text,
            pinned ? 1 : 0, deletedAtNs, capturedAtNs
        ])
    }
}

private func insertOwn(
    _ db: DuoDB,
    id: String,
    origin: String = "self",
    capturedAtNs: Int64,
    kind: ItemKind = .text,
    text: String = "",
    pinned: Bool = false
) throws {
    let it = Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedAtNs,
        kind: kind,
        sourceAppName: "Own App",
        preview: text,
        textFull: text,
        pinned: pinned,
        pushState: .acked
    )
    try db.pool.write { conn in try it.insert(conn) }
}

@Test func unionMergesAndSortsByCapturedAtDesc() throws {
    let db = try makeDB()
    try insertOwn(db, id: "own-100", capturedAtNs: 100, text: "own one")
    try insertMirror(db, id: "mir-50", origin: "primary", capturedAtNs: 50, text: "mirror older")
    try insertMirror(db, id: "mir-200", origin: "primary", capturedAtNs: 200, text: "mirror newer")
    try insertOwn(db, id: "own-150", capturedAtNs: 150, text: "own mid")
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.map(\.0.id) == ["mir-200", "own-150", "own-100", "mir-50"])
}

@Test func unionPinnedAlwaysFirst() throws {
    let db = try makeDB()
    try insertOwn(db, id: "fresh", capturedAtNs: 1000, text: "newest")
    try insertMirror(db, id: "old-pin", origin: "primary", capturedAtNs: 100, text: "pinned mirror", pinned: true)
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.first?.0.id == "old-pin")
}

@Test func unionLimitAndOffsetWorksAcrossBothTables() throws {
    let db = try makeDB()
    try insertOwn(db, id: "a", capturedAtNs: 500, text: "alpha")
    try insertMirror(db, id: "b", origin: "primary", capturedAtNs: 400, text: "bravo")
    try insertOwn(db, id: "c", capturedAtNs: 300, text: "charlie")
    try insertMirror(db, id: "d", origin: "primary", capturedAtNs: 200, text: "delta")
    let api = SearchAPI(database: db)
    let page1 = try api.searchUnion(SearchQuery(limit: 2, offset: 0))
    #expect(page1.map(\.0.id) == ["a", "b"])
    let page2 = try api.searchUnion(SearchQuery(limit: 2, offset: 2))
    #expect(page2.map(\.0.id) == ["c", "d"])
}

@Test func unionDedupePrefersNewerCapturedAtRegardlessOfPin() throws {
    // 回归保护：mirror 那份 pinned=true（用户在 primary 上 pin 了但还没回传），
    // own 那份是更新的 unpinned 文本。dedupe 必须取 own 那份（更近的 capturedAtNs），
    // 否则 UI 显示陈旧的 mirror 文本。
    let db = try makeDB()
    try insertOwn(db, id: "x", capturedAtNs: 1000, text: "freshest unpinned", pinned: false)
    try insertMirror(db, id: "x", origin: "primary", capturedAtNs: 100, text: "old pinned", pinned: true)
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.count == 1)
    #expect(hits.first?.0.capturedAtNs == 1000)
    #expect(hits.first?.0.textFull == "freshest unpinned")
    #expect(hits.first?.0.pinned == false)
}

@Test func unionDedupesOnSameID() throws {
    // 边界：promote-to-primary 流程中 item 和 item_mirror 同时有同 id 行，UNION 应只出一份。
    // 优先级：seen 用排序后的顺序填充——按 captured_at_ns 取最近那一份。
    let db = try makeDB()
    try insertOwn(db, id: "dup", capturedAtNs: 500, text: "own latest")
    try insertMirror(db, id: "dup", origin: "primary", capturedAtNs: 400, text: "mirror older")
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.count == 1)
    #expect(hits.first?.0.capturedAtNs == 500)  // 取最近那份
}

@Test func unionFTSHitsAcrossBothTables() throws {
    let db = try makeDB()
    try insertOwn(db, id: "own", capturedAtNs: 100, text: "needle in own table")
    try insertMirror(db, id: "mir", origin: "primary", capturedAtNs: 200, text: "needle in mirror table")
    try insertOwn(db, id: "other", capturedAtNs: 300, text: "no match here")
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(text: "needle", limit: 10))
    #expect(hits.map(\.0.id).sorted() == ["mir", "own"])
    // 两边都应该有 snippet（FTS 命中）
    for hit in hits {
        #expect(hit.1?.contains("\u{02}") == true)
    }
}

@Test func unionSoftDeletedFilteredOut() throws {
    let db = try makeDB()
    try insertOwn(db, id: "alive", capturedAtNs: 100, text: "ok")
    try insertMirror(db, id: "deleted-mirror", origin: "primary", capturedAtNs: 200, text: "rip", deletedAtNs: 999)
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.map(\.0.id) == ["alive"])
}

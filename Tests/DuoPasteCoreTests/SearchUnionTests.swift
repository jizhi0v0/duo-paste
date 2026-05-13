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

// MARK: - count / countUnion

@Test func countItemRespectsLimitlessTotal() throws {
    // count 必须忽略 limit/offset，否则 UI counter 一旦库 ≥200 就永远定格在 200。
    let db = try makeDB()
    for i in 0..<5 {
        try insertOwn(db, id: "i-\(i)", capturedAtNs: Int64(i) * 10, text: "n\(i)")
    }
    let api = SearchAPI(database: db)
    // 即便 SearchQuery 写了 limit=2，count 也应该返回 5
    #expect(try api.count(SearchQuery(limit: 2)) == 5)
}

@Test func countItemAppliesFTSFilter() throws {
    let db = try makeDB()
    try insertOwn(db, id: "a", capturedAtNs: 100, text: "needle here")
    try insertOwn(db, id: "b", capturedAtNs: 200, text: "no match")
    try insertOwn(db, id: "c", capturedAtNs: 300, text: "another needle")
    #expect(try SearchAPI(database: db).count(SearchQuery(text: "needle")) == 2)
}

@Test func countItemSkipsSoftDeleted() throws {
    let db = try makeDB()
    try insertOwn(db, id: "alive", capturedAtNs: 100, text: "ok")
    // 软删 own：直接 SQL stamp deleted_at_ns
    try insertOwn(db, id: "gone", capturedAtNs: 200, text: "buried")
    try db.pool.write { conn in
        try conn.execute(sql: "UPDATE item SET deleted_at_ns = 999 WHERE id = 'gone'")
    }
    #expect(try SearchAPI(database: db).count(SearchQuery()) == 1)
}

@Test func countUnionDedupesSameIDAcrossTables() throws {
    // 关键回归：同 id 跨表存在（promote-to-primary 过渡期常见）必须算 1 不能算 2。
    // 用 UNION（不是 UNION ALL）在 id 维度去重。
    let db = try makeDB()
    try insertOwn(db, id: "dup", capturedAtNs: 500, text: "own version")
    try insertMirror(db, id: "dup", origin: "primary", capturedAtNs: 400, text: "mirror version")
    try insertOwn(db, id: "only-own", capturedAtNs: 100, text: "just own")
    try insertMirror(db, id: "only-mir", origin: "primary", capturedAtNs: 200, text: "just mirror")
    #expect(try SearchAPI(database: db).countUnion(SearchQuery()) == 3)
}

@Test func countUnionWithFTSAcrossBothTables() throws {
    let db = try makeDB()
    try insertOwn(db, id: "own", capturedAtNs: 100, text: "needle in own table")
    try insertMirror(db, id: "mir", origin: "primary", capturedAtNs: 200, text: "needle in mirror table")
    try insertOwn(db, id: "other", capturedAtNs: 300, text: "no match")
    #expect(try SearchAPI(database: db).countUnion(SearchQuery(text: "needle")) == 2)
}

@Test func countUnionSkipsSoftDeletedOnBothSides() throws {
    let db = try makeDB()
    try insertOwn(db, id: "alive-own", capturedAtNs: 100, text: "ok")
    try insertMirror(db, id: "alive-mir", origin: "primary", capturedAtNs: 200, text: "ok")
    try insertMirror(db, id: "dead-mir", origin: "primary", capturedAtNs: 300, text: "rip", deletedAtNs: 999)
    try insertOwn(db, id: "dead-own", capturedAtNs: 400, text: "rip")
    try db.pool.write { conn in
        try conn.execute(sql: "UPDATE item SET deleted_at_ns = 999 WHERE id = 'dead-own'")
    }
    #expect(try SearchAPI(database: db).countUnion(SearchQuery()) == 2)
}

// MARK: - countByKind / countByKindUnion

@Test func countByKindUnionGroupsAcrossBothTables() throws {
    // 模拟典型场景：本机 own 主要是 text，mirror 镜了 image 过来
    let db = try makeDB()
    try insertOwn(db, id: "t1", capturedAtNs: 100, kind: .text, text: "alpha")
    try insertOwn(db, id: "t2", capturedAtNs: 200, kind: .text, text: "bravo")
    try insertOwn(db, id: "i1", capturedAtNs: 300, kind: .image)
    try insertMirror(db, id: "mi1", origin: "primary", capturedAtNs: 400, kind: .image, text: "img1")
    try insertMirror(db, id: "mi2", origin: "primary", capturedAtNs: 500, kind: .image, text: "img2")
    try insertMirror(db, id: "mu1", origin: "primary", capturedAtNs: 600, kind: .url, text: "https://x")
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery())
    #expect(counts[.text] == 2)
    #expect(counts[.image] == 3)
    #expect(counts[.url] == 1)
    #expect(counts[.html] == nil)  // 没出现的 kind 不要塞 0，让 UI 自行决定显示策略
}

@Test func countByKindUnionIgnoresQueryKindsFilter() throws {
    // 关键不变量：chip 上的数字表示"如果只选这个 kind 会有多少"，所以传进来的 query.kinds
    // 必须被忽略——否则用户多选 chip 时 count 来回跳，无法判断稀疏类型
    let db = try makeDB()
    try insertOwn(db, id: "t1", capturedAtNs: 100, kind: .text, text: "x")
    try insertOwn(db, id: "i1", capturedAtNs: 200, kind: .image)
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery(kinds: [.text]))
    #expect(counts[.text] == 1)
    #expect(counts[.image] == 1)  // ← 不被 kinds=[.text] 过滤掉
}

@Test func countByKindUnionAppliesFTSAndTimeWindow() throws {
    // chip count 必须跟 query / timeRange / pinnedOnly 联动——只有 kinds 维度被剥离。
    // 这样用户输入 "foo" 后 chip 数字立刻反映"包含 foo 的 X 类有几条"。
    let db = try makeDB()
    try insertOwn(db, id: "t1", capturedAtNs: 100, kind: .text, text: "needle text")
    try insertOwn(db, id: "t2", capturedAtNs: 200, kind: .text, text: "irrelevant")
    try insertMirror(db, id: "i1", origin: "primary", capturedAtNs: 300, kind: .image, text: "needle img")
    try insertMirror(db, id: "i2", origin: "primary", capturedAtNs: 400, kind: .image, text: "other")
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery(text: "needle"))
    #expect(counts[.text] == 1)
    #expect(counts[.image] == 1)
}

@Test func countByKindUnionDedupesCrossTableSameID() throws {
    // 同 id 跨表（promote 过渡期）算一份。kind 一致 → UNION 去重生效。
    let db = try makeDB()
    try insertOwn(db, id: "dup", capturedAtNs: 200, kind: .image)
    try insertMirror(db, id: "dup", origin: "primary", capturedAtNs: 100, kind: .image)
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery())
    #expect(counts[.image] == 1)
}

@Test func countByKindFallsBackToItemOnlyForStandalone() throws {
    // standalone / pure-primary 走 countByKind（只 own 表），不掺 mirror
    let db = try makeDB()
    try insertOwn(db, id: "t1", capturedAtNs: 100, kind: .text, text: "x")
    try insertOwn(db, id: "i1", capturedAtNs: 200, kind: .image)
    try insertMirror(db, id: "m1", origin: "primary", capturedAtNs: 300, kind: .image, text: "should-not-count")
    let counts = try SearchAPI(database: db).countByKind(SearchQuery())
    #expect(counts[.text] == 1)
    #expect(counts[.image] == 1)  // mirror 那行不算进去
}

@Test func countByKindUnionSkipsSoftDeletedByDefault() throws {
    let db = try makeDB()
    try insertOwn(db, id: "alive", capturedAtNs: 100, kind: .text, text: "ok")
    try insertMirror(db, id: "dead", origin: "primary", capturedAtNs: 200, kind: .image, text: "rip", deletedAtNs: 999)
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery())
    #expect(counts[.text] == 1)
    #expect(counts[.image] == nil)  // 唯一一行 image 是软删的，桶里不该出现
}

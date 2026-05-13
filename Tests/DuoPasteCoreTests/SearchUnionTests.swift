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
    // 文本各 distinct，避免触发文本 fold 干扰这条 soft-delete 路径的不变量验证。
    let db = try makeDB()
    try insertOwn(db, id: "alive-own", capturedAtNs: 100, text: "alive own text")
    try insertMirror(db, id: "alive-mir", origin: "primary", capturedAtNs: 200, text: "alive mirror text")
    try insertMirror(db, id: "dead-mir", origin: "primary", capturedAtNs: 300, text: "rip mirror", deletedAtNs: 999)
    try insertOwn(db, id: "dead-own", capturedAtNs: 400, text: "rip own")
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
    // 同 id 跨表（promote 过渡期）算一份。dedupe 走 ROW_NUMBER OVER captured_at_ns DESC，
    // 取 winner 行的 kind——kind 一致时这条 case 跟 winner kind 不同 case 收敛到同一结果。
    let db = try makeDB()
    try insertOwn(db, id: "dup", capturedAtNs: 200, kind: .image)
    try insertMirror(db, id: "dup", origin: "primary", capturedAtNs: 100, kind: .image)
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery())
    #expect(counts[.image] == 1)
}

@Test func countByKindUnionDedupesCrossTableKindDivergence() throws {
    // 边界：同 id 跨表 kind 不一致（极少见但可能——schema 演进 / 异常状态）。
    // 必须按 captured_at_ns DESC 选 winner 行的 kind，跟 fetchUnion 的 dedup 不变量对齐——
    // 否则 chip 显示 "image 1" 但用户点 image 后看不到该行（winner 那份其实是 text）。
    let db = try makeDB()
    try insertOwn(db, id: "dup", capturedAtNs: 200, kind: .text, text: "winner")
    try insertMirror(db, id: "dup", origin: "primary", capturedAtNs: 100, kind: .image)
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery())
    #expect(counts[.text] == 1)
    #expect(counts[.image] == nil)  // 落选的 mirror 行不进桶
}

@Test func countByKindUnionTieBreaksOwnOverMirror() throws {
    // 边界：同 id 跨表 captured_at_ns 完全相等（极少见但理论上可能：手动 replay INSERT
    // 或时钟跳变）。ROW_NUMBER 单看 captured_at_ns 不确定 winner——加 _src tiebreak
    // own=0 / mirror=1 让 own 赢，跟 fetchUnion Swift 端"先 own 后 mirror + 严格大于
    // 才覆盖"的不变量一致，避免 SQL / Swift 路径在边界 case 上分裂。
    let db = try makeDB()
    try insertOwn(db, id: "tie", capturedAtNs: 500, kind: .text, text: "own wins")
    try insertMirror(db, id: "tie", origin: "primary", capturedAtNs: 500, kind: .image)
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery())
    #expect(counts[.text] == 1)
    #expect(counts[.image] == nil)
}

@Test func countByKindUnionPinnedOnlyResolvesByWinnerNotByStaleMirrorRow() throws {
    // 关键不变量：pinnedOnly 必须在跨表 dedupe **之后**按 winner 行的 pinned 字段过滤。
    // 模拟：own 上 pin 取消（pinned=false 新行），mirror 上仍 pinned=true（旧行还没同步）。
    // winner = own 那份 pinned=false → pinnedOnly=true 时该 id 不进 pinned 桶。
    // 同时再来一行 own pinned=true 当对照，确保 pinned 桶不空。
    let db = try makeDB()
    try insertOwn(db, id: "x", capturedAtNs: 1000, kind: .text, text: "unpinned now", pinned: false)
    try insertMirror(db, id: "x", origin: "primary", capturedAtNs: 100, kind: .text, text: "stale pin", pinned: true)
    try insertOwn(db, id: "really-pinned", capturedAtNs: 500, kind: .image, pinned: true)
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery(pinnedOnly: true))
    #expect(counts[.text] == nil)  // x 的 winner 是 unpinned，不算
    #expect(counts[.image] == 1)
}

@Test func countByKindUnionPinnedOnlyCountsWinnerPinned() throws {
    // 对称 case：own pinned=false 旧行 + mirror pinned=true 新行 → winner 是 mirror（capturedAtNs 大）
    // → pinned 桶应该算上这一份
    let db = try makeDB()
    try insertOwn(db, id: "y", capturedAtNs: 100, kind: .url, text: "old unpinned", pinned: false)
    try insertMirror(db, id: "y", origin: "primary", capturedAtNs: 1000, kind: .url, text: "new pinned", pinned: true)
    let counts = try SearchAPI(database: db).countByKindUnion(SearchQuery(pinnedOnly: true))
    #expect(counts[.url] == 1)
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

// MARK: - codex review P1 #1: searchUnion / countUnion / countByKindUnion 在 kind 分歧时口径一致

@Test func searchUnionKindFilterRespectsWinnerNotStaleMirrorRow() throws {
    // 跨表 kind 分歧：own.text 新（winner）+ mirror.image 旧。
    // chip count 显示 "image 0"——要保证点 image chip 之后 searchUnion(kinds:[.image]) 也是 0 行，
    // 否则 list 出来一条 mirror.image 跟 chip 数字矛盾。
    let db = try makeDB()
    try insertOwn(db, id: "x", capturedAtNs: 200, kind: .text, text: "winner text")
    try insertMirror(db, id: "x", origin: "primary", capturedAtNs: 100, kind: .image)
    let api = SearchAPI(database: db)

    let imageHits = try api.searchUnion(SearchQuery(kinds: [.image], limit: 10))
    #expect(imageHits.isEmpty)

    let textHits = try api.searchUnion(SearchQuery(kinds: [.text], limit: 10))
    #expect(textHits.map(\.0.id) == ["x"])
    #expect(textHits.first?.0.kind == .text)
}

@Test func searchUnionKindFilterMatchesWinnerInMatchingKind() throws {
    // 对称 case：mirror.image 新（winner）+ own.text 旧，q.kinds=[.image] 应返回 winner mirror 行。
    let db = try makeDB()
    try insertOwn(db, id: "y", capturedAtNs: 100, kind: .text, text: "stale text")
    try insertMirror(db, id: "y", origin: "primary", capturedAtNs: 1000, kind: .image, text: "newer image")
    let api = SearchAPI(database: db)

    let imageHits = try api.searchUnion(SearchQuery(kinds: [.image], limit: 10))
    #expect(imageHits.map(\.0.id) == ["y"])
    #expect(imageHits.first?.0.kind == .image)

    let textHits = try api.searchUnion(SearchQuery(kinds: [.text], limit: 10))
    #expect(textHits.isEmpty)
}

@Test func unionThreePathsAgreeUnderKindDivergence() throws {
    // 钉死不变量：searchUnion / countUnion / countByKindUnion 三条路径在跨表 kind 分歧时
    // 必须算出口径一致的值——chip 数字、total count、点击 chip 后 list 长度互相 agree。
    let db = try makeDB()
    // 分歧行：own.text 新 winner / mirror.image 旧
    try insertOwn(db, id: "div", capturedAtNs: 1000, kind: .text, text: "div text")
    try insertMirror(db, id: "div", origin: "primary", capturedAtNs: 100, kind: .image)
    // 另外一条单纯 image 行做对照
    try insertOwn(db, id: "lone-image", capturedAtNs: 500, kind: .image, text: "lone")
    let api = SearchAPI(database: db)

    // chip 数字：image 桶应只算 lone-image，div 落 text 桶
    let counts = try api.countByKindUnion(SearchQuery())
    #expect(counts[.text] == 1)
    #expect(counts[.image] == 1)

    // 点 image chip → countUnion + searchUnion 同时只数 lone-image
    let imageQuery = SearchQuery(kinds: [.image])
    #expect(try api.countUnion(imageQuery) == counts[.image])
    let imageHits = try api.searchUnion(SearchQuery(kinds: [.image], limit: 10))
    #expect(imageHits.map(\.0.id) == ["lone-image"])

    // 点 text chip → countUnion + searchUnion 同时只数 div（winner）
    let textQuery = SearchQuery(kinds: [.text])
    #expect(try api.countUnion(textQuery) == counts[.text])
    let textHits = try api.searchUnion(SearchQuery(kinds: [.text], limit: 10))
    #expect(textHits.map(\.0.id) == ["div"])
}

@Test func countUnionRespectsWinnerKindFilterAcrossDivergence() throws {
    // countUnion 单独锁死：跟 fetchUnion 一样必须按 winner.kind 过滤，
    // 不能把 mirror 那行的 image 算到 image 桶里——否则跟 chip count 算出来的 image=0 矛盾。
    let db = try makeDB()
    try insertOwn(db, id: "z", capturedAtNs: 800, kind: .text, text: "z text")
    try insertMirror(db, id: "z", origin: "primary", capturedAtNs: 200, kind: .image)
    let api = SearchAPI(database: db)

    #expect(try api.countUnion(SearchQuery(kinds: [.image])) == 0)
    #expect(try api.countUnion(SearchQuery(kinds: [.text])) == 1)
}

@Test func unionPinnedOnlyAndKindsCombinedFilterAgreesAcrossThreePaths() throws {
    // codex review round 2 Nit：pinnedOnly + kinds 同时过滤的组合 case，
    // 钉死三条路径（list / countUnion / countByKindUnion）一致。
    // 跨表分歧场景：winner unpinned 但 loser 在 mirror 里 pinned=true。
    // 三路必须按 winner.pinned 判断，跳过这一行；不能让 mirror pinned=true 的旧行混进 pinned 桶。
    let db = try makeDB()
    // 分歧 row：own winner unpinned + mirror loser pinned —— 这条不该进 pinnedOnly 结果
    try insertOwn(db, id: "div", capturedAtNs: 1000, kind: .text, text: "winner unpinned", pinned: false)
    try insertMirror(db, id: "div", origin: "primary", capturedAtNs: 100, kind: .text, text: "stale pinned", pinned: true)
    // 真 pinned 对照 row：should pass both kinds=[.text] and pinnedOnly
    try insertOwn(db, id: "really-pinned", capturedAtNs: 500, kind: .text, text: "really pinned", pinned: true)
    // 噪声：pinned 但 kind 不匹配 —— 应被 kinds=[.text] 过滤掉
    try insertOwn(db, id: "img-pin", capturedAtNs: 700, kind: .image, pinned: true)
    let api = SearchAPI(database: db)

    let q = SearchQuery(kinds: [.text], pinnedOnly: true, limit: 10)
    let hits = try api.searchUnion(q)
    #expect(hits.map(\.0.id) == ["really-pinned"])
    #expect(try api.countUnion(q) == 1)

    // countByKindUnion **忽略** q.kinds（stripKinds），但 pinnedOnly 仍生效。
    // div 行 winner unpinned → 不进 pinned 桶；really-pinned 进 text；img-pin 进 image。
    let counts = try api.countByKindUnion(SearchQuery(pinnedOnly: true))
    #expect(counts[.text] == 1)
    #expect(counts[.image] == 1)
}

// MARK: - codex review round 1 P1 #2: fetchHitsMirror 必须把 ocr_state 透传

@Test func unionMirrorPropagatesOcrStateToItem() throws {
    // mirror 行 ocr_state='done' 经过 fetchHitsMirror → searchUnion 后 Item.ocrState 必须保留，
    // 否则 OCR worker 没法分流"已扫过"的 mirror 行 + UI 展示状态信息丢失
    let db = try makeDB()
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item_mirror (
                id, origin_device, captured_at_ns, ingested_at_ns, kind,
                source_app, source_app_name, preview, text_full,
                blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
                mirrored_at_ns, ocr_state
            ) VALUES (
                'mir-img', 'primary', 200, 200, 'image',
                NULL, 'Mirror App', 'pic', 'pic',
                NULL, NULL, NULL, 0, NULL,
                200, 'done'
            )
        """)
    }
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    let mirror = hits.first { $0.0.id == "mir-img" }
    #expect(mirror?.0.ocrState == .done)
}

@Test func countUnionTieBreaksOwnOverMirrorOnSameTimestamp() throws {
    // captured_at_ns 相等时跟 fetchUnion 同源（own=0/_src ASC 赢），不会出现非确定 winner。
    // own.text 跟 mirror.image 同时间戳 → winner=own.text → image 桶 0 / text 桶 1。
    let db = try makeDB()
    try insertOwn(db, id: "tie", capturedAtNs: 500, kind: .text, text: "tied own")
    try insertMirror(db, id: "tie", origin: "primary", capturedAtNs: 500, kind: .image, text: "tied mirror")
    let api = SearchAPI(database: db)

    #expect(try api.countUnion(SearchQuery(kinds: [.image])) == 0)
    #expect(try api.countUnion(SearchQuery(kinds: [.text])) == 1)
    let hits = try api.searchUnion(SearchQuery(limit: 10))
    #expect(hits.first?.0.kind == .text)  // own 赢
}

// MARK: - 文本永久 dedup（跨表/跨设备 fold）

/// Image 行带 blob_sha256 的 mirror 写入助手——验证 fold 跳过 blob kind 用。
private func insertMirrorImage(
    _ db: DuoDB,
    id: String,
    origin: String,
    capturedAtNs: Int64,
    blobSha256: String,
    fileName: String
) throws {
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item_mirror (
                id, origin_device, captured_at_ns, ingested_at_ns, kind,
                source_app, source_app_name, preview, text_full,
                blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, mirrored_at_ns
            ) VALUES (?, ?, ?, ?, 'image', NULL, NULL, ?, ?, ?, ?, ?, 0, NULL, ?)
        """, arguments: [
            id, origin, capturedAtNs, capturedAtNs,
            fileName, fileName, blobSha256, 100, "image/png", capturedAtNs
        ])
    }
}

private func insertOwnImage(
    _ db: DuoDB,
    id: String,
    capturedAtNs: Int64,
    blobSha256: String,
    fileName: String
) throws {
    let it = Item(
        id: id,
        originDevice: "self",
        capturedAtNs: capturedAtNs,
        kind: .image,
        preview: fileName,
        textFull: fileName,
        blobSha256: blobSha256,
        blobSize: 100,
        blobMime: "image/png",
        pushState: .acked
    )
    try db.pool.write { conn in try it.insert(conn) }
}

@Test func unionFoldsSameTextAcrossOwnAndMirror() throws {
    // 截图场景：MBP own 行（自家 watcher 抓到）+ mini mirror 行（远端推过来）同文本。
    // searchUnion 应只出 1 条，winner = 较新 capturedAtNs。
    let db = try makeDB()
    try insertMirror(db, id: "mini-row", origin: "mini", capturedAtNs: 100, text: "cat ./snippets/x")
    try insertOwn(db, id: "mbp-row", capturedAtNs: 200, text: "cat ./snippets/x")
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.count == 1)
    #expect(hits.first?.0.id == "mbp-row")  // 较新者赢
    #expect(hits.first?.0.capturedAtNs == 200)
}

@Test func unionFoldPreservesPinnedViaOR() throws {
    // pinned 通过 OR 聚合——mirror 那条 pinned=true / own 那条新 unpinned，
    // fold 结果保留 pinned=true（pin 是对内容的属性而非具体 row）。
    let db = try makeDB()
    try insertMirror(db, id: "old", origin: "mini", capturedAtNs: 100, text: "snippet", pinned: true)
    try insertOwn(db, id: "new", capturedAtNs: 200, text: "snippet", pinned: false)
    // 另插一条 distinct 行验证排序（pinned 应排首位）
    try insertOwn(db, id: "other", capturedAtNs: 500, text: "unrelated", pinned: false)
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.count == 2)
    #expect(hits.first?.0.textFull == "snippet")  // fold 后 pinned 排前
    #expect(hits.first?.0.pinned == true)
    #expect(hits.first?.0.capturedAtNs == 200)    // 来自较新那条
}

@Test func unionDoesNotFoldBlobsBySameSha() throws {
    // 同 sha 图片不参与 text fold——blob_sha256 非 nil 走非文本分支。
    // 用户在 mini 跟 MBP 各贴一次同图，时间线上保留两条（跟当前行为一致）。
    let db = try makeDB()
    let sha = String(repeating: "a", count: 64)
    try insertMirrorImage(db, id: "mini-img", origin: "mini", capturedAtNs: 100, blobSha256: sha, fileName: "shot.png")
    try insertOwnImage(db, id: "mbp-img", capturedAtNs: 200, blobSha256: sha, fileName: "shot.png")
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.count == 2)
    #expect(Set(hits.map(\.0.id)) == ["mini-img", "mbp-img"])
}

@Test func unionFoldRespectsKindFilter() throws {
    // fold 后 winner 是 text kind，q.kinds=[.image] 应过滤掉这条 fold 结果。
    let db = try makeDB()
    try insertMirror(db, id: "txt-mirror", origin: "mini", capturedAtNs: 100, kind: .text, text: "shared")
    try insertOwn(db, id: "txt-own", capturedAtNs: 200, kind: .text, text: "shared")
    let sha = String(repeating: "b", count: 64)
    try insertOwnImage(db, id: "img", capturedAtNs: 300, blobSha256: sha, fileName: "x.png")
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(kinds: [.image], limit: 10))
    #expect(hits.map(\.0.id) == ["img"])  // text fold 结果被 kind filter 过滤
}

@Test func unionFoldCountAndListConsistent() throws {
    // 不变量：fetchUnion / countUnion / countByKindUnion 三条路径口径必须一致。
    // 否则 chip "文本 3" 但 list 出 2 条（fold 没在 count 端应用）。
    let db = try makeDB()
    try insertMirror(db, id: "a-mir", origin: "mini", capturedAtNs: 100, text: "same A")
    try insertOwn(db, id: "a-own", capturedAtNs: 200, text: "same A")
    try insertOwn(db, id: "b", capturedAtNs: 300, text: "distinct B")
    let api = SearchAPI(database: db)
    let listed = try api.searchUnion(SearchQuery(limit: 100))
    let totalCount = try api.countUnion(SearchQuery())
    let kindCount = try api.countByKindUnion(SearchQuery())
    #expect(listed.count == 2)
    #expect(totalCount == 2)
    #expect(kindCount[.text] == 2)
}

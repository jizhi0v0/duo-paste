import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

/// `foldPosition` 是"从搜索结果跳回完整列表"的地基:知道位次才能只拉目标前后一小段,
/// 而不是把整库拉出来(本机实测 22,523 条 fold 行全拉一次 717ms,200 条只要 7.9ms)。
///
/// 位次的定义必须逐字对应 `fetchProjectionHits` 的
/// `ORDER BY f.pinned DESC, f.captured_at_ns DESC, f.item_id ASC` —— 差一位窗口就偏。
private typealias PositionDB = DuoPasteCore.Database

private func makePositionDB() throws -> PositionDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-fold-position-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try PositionDB(path: paths.mainDB)
}

private func positionItem(
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

private func insert(_ items: [Item], into database: PositionDB) throws {
    try database.pool.write { db in
        for item in items { try item.insert(db) }
    }
}

@Test("位次跟空查询列表的实际下标一致")
func foldPositionMatchesListIndex() throws {
    let database = try makePositionDB()
    // captured 递减 → 列表顺序就是 item-0, item-1, ... item-49
    let items = (0..<50).map {
        positionItem(id: "item-\($0)", captured: Int64(10_000 - $0), text: "text-\($0)")
    }
    try insert(items, into: database)
    let api = SearchAPI(database: database)

    let all = try api.searchHits(SearchQuery(limit: Int.max)).map(\.0.id)
    for probe in ["item-0", "item-7", "item-49"] {
        let pos = try #require(try api.foldPosition(ofItemID: probe, query: SearchQuery()))
        #expect(pos.displayItemID == probe)
        #expect(pos.rank == all.firstIndex(of: probe), "位次跟列表下标对不上: \(probe)")
    }
}

@Test("pinned 排在最前,位次要跟着走")
func foldPositionRespectsPinnedFirst() throws {
    let database = try makePositionDB()
    try insert([
        positionItem(id: "new", captured: 300, text: "new"),
        positionItem(id: "mid", captured: 200, text: "mid"),
        positionItem(id: "old-pinned", captured: 100, text: "old", pinned: true),
    ], into: database)
    let api = SearchAPI(database: database)

    let all = try api.searchHits(SearchQuery(limit: Int.max)).map(\.0.id)
    #expect(all == ["old-pinned", "new", "mid"])
    let pos = try #require(try api.foldPosition(ofItemID: "old-pinned", query: SearchQuery()))
    #expect(pos.rank == 0)
}

/// 用户右键的那条未必是 fold 展示行——跨 origin 同 text 会被折叠,展示行是最新那条。
/// 定位必须落到展示行上,否则列表里根本没有这个 id,卡片选不中。
@Test("被折叠掉的条目定位到它所在组的展示行")
func foldPositionMapsFoldedRowToDisplayRow() throws {
    let database = try makePositionDB()
    try insert([
        positionItem(id: "newer", captured: 500, text: "same text"),
        positionItem(id: "peer-copy", origin: "peer", captured: 400, text: "same text"),
        positionItem(id: "other", captured: 300, text: "other"),
    ], into: database)
    let api = SearchAPI(database: database)

    let all = try api.searchHits(SearchQuery(limit: Int.max)).map(\.0.id)
    #expect(all == ["newer", "other"], "跨 origin 同 text 应该折成一条")

    let pos = try #require(try api.foldPosition(ofItemID: "peer-copy", query: SearchQuery()))
    #expect(pos.displayItemID == "newer")
    #expect(pos.rank == 0)
}

@Test("chip 过滤下位次按过滤后的列表算")
func foldPositionRespectsQualifier() throws {
    let database = try makePositionDB()
    let sha = String(repeating: "b", count: 64)
    try insert([
        positionItem(id: "t1", captured: 500, text: "a"),
        positionItem(id: "img", captured: 400, kind: .image, sha: sha, mime: "image/png"),
        positionItem(id: "t2", captured: 300, text: "b"),
    ], into: database)
    let api = SearchAPI(database: database)

    let textOnly = SearchQuery(kinds: [.text])
    let pos = try #require(try api.foldPosition(ofItemID: "t2", query: textOnly))
    #expect(pos.rank == 1, "只看文本时 t2 是第 2 条,不是全局第 3 条")

    // 被 chip 滤掉的条目没有位次 —— 调用方据此退化成"不在列表里"的提示
    #expect(try api.foldPosition(ofItemID: "img", query: textOnly) == nil)
}

/// FTS / 自定义时间范围路径的 offset 是 Swift 端切数组,要先构造全集才能分页,
/// 拿 rank 反而更贵。这条路径必须返回 nil 让调用方降级,不能假装支持。
@Test("非 projection 路径不返回位次")
func foldPositionReturnsNilOutsideProjectionPath() throws {
    let database = try makePositionDB()
    try insert([positionItem(id: "only", captured: 100, text: "hello")], into: database)
    let api = SearchAPI(database: database)

    #expect(try api.foldPosition(ofItemID: "only", query: SearchQuery(text: "hello")) == nil)
    #expect(try api.foldPosition(ofItemID: "only", query: SearchQuery(fromNs: 1)) == nil)
    #expect(try api.foldPosition(ofItemID: "missing", query: SearchQuery()) == nil)
}

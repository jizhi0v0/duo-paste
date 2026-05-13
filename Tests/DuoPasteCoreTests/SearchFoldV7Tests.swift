import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

/// v7 合表后 `item_mirror` 已 DROP，peer 行通过 PullWorker 直接落 `item` 表（push_state='acked'，
/// origin_device 区分本机 vs peer）。原 SearchUnionTests 走"跨表 union + Swift fold"假设失效，
/// 但 `searchUnion` 接口保留（PR 6 才清 SearchProvider.Mode 枚举），内部退化为"单表 fetchHits
/// oversample + Swift 端 text-fold + 后置过滤 + 排序"。
///
/// 本套覆盖 v7 单表语义下的 fold 不变量，保证 SearchProvider.localMirror 路径行为跟合表前一致：
/// - 跨 origin 同 text_full 在单表内 fold 为一条（winner = max(capturedAtNs)，pinned OR 聚合）
/// - 同 blob_sha256 不 fold（保留时间线，blob kind 独立）
/// - kinds / pinnedOnly filter 应用到 winner 行（不前置到子查询）
/// - fetchUnion / countUnion / countByKindUnion 三路口径一致
///
/// 老 SearchUnionTests 在 PR 1 期间整体挂（写 item_mirror 表挂掉）；PR 4 才删，是 plan 字面接受。

private typealias DuoDB = DuoPasteCore.Database

private func makeDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-foldv7-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB, role: .client)
}

/// 直接 INSERT 到 item 表，模拟 own 行（origin=self）或 peer 行（origin!=self，PullWorker 路径
/// 写入的 push_state='acked'）。capturedAtNs 直接复用为 ingestedAtNs，便于测试断言可预期顺序。
private func insertItem(
    _ db: DuoDB,
    id: String,
    origin: String,
    capturedAtNs: Int64,
    kind: ItemKind = .text,
    text: String? = nil,
    blobSha256: String? = nil,
    pinned: Bool = false,
    deletedAtNs: Int64? = nil
) throws {
    let it = Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedAtNs,
        ingestedAtNs: capturedAtNs,
        kind: kind,
        sourceAppName: origin == "self" ? "Own App" : "Peer App",
        preview: text,
        textFull: text,
        blobSha256: blobSha256,
        pinned: pinned,
        deletedAtNs: deletedAtNs,
        pushState: .acked
    )
    try db.pool.write { conn in try it.insert(conn) }
}

@Test func foldSameTextAcrossOwnAndPeerInSingleTable() throws {
    // 本机 own + peer mirror 同 text_full：合表后两行都落 item 表，单表 fold 应只剩 winner=newest 那条
    let db = try makeDB()
    try insertItem(db, id: "own-old", origin: "self", capturedAtNs: 100, text: "duplicate text")
    try insertItem(db, id: "peer-new", origin: "peer", capturedAtNs: 500, text: "duplicate text")
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.count == 1)
    #expect(hits.first?.0.id == "peer-new")
}

@Test func foldPreservesPinnedViaORInSingleTable() throws {
    // 任一行 pinned=true → fold winner 继承 pinned=true（pin 是对内容的属性而非具体 row）
    let db = try makeDB()
    try insertItem(db, id: "own-pinned", origin: "self", capturedAtNs: 100, text: "shared", pinned: true)
    try insertItem(db, id: "peer-unpinned-newer", origin: "peer", capturedAtNs: 500, text: "shared", pinned: false)
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.count == 1)
    #expect(hits.first?.0.id == "peer-unpinned-newer")
    #expect(hits.first?.0.pinned == true)
}

@Test func foldDoesNotFoldBlobsBySameShaInSingleTable() throws {
    // 同 sha 图片多次复制可能是用户故意保留时间线 → 不 fold（仅 blob_sha256 IS NULL 行参与 fold）
    let db = try makeDB()
    let sha = String(repeating: "a", count: 64)
    try insertItem(db, id: "own-img", origin: "self", capturedAtNs: 100, kind: .image, blobSha256: sha)
    try insertItem(db, id: "peer-img", origin: "peer", capturedAtNs: 500, kind: .image, blobSha256: sha)
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.count == 2)
    #expect(Set(hits.map(\.0.id)) == ["own-img", "peer-img"])
}

@Test func foldRespectsKindFilter() throws {
    // kinds filter 应用到 winner 行（fold 后），跟 fetchUnion 的"后置 filter 不变量"对齐
    let db = try makeDB()
    try insertItem(db, id: "txt-old", origin: "self", capturedAtNs: 100, kind: .text, text: "hello")
    try insertItem(db, id: "txt-new", origin: "peer", capturedAtNs: 500, kind: .text, text: "hello")
    try insertItem(db, id: "url-row", origin: "self", capturedAtNs: 200, kind: .url, text: "https://example.com")
    let api = SearchAPI(database: db)

    // 单选 text：fold 后 winner=txt-new，url-row 不进结果
    let textHits = try api.searchUnion(SearchQuery(kinds: [.text], limit: 10))
    #expect(textHits.map(\.0.id) == ["txt-new"])

    // 单选 url：只有 url-row
    let urlHits = try api.searchUnion(SearchQuery(kinds: [.url], limit: 10))
    #expect(urlHits.map(\.0.id) == ["url-row"])

    // 全 kinds（默认）：fold 后两条（text fold 一条 + url 一条），按 captured DESC 排
    let allHits = try api.searchUnion(SearchQuery(limit: 10))
    #expect(allHits.map(\.0.id) == ["txt-new", "url-row"])
}

@Test func foldCountAndListConsistent() throws {
    // 三路口径：searchUnion list, countUnion total, countByKindUnion chip —— 都基于同一 fetchUnion
    // oversample → fold 路径计算。fold 后 4 个原始行 → 3 个 winner（text 'A' fold + text 'B' + url）
    let db = try makeDB()
    try insertItem(db, id: "txt-a-old", origin: "self", capturedAtNs: 100, kind: .text, text: "A")
    try insertItem(db, id: "txt-a-new", origin: "peer", capturedAtNs: 500, kind: .text, text: "A")
    try insertItem(db, id: "txt-b", origin: "self", capturedAtNs: 300, kind: .text, text: "B")
    try insertItem(db, id: "url-only", origin: "self", capturedAtNs: 200, kind: .url, text: "https://example.com")
    let api = SearchAPI(database: db)

    let list = try api.searchUnion(SearchQuery(limit: 50))
    let total = try api.countUnion(SearchQuery())
    let byKind = try api.countByKindUnion(SearchQuery())

    #expect(list.count == 3)
    #expect(total == 3)
    #expect(byKind[.text] == 2)  // 'A' fold 一条 + 'B' 一条
    #expect(byKind[.url] == 1)
    // 其它 kind 走 normalizeKindCounts 应该补 0（这里 SearchAPI.countByKindUnion 不补，由
    // SearchProvider.normalizeKindCounts 兜底；这里直接断言原始字典只含命中 kind）
    #expect(byKind[.image] == nil)
}

@Test func foldPinnedOnlyAppliesAfterFoldWinner() throws {
    // pinnedOnly filter 应用到 winner 行：own-pinned + peer-unpinned-newer 同文本 → fold winner
    // 是 peer-unpinned-newer 但 pinned 通过 OR 聚合后 winner.pinned=true → pinnedOnly=true 应包含它
    let db = try makeDB()
    try insertItem(db, id: "own-pinned", origin: "self", capturedAtNs: 100, text: "shared", pinned: true)
    try insertItem(db, id: "peer-newer-unpinned", origin: "peer", capturedAtNs: 500, text: "shared", pinned: false)
    try insertItem(db, id: "lone-unpinned", origin: "self", capturedAtNs: 300, text: "other", pinned: false)
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(pinnedOnly: true, limit: 10))
    #expect(hits.count == 1)
    #expect(hits.first?.0.id == "peer-newer-unpinned")
}

@Test func foldSoftDeletedExcludedByDefault() throws {
    // deletedAtNs 非空的行默认不进结果（includeDeleted=false）；fold 不让 tombstone 顶 active 行
    let db = try makeDB()
    try insertItem(db, id: "active", origin: "self", capturedAtNs: 100, text: "live")
    try insertItem(db, id: "deleted", origin: "peer", capturedAtNs: 500, text: "live", deletedAtNs: 600)
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(limit: 10))
    #expect(hits.count == 1)
    #expect(hits.first?.0.id == "active")
}

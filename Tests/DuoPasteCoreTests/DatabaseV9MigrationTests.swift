import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

/// v9 migration 端到端 schema 验证。
///
/// 不模拟"v8 → v9 升级"的数据搬迁路径(GRDB DatabaseMigrator 没有部分回滚 API,搭测试
/// 鹰架成本高于收益)——数据搬迁 SQL 简单直观,review + install-agent 后 sqlite3 直查
/// 验证。这里只钉死**v9 之后**的 schema 状态:
///   1. item 表有 extracted_text + extracted_text_source 列
///   2. item_fts 虚表索引列包含 extracted_text(查 master 表 sql 字符串确认)
///   3. INSERT 一条 extractedText 非空的 item → FTS5 trigger 自动索引 → MATCH 命中
private func makeDB() throws -> DuoPasteCore.Database {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-v9-mig-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoPasteCore.Database(path: paths.mainDB)
}

@Test func v9ItemTableHasExtractedTextColumns() async throws {
    let db = try makeDB()
    let columns = try await db.pool.read { conn -> [String] in
        try Row.fetchAll(conn, sql: "PRAGMA table_info(item)").map {
            ($0["name"] as String?) ?? ""
        }
    }
    #expect(columns.contains("extracted_text"))
    #expect(columns.contains("extracted_text_source"))
    // text_full 还在(v9 不删原列,只是清 image kind 的值)
    #expect(columns.contains("text_full"))
}

@Test func v9ItemFTSIndexesExtractedText() async throws {
    let db = try makeDB()
    // sqlite_master.sql 字符串里查 item_fts 定义,确认 extracted_text 在列签名里
    let ftsSql = try await db.pool.read { conn -> String in
        try String.fetchOne(conn, sql: """
            SELECT sql FROM sqlite_master
            WHERE type='table' AND name='item_fts'
        """) ?? ""
    }
    #expect(ftsSql.contains("extracted_text"))
}

@Test func v9FTSTriggerIndexesExtractedTextOnInsert() async throws {
    // INSERT 一条 extractedText 非空的 item → item_ai trigger 自动 INSERT 进 item_fts →
    // MATCH 应命中。证明 v9 重建后的 trigger 把 extracted_text 也喂给了 FTS5
    let db = try makeDB()
    let it = Item(
        id: "v9-fts-1",
        originDevice: "dev",
        capturedAtNs: 1_700_000_000_000_000_000,
        ingestedAtNs: 1_700_000_000_000_000_000,
        kind: .image,
        preview: "[image 10KB]",
        textFull: nil,    // image kind 永远 nil(v9 契约)
        blobSha256: "deadbeef" + String(repeating: "0", count: 56),
        blobMime: "image/png",
        ocrState: .done,
        extractedText: "唯一可搜词 unique-needle-xyz",
        extractedTextSource: .ocr
    )
    try await db.pool.write { try it.insert($0) }

    let api = SearchAPI(database: db)
    let hits = try api.searchHits(SearchQuery(text: "unique-needle-xyz"))
    #expect(hits.count == 1)
    #expect(hits.first?.0.id == "v9-fts-1")
    #expect(hits.first?.0.extractedText == "唯一可搜词 unique-needle-xyz")
    #expect(hits.first?.0.extractedTextSource == .ocr)
    #expect(hits.first?.0.textFull == nil)        // image kind text_full 永远 nil

    // 中文 token 也应命中(unicode61 + remove_diacritics 2)
    let zhHits = try api.searchHits(SearchQuery(text: "唯一"))
    #expect(zhHits.count == 1)
}

@Test func v9FTSTriggerReindexesExtractedTextOnUpdate() async throws {
    // OCR markDone 通过 UPDATE 写 extracted_text。item_au trigger 必须 delete 旧 FTS
    // 索引 + insert 新——否则 OCR 完成后搜不到。这条钉死 trigger UPDATE 分支
    let db = try makeDB()
    let priorItem = Item(
        id: "v9-update-1",
        originDevice: "dev",
        capturedAtNs: 1_700_000_000_000_000_000,
        ingestedAtNs: 1_700_000_000_000_000_000,
        kind: .image,
        preview: "[image 10KB]",
        blobSha256: "cafebabe" + String(repeating: "0", count: 56),
        blobMime: "image/png",
        ocrState: .pending
        // extractedText 暂为 nil
    )
    try await db.pool.write { try priorItem.insert($0) }

    // 搜 OCR text → 不命中(还没 OCR)
    let api = SearchAPI(database: db)
    #expect(try api.searchHits(SearchQuery(text: "fresh-needle-abc")).isEmpty)

    // 模拟 OCR markDone 的 UPDATE
    try await db.pool.write { conn in
        try conn.execute(sql: """
            UPDATE item SET extracted_text = ?, extracted_text_source = 'ocr', ocr_state = 'done'
            WHERE id = ?
        """, arguments: ["搜词 fresh-needle-abc", "v9-update-1"])
    }

    // FTS5 trigger 应该重新索引 → 现在能命中
    let hits = try api.searchHits(SearchQuery(text: "fresh-needle-abc"))
    #expect(hits.count == 1)
    #expect(hits.first?.0.id == "v9-update-1")
}

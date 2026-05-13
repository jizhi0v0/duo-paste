import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private func tempDBPath() -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-mig6-\(UUID().uuidString).sqlite")
    return url.path
}

/// 跑到 v5_primary_lineage 停下，让测试可以在 v6 之前手动插入"老数据"模拟历史状态。
/// 一旦 v6 跑完，验证 backfill 行为
private func openAtV5() throws -> DatabasePool {
    let path = tempDBPath()
    let pool = try DatabasePool(path: path)
    try Database.migrator.migrate(pool, upTo: "v5_primary_lineage")
    return pool
}

@Test func v6AddsOcrStateColumnToItem() async throws {
    let path = tempDBPath()
    let pool = try DatabasePool(path: path)
    try Database.migrator.migrate(pool)
    let cols = try await pool.read { db -> [String] in
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(item)")
        return rows.map { ($0["name"] as String?) ?? "" }
    }
    #expect(cols.contains("ocr_state"))
}

@Test func v6AddsOcrStateColumnToItemMirror() async throws {
    let path = tempDBPath()
    let pool = try DatabasePool(path: path)
    try Database.migrator.migrate(pool)
    let cols = try await pool.read { db -> [String] in
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(item_mirror)")
        return rows.map { ($0["name"] as String?) ?? "" }
    }
    #expect(cols.contains("ocr_state"))
}

@Test func v6BackfillsImageRowsToPending() async throws {
    let pool = try openAtV5()
    try await pool.write { db in
        try db.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, kind)
            VALUES
                ('img-old', 'dev', 1, 'image'),
                ('txt-old', 'dev', 2, 'text'),
                ('file-old', 'dev', 3, 'file')
        """)
        try db.execute(sql: """
            INSERT INTO item_mirror (id, origin_device, captured_at_ns, kind, mirrored_at_ns)
            VALUES
                ('img-mirror', 'dev2', 10, 'image', 100),
                ('txt-mirror', 'dev2', 11, 'text', 100)
        """)
    }
    try Database.migrator.migrate(pool)

    try await pool.read { db in
        let imgItem = try String.fetchOne(db, sql: "SELECT ocr_state FROM item WHERE id='img-old'")
        #expect(imgItem == "pending")
        let txtItem = try String.fetchOne(db, sql: "SELECT ocr_state FROM item WHERE id='txt-old'")
        #expect(txtItem == nil)
        let fileItem = try String.fetchOne(db, sql: "SELECT ocr_state FROM item WHERE id='file-old'")
        #expect(fileItem == nil)
        let imgMirror = try String.fetchOne(db, sql: "SELECT ocr_state FROM item_mirror WHERE id='img-mirror'")
        #expect(imgMirror == "pending")
        let txtMirror = try String.fetchOne(db, sql: "SELECT ocr_state FROM item_mirror WHERE id='txt-mirror'")
        #expect(txtMirror == nil)
    }
}

@Test func v6BackfillsHttpTextRowsToUrlKind() async throws {
    let pool = try openAtV5()
    try await pool.write { db in
        try db.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, kind, text_full)
            VALUES
                ('url-http',    'dev', 1, 'text', 'http://example.com'),
                ('url-https',   'dev', 2, 'text', 'https://github.com/owner/repo'),
                ('url-trail',   'dev', 3, 'text', 'https://example.com/path?q=1'),
                ('plain-bare',  'dev', 4, 'text', 'github.com'),
                ('plain-text',  'dev', 5, 'text', 'just plain text'),
                ('multi-line',  'dev', 6, 'text', 'https://example.com' || char(10) || '说明'),
                ('with-space',  'dev', 7, 'text', 'https://example.com 描述'),
                ('null-text',   'dev', 8, 'text', NULL),
                ('ftp-text',    'dev', 9, 'text', 'ftp://example.com/file.zip')
        """)
        try db.execute(sql: """
            INSERT INTO item_mirror (id, origin_device, captured_at_ns, kind, mirrored_at_ns, text_full)
            VALUES
                ('m-url',  'dev2', 10, 'text', 100, 'https://docs.example.com'),
                ('m-plain', 'dev2', 11, 'text', 100, 'plain words')
        """)
    }
    try Database.migrator.migrate(pool)

    try await pool.read { db in
        let promoted = try String.fetchSet(db, sql: """
            SELECT id FROM item WHERE kind='url'
        """)
        #expect(promoted == ["url-http", "url-https", "url-trail"])

        let stillText = try String.fetchSet(db, sql: """
            SELECT id FROM item WHERE kind='text'
        """)
        #expect(stillText == ["plain-bare", "plain-text", "multi-line", "with-space", "null-text", "ftp-text"])

        let mirrorPromoted = try String.fetchSet(db, sql: """
            SELECT id FROM item_mirror WHERE kind='url'
        """)
        #expect(mirrorPromoted == ["m-url"])
    }
}

/// codex review round 1 P1 #1：v6 backfill 必须拒收 URL.host=nil 的畸形文本，
/// 跟 capture 路径同源调 looksLikeURL，避免单 SQL GLOB 通得过但启发拒收的 text 行
/// 被永久错升为 url
@Test func v6DoesNotPromoteMalformedURLs() async throws {
    let pool = try openAtV5()
    try await pool.write { db in
        try db.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, kind, text_full)
            VALUES
                ('empty-host',   'dev', 1, 'text', 'https:///path'),
                ('tab-inside',   'dev', 2, 'text', 'https://x.com' || char(9) || 'note'),
                ('bad-host-dot', 'dev', 3, 'text', 'http://example..com/'),
                ('lead-dot',     'dev', 4, 'text', 'http://.com/'),
                ('underscore',   'dev', 5, 'text', 'http://_.com/')
        """)
    }
    try Database.migrator.migrate(pool)
    try await pool.read { db in
        let stillText = try String.fetchSet(db, sql: "SELECT id FROM item WHERE kind='text'")
        #expect(stillText == ["empty-host", "tab-inside", "bad-host-dot", "lead-dot", "underscore"])
    }
}

/// 历史路径 GLOB 不接受前导/尾随空白和大写 scheme；切到 Swift backfill 后应当能修正
@Test func v6PromotesURLsWithLeadingWhitespaceOrUppercaseScheme() async throws {
    let pool = try openAtV5()
    try await pool.write { db in
        try db.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, kind, text_full)
            VALUES
                ('leading-space', 'dev', 1, 'text', '  https://example.com  '),
                ('upper-scheme',  'dev', 2, 'text', 'HTTPS://example.com')
        """)
    }
    try Database.migrator.migrate(pool)
    try await pool.read { db in
        let promoted = try String.fetchSet(db, sql: "SELECT id FROM item WHERE kind='url'")
        #expect(promoted == ["leading-space", "upper-scheme"])
    }
}

@Test func v6DoesNotBumpIngestedAtNsOnBackfill() async throws {
    let pool = try openAtV5()
    try await pool.write { db in
        try db.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, ingested_at_ns, kind, text_full)
            VALUES ('url-x', 'dev', 1, 12345, 'text', 'https://example.com')
        """)
    }
    try Database.migrator.migrate(pool)
    let ingested = try await pool.read { db in
        try Int64.fetchOne(db, sql: "SELECT ingested_at_ns FROM item WHERE id='url-x'")
    }
    #expect(ingested == 12345)
}

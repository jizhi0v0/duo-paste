import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-promote-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 写一份典型 client config 到 path：primary_url=https://primary.example:8443 + pull.enabled=true。
/// 不动 capture / 不设 tls / 不设 keychain，给"字段保留"用例留 override 空间。
private func writeClientConfig(
    to path: URL,
    primaryURL: String = "https://primary.example:8443",
    pullEnabled: Bool = true,
    extraKeys: [String: Any] = [:]
) throws {
    var dict: [String: Any] = [
        "serve": false,
        "primary_url": primaryURL,
        "pull": [
            "enabled": pullEnabled,
            "interval_sec": 30,
            "eager_blobs": false,
        ],
    ]
    for (k, v) in extraKeys { dict[k] = v }
    let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: path, options: [.atomic])
}

private func insertMirrorRow(
    _ conn: GRDB.Database,
    id: String, origin: String, capturedAtNs: Int64,
    kind: String = "text", text: String = "x"
) throws {
    try conn.execute(sql: """
        INSERT INTO item_mirror
          (id, origin_device, captured_at_ns, ingested_at_ns, kind,
           source_app, source_app_name, preview, text_full,
           blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, mirrored_at_ns)
        VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, NULL, NULL, NULL, 0, NULL, ?)
    """, arguments: [id, origin, capturedAtNs, capturedAtNs, kind, text, text, capturedAtNs])
}

// MARK: - Happy path

@Test func promotePullsMirrorIntoItemAndClearsTables() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .client)
    // 准备：自家 own-origin 一条 + mirror 两条 origin=A/B + pull_cursor primary_id=old-primary
    let ownItem = Item(id: "self-1", originDevice: "self-dev", capturedAtNs: 1_000, kind: .text,
                       preview: "own", pushState: .pending)
    try db.pool.write { conn in
        try ownItem.insert(conn)
        try insertMirrorRow(conn, id: "mirror-a", origin: "device-A", capturedAtNs: 2_000, text: "from A")
        try insertMirrorRow(conn, id: "mirror-b", origin: "device-B", capturedAtNs: 3_000, text: "from B")
        try conn.execute(sql: """
            INSERT INTO pull_cursor (primary_id, cursor_ns, cursor_id, updated_at_ns)
            VALUES ('old-primary', 3000, 'mirror-b', 3000)
        """)
    }

    let promoteNow: Int64 = 9_999_999
    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        selfDeviceID: "self-dev",
        now: promoteNow
    )

    #expect(result.promotedRows == 2)
    #expect(result.mirrorClearedRows == 2)
    #expect(result.lineageOldPrimaryID == "old-primary")
    #expect(result.lineageStartedAtNs == promoteNow)
    #expect(result.oldPrimaryURL?.absoluteString == "https://primary.example:8443")

    // 重开 DB（promote 关闭了 pool）读断言
    let after = try Database(path: paths.mainDB, role: .primary)
    let (items, mirrorCount, cursorCount, lineage) = try after.pool.read { conn -> ([Item], Int, Int, [LineageRow]) in
        let items = try Item.order(Column("id")).fetchAll(conn)
        let mc = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item_mirror") ?? -1
        let cc = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM pull_cursor") ?? -1
        let rows = try LineageRow.order(Column("device_id"), Column("started_at_ns"))
            .fetchAll(conn)
        return (items, mc, cc, rows)
    }

    #expect(items.map(\.id) == ["mirror-a", "mirror-b", "self-1"])
    // promote 进来的两条 origin 保留、push_state='acked'
    let promoted = items.filter { $0.id.hasPrefix("mirror-") }
    #expect(promoted.allSatisfy { $0.pushState == .acked })
    #expect(promoted.allSatisfy { $0.pushAttempts == 0 })
    #expect(promoted.allSatisfy { $0.lastPushError == nil })
    #expect(promoted.first { $0.id == "mirror-a" }?.originDevice == "device-A")
    #expect(promoted.first { $0.id == "mirror-b" }?.originDevice == "device-B")
    // 自家原行不动
    let own = items.first { $0.id == "self-1" }!
    #expect(own.pushState == .pending)

    #expect(mirrorCount == 0)
    #expect(cursorCount == 0)

    #expect(lineage.count == 2)
    let oldRow = lineage.first { $0.deviceID == "old-primary" }!
    #expect(oldRow.startedAtNs == 0)
    #expect(oldRow.endedAtNs == promoteNow)
    let selfRow = lineage.first { $0.deviceID == "self-dev" }!
    #expect(selfRow.startedAtNs == promoteNow)
    #expect(selfRow.endedAtNs == nil)

    // config.json 改写正确
    let cfg = try Config.load(from: paths.configFile)
    #expect(cfg.serve == true)
    #expect(cfg.primaryURL == nil)
    #expect(cfg.pull.enabled == false)
    #expect(result.configWrittenTo == paths.configFile)
}

@Test func promoteWithIDConflictSkipsMirrorRow() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .client)
    // 自家 item.id=conflict（origin=self），mirror 也有 id=conflict（origin=A，新内容）
    // INSERT OR IGNORE 应保留自家行，跳过 mirror 那条
    let ownItem = Item(id: "conflict", originDevice: "self-dev", capturedAtNs: 5_000, kind: .text,
                       textFull: "OWN COPY", pushState: .acked)
    try db.pool.write { conn in
        try ownItem.insert(conn)
        try insertMirrorRow(conn, id: "conflict", origin: "device-A",
                            capturedAtNs: 6_000, text: "MIRROR COPY")
        try insertMirrorRow(conn, id: "unique-b", origin: "device-A",
                            capturedAtNs: 7_000, text: "unique")
    }

    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        selfDeviceID: "self-dev",
        now: 12_345
    )
    // 只新插入 1 条（unique-b）；conflict 被 IGNORE
    #expect(result.promotedRows == 1)
    #expect(result.mirrorClearedRows == 2)

    let after = try Database(path: paths.mainDB, role: .primary)
    let conflictRow = try after.pool.read { conn in
        try Item.filter(Column("id") == "conflict").fetchOne(conn)
    }
    #expect(conflictRow?.originDevice == "self-dev")        // 仍是自家行
    #expect(conflictRow?.textFull == "OWN COPY")            // mirror 的 MIRROR COPY 没覆盖
    #expect(conflictRow?.pushState == .acked)               // 自家 push_state 不被改成 'acked'（已是 acked，但语义上没被覆盖）
}

@Test func promoteRefusesStandaloneMode() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    // 不写 config.json → load 返回 .default（standalone：primary_url=nil, serve=false）

    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.promoteToPrimary(
            dbPath: paths.mainDB,
            configPath: paths.configFile,
            selfDeviceID: "self-dev",
            now: 1
        )
    }
}

@Test func promoteRefusesPrimaryMode() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    // 已经是 primary：serve=true, primary_url 缺失
    let dict: [String: Any] = [
        "serve": true,
        "serve_host": "0.0.0.0",
        "serve_port": 8443,
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    try data.write(to: paths.configFile)

    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.promoteToPrimary(
            dbPath: paths.mainDB,
            configPath: paths.configFile,
            selfDeviceID: "self-dev",
            now: 1
        )
    }
}

@Test func promoteWithEmptyPullCursorWritesOnlySelfLineage() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile, pullEnabled: false)  // 还没启用 pull

    let db = try Database(path: paths.mainDB, role: .client)
    // 没 mirror 数据、没 pull_cursor 行
    _ = db

    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        selfDeviceID: "self-dev",
        now: 42
    )
    #expect(result.promotedRows == 0)
    #expect(result.mirrorClearedRows == 0)
    #expect(result.lineageOldPrimaryID == nil)

    let after = try Database(path: paths.mainDB, role: .primary)
    let lineage = try after.pool.read { conn in
        try LineageRow.order(Column("device_id")).fetchAll(conn)
    }
    #expect(lineage.count == 1)
    #expect(lineage[0].deviceID == "self-dev")
    #expect(lineage[0].startedAtNs == 42)
    #expect(lineage[0].endedAtNs == nil)
}

@Test func promoteOverridesServeHostAndPortWhenProvided() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    _ = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        selfDeviceID: "self-dev",
        now: 1,
        serveHost: "0.0.0.0",
        servePort: 9443
    )

    let cfg = try Config.load(from: paths.configFile)
    #expect(cfg.serveHost == "0.0.0.0")
    #expect(cfg.servePort == 9443)
    #expect(cfg.serve == true)
}

@Test func promotePreservesUserConfigFields() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    // 写一个含 capture 自定义值 + shared_secret_keychain_account + 一个未知字段的 config
    try writeClientConfig(to: paths.configFile, extraKeys: [
        "capture": [
            "max_blob_mb": 16,
            "max_text_kb": 900,
            "merge_window_sec": 600,
        ],
        "shared_secret_keychain_account": "duo-paste-secret",
        "x_user_note": "手动加的调试注解",  // 未知字段
    ])

    _ = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        selfDeviceID: "self-dev",
        now: 1
    )

    let cfg = try Config.load(from: paths.configFile)
    #expect(cfg.capture.maxBlobBytes == 16 * 1024 * 1024)
    #expect(cfg.capture.maxTextBytes == 900 * 1024)
    #expect(cfg.capture.mergeWindowSec == 600)
    #expect(cfg.sharedSecretKeychainAccount == "duo-paste-secret")

    // 未知字段也必须保留（Config.write 走 dict round-trip）
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile)) as! [String: Any]
    #expect((raw["x_user_note"] as? String) == "手动加的调试注解")
}

@Test func promoteIgnoresSelfDeviceIDInPullCursor() throws {
    // 边界：pull_cursor.primary_id 恰好等于 selfDeviceID（理论不该发生，但 robust 测一下）
    // 这种情况不应该写"闭老任期"行（避免给同一个 device 写两条互相打架的 lineage）
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .client)
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO pull_cursor (primary_id, cursor_ns, cursor_id, updated_at_ns)
            VALUES ('self-dev', 100, '', 100)
        """)
    }

    _ = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        selfDeviceID: "self-dev",
        now: 200
    )

    let after = try Database(path: paths.mainDB, role: .primary)
    let lineage = try after.pool.read { conn in
        try LineageRow.fetchAll(conn)
    }
    #expect(lineage.count == 1)
    #expect(lineage[0].deviceID == "self-dev")
    #expect(lineage[0].startedAtNs == 200)
    #expect(lineage[0].endedAtNs == nil)
}

// MARK: - Helpers

private struct LineageRow: FetchableRecord, Decodable {
    static let databaseTableName = "primary_lineage"
    let deviceID: String
    let startedAtNs: Int64
    let endedAtNs: Int64?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case startedAtNs = "started_at_ns"
        case endedAtNs = "ended_at_ns"
    }
}

extension LineageRow: TableRecord {}

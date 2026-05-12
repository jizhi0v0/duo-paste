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
        blobs: BlobStore(root: paths.blobsDir),
        selfDeviceID: "self-dev",
        now: promoteNow
    )

    #expect(result.promotedRows == 2)
    #expect(result.mirrorClearedRows == 2)
    // own self-1 ingested_at_ns=nil + 两条 mirror 进来 ingested_at_ns 也 nil（insertMirrorRow
    // 用 capturedAtNs 当 ingested_at_ns，所以非 nil）→ 实际只 self-1 需要 stamp
    #expect(result.stampedRows == 1)
    #expect(result.lineageOldPrimaryID == "old-primary")
    #expect(result.lineageStartedAtNs == promoteNow)
    #expect(result.oldPrimaryURL?.absoluteString == "https://primary.example:8443")
    #expect(result.missingBlobsTotal == 0)
    #expect(result.missingBlobsSamples.isEmpty)

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
    // 自家原行：origin 保留，但 P1 修复会 stamp ingested_at_ns + 强制 push_state='acked'
    // （本机变 primary 后没上游可推，pending 行进入终态）
    let own = items.first { $0.id == "self-1" }!
    #expect(own.originDevice == "self-dev")
    #expect(own.pushState == .acked)
    #expect(own.ingestedAtNs != nil)
    #expect((own.ingestedAtNs ?? 0) >= promoteNow)  // nextIngestNs 保证 >= now

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
    // INSERT OR IGNORE 应保留自家行，跳过 mirror 那条。own 行 ingested_at_ns=8_000 让它
    // 不参与 P1 stamping 路径，便于隔离测试 INSERT OR IGNORE 不变量
    let ownItem = Item(id: "conflict", originDevice: "self-dev", capturedAtNs: 5_000,
                       ingestedAtNs: 8_000, kind: .text,
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
        blobs: BlobStore(root: paths.blobsDir),
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
            blobs: BlobStore(root: paths.blobsDir),
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
            blobs: BlobStore(root: paths.blobsDir),
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
        blobs: BlobStore(root: paths.blobsDir),
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
        blobs: BlobStore(root: paths.blobsDir),
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
        blobs: BlobStore(root: paths.blobsDir),
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
        blobs: BlobStore(root: paths.blobsDir),
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

// MARK: - P1: ingested_at_ns stamping

@Test func promoteStampsOwnOriginNullIngestedNs() throws {
    // 真实 client 路径捕获的 own-origin 行 ingested_at_ns=nil，push_state=pending（acked
    // 后字段仍 nil，因为 client 端从不 stamp）。promote 后必须 stamp 让 /since 能拉走，
    // 同时 push_state 拍 acked 让 own 行进 sync 终态。
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .client)
    let pendingOwn = Item(id: "p1", originDevice: "self-dev", capturedAtNs: 1_000, kind: .text,
                          preview: "p", pushState: .pending)
    let ackedOwn = Item(id: "a1", originDevice: "self-dev", capturedAtNs: 2_000, kind: .text,
                        preview: "a", pushState: .acked, pushAttempts: 1)
    let failedOwn = Item(id: "f1", originDevice: "self-dev", capturedAtNs: 3_000, kind: .text,
                         preview: "f", pushState: .failed, pushAttempts: 50,
                         lastPushError: "connection refused")
    try db.pool.write { conn in
        try pendingOwn.insert(conn)
        try ackedOwn.insert(conn)
        try failedOwn.insert(conn)
    }

    let promoteNow: Int64 = 100_000
    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobs: BlobStore(root: paths.blobsDir),
        selfDeviceID: "self-dev",
        now: promoteNow
    )
    #expect(result.stampedRows == 3)

    let after = try Database(path: paths.mainDB, role: .primary)
    let items = try after.pool.read { conn in
        try Item.order(Column("captured_at_ns")).fetchAll(conn)
    }
    #expect(items.count == 3)
    // 三行 ingested_at_ns 都被 stamp、严格单调（nextIngestNs 契约）
    let stamps = items.compactMap { $0.ingestedAtNs }
    #expect(stamps.count == 3)
    #expect(stamps[0] >= promoteNow)
    #expect(stamps[0] < stamps[1])
    #expect(stamps[1] < stamps[2])
    // 全部 push_state → acked，attempts 归零、error 清空
    #expect(items.allSatisfy { $0.pushState == .acked })
    #expect(items.allSatisfy { $0.pushAttempts == 0 })
    #expect(items.allSatisfy { $0.lastPushError == nil })
}

@Test func promoteDoesNotReStampAlreadyIngestedRows() throws {
    // 已经有 ingested_at_ns 的行不该被 stamp 二次（避免把跟其它 client 协调好的 ns 改掉）。
    // 现实场景：本机以前是 primary，ingested 字段已有；又被自己再 promote 一次。
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .client)
    let already = Item(id: "x", originDevice: "self-dev", capturedAtNs: 1_000,
                       ingestedAtNs: 555, kind: .text, preview: "x", pushState: .acked)
    try db.pool.write { conn in try already.insert(conn) }

    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobs: BlobStore(root: paths.blobsDir),
        selfDeviceID: "self-dev",
        now: 999_999
    )
    #expect(result.stampedRows == 0)

    let after = try Database(path: paths.mainDB, role: .primary)
    let row = try after.pool.read { conn in
        try Item.filter(Column("id") == "x").fetchOne(conn)
    }
    #expect(row?.ingestedAtNs == 555)  // 原 ns 不动
}

@Test func promoteStampsMirrorOriginatedRowsAsLastResort() throws {
    // 防御：mirror 表里的 ingested_at_ns 出现 nil（异常，老 primary schema 漏 stamp 或
    // 数据 corruption）。INSERT OR IGNORE 进 item 后 stamp 阶段必须兜底。
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .client)
    try db.pool.write { conn in
        // 直接 INSERT，ingested_at_ns=NULL（insertMirrorRow helper 用 capturedAtNs，所以
        // 这里手工写）
        try conn.execute(sql: """
            INSERT INTO item_mirror
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, mirrored_at_ns)
            VALUES ('m1', 'device-A', 5_000, NULL, 'text', NULL, NULL,
                    'mp', 'mt', NULL, NULL, NULL, 0, NULL, 5_000)
        """)
    }

    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobs: BlobStore(root: paths.blobsDir),
        selfDeviceID: "self-dev",
        now: 200_000
    )
    // 进了 1 条 + stamp 了 1 条
    #expect(result.promotedRows == 1)
    #expect(result.stampedRows == 1)

    let after = try Database(path: paths.mainDB, role: .primary)
    let row = try after.pool.read { conn in
        try Item.filter(Column("id") == "m1").fetchOne(conn)
    }
    #expect(row?.ingestedAtNs != nil)
    #expect((row?.ingestedAtNs ?? 0) >= 200_000)
    // mirror 来的行 origin 不动，但 push_state 也强制 acked
    #expect(row?.originDevice == "device-A")
    #expect(row?.pushState == .acked)
}

// MARK: - P2: blob 缺失预检

@Test func promoteRefusesWhenBlobsMissingByDefault() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .client)
    // mirror 含 blob_sha256，但 BlobStore 没字节
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item_mirror
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, mirrored_at_ns)
            VALUES ('img-1', 'device-A', 1_000, 1_000, 'image', NULL, NULL,
                    NULL, NULL, 'abcdef0123456789' || '00000000000000000000000000000000' || '0000000000000000', 12345, 'image/png', 0, NULL, 1_000)
        """)
    }

    let blobs = BlobStore(root: paths.blobsDir)
    var caught: Admin.AdminError? = nil
    do {
        _ = try Admin.promoteToPrimary(
            dbPath: paths.mainDB,
            configPath: paths.configFile,
            blobs: blobs,
            selfDeviceID: "self-dev",
            now: 1
        )
    } catch let e as Admin.AdminError {
        caught = e
    }
    guard case .missingBlobs(let total, let samples) = caught else {
        Issue.record("expected missingBlobs error, got \(String(describing: caught))")
        return
    }
    #expect(total == 1)
    #expect(samples.count == 1)
    #expect(samples[0].hasPrefix("abcdef"))

    // DB 状态：tx 没运行，mirror 表仍含原行；config 没改
    let after = try Database(path: paths.mainDB, role: .client)
    let mirrorCount = try after.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item_mirror") ?? -1
    }
    #expect(mirrorCount == 1)
    let cfg = try Config.load(from: paths.configFile)
    #expect(cfg.primaryURL != nil)  // 还在 client 模式
    #expect(cfg.serve == false)
}

@Test func promoteWithAllowMissingBlobsReportsAndContinues() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .client)
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item_mirror
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, mirrored_at_ns)
            VALUES ('img-x', 'device-A', 1_000, 1_000, 'image', NULL, NULL,
                    NULL, NULL, 'aa' || '000000000000000000000000000000000000000000000000000000000000000', 99, 'image/png', 0, NULL, 1_000)
        """)
    }

    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobs: BlobStore(root: paths.blobsDir),
        selfDeviceID: "self-dev",
        now: 50,
        allowMissingBlobs: true
    )
    #expect(result.missingBlobsTotal == 1)
    #expect(result.missingBlobsSamples.count == 1)
    #expect(result.promotedRows == 1)

    let after = try Database(path: paths.mainDB, role: .primary)
    let mirrorCount = try after.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item_mirror") ?? -1
    }
    #expect(mirrorCount == 0)  // 已清空，promote 跑完了
    let cfg = try Config.load(from: paths.configFile)
    #expect(cfg.serve == true)
    #expect(cfg.primaryURL == nil)
}

@Test func promotePassesWhenBlobBytesPresent() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let blobs = BlobStore(root: paths.blobsDir)
    // 写一字节进 BlobStore，拿到真实 sha
    let info = try blobs.put(Data([0x42]))
    let sha = info.sha256

    let db = try Database(path: paths.mainDB, role: .client)
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item_mirror
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, mirrored_at_ns)
            VALUES ('img-ok', 'device-A', 1_000, 1_000, 'image', NULL, NULL,
                    NULL, NULL, ?, 1, 'application/octet-stream', 0, NULL, 1_000)
        """, arguments: [sha])
    }

    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobs: blobs,
        selfDeviceID: "self-dev",
        now: 1
    )
    #expect(result.missingBlobsTotal == 0)
    #expect(result.missingBlobsSamples.isEmpty)
    #expect(result.promotedRows == 1)
}

@Test func promoteIgnoresMissingBlobOnSoftDeletedRows() throws {
    // 软删行就算 blob_sha256 非空也不该参与预检——tombstone 不需要 blob 字节。
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .client)
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item_mirror
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, mirrored_at_ns)
            VALUES ('img-deleted', 'device-A', 1_000, 1_000, 'image', NULL, NULL,
                    NULL, NULL, 'bb' || '000000000000000000000000000000000000000000000000000000000000000', 12, 'image/png', 0, 9999, 1_000)
        """)
    }

    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobs: BlobStore(root: paths.blobsDir),
        selfDeviceID: "self-dev",
        now: 1
    )
    #expect(result.missingBlobsTotal == 0)
    #expect(result.promotedRows == 1)
}

// MARK: - P1 review fix: daemon-running 安全检查

@Test func promoteRefusesWhenDaemonRunning() throws {
    // daemon 在跑时 promote 必须 throw daemonRunning（CLI 层会调 launchctl 检测后传 true）。
    // 设计语义：promote 期间 daemon 仍以 client mode capture 新行，ingested_at_ns=nil 永远
    // 卡在 /since 之外；强制让用户先 bootout
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    var caught: Admin.AdminError? = nil
    do {
        _ = try Admin.promoteToPrimary(
            dbPath: paths.mainDB,
            configPath: paths.configFile,
            blobs: BlobStore(root: paths.blobsDir),
            selfDeviceID: "self-dev",
            now: 1,
            daemonRunning: true,
            daemonLabel: "io.duopaste.agent"
        )
    } catch let e as Admin.AdminError {
        caught = e
    }
    guard case .daemonRunning(let label) = caught else {
        Issue.record("expected daemonRunning, got \(String(describing: caught))")
        return
    }
    #expect(label == "io.duopaste.agent")

    // config 没被改：仍是 client 状态
    let cfg = try Config.load(from: paths.configFile)
    #expect(cfg.primaryURL != nil)
    #expect(cfg.serve == false)
}

@Test func promoteProceedsWhenDaemonNotRunning() throws {
    // 默认 daemonRunning=false（dev 场景 / 用户已 bootout）→ promote 正常进入
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)

    let result = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobs: BlobStore(root: paths.blobsDir),
        selfDeviceID: "self-dev",
        now: 1,
        daemonRunning: false
    )
    #expect(result.configWrittenTo == paths.configFile)
}

// MARK: - P2 review fix: nested config 字段保留

@Test func promotePreservesNestedUserConfigFields() throws {
    // pull / capture 子 dict 里用户/未来加的扩展 key 必须保留，不能因为 Config.write
    // 全量 replace 子 dict 而丢掉
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile, extraKeys: [
        "pull": [
            "enabled": true,
            "interval_sec": 30,
            "eager_blobs": false,
            "x_pull_custom": "保留我",
            "future_max_concurrency": 4,
        ],
        "capture": [
            "max_blob_mb": 16,
            "max_text_kb": 900,
            "merge_window_sec": 600,
            "x_capture_note": "图片优先",
            "future_dedupe_strategy": "fuzzy",
        ],
    ])

    _ = try Admin.promoteToPrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobs: BlobStore(root: paths.blobsDir),
        selfDeviceID: "self-dev",
        now: 1
    )

    // 已知字段更新正确
    let cfg = try Config.load(from: paths.configFile)
    #expect(cfg.capture.maxBlobBytes == 16 * 1024 * 1024)
    #expect(cfg.capture.maxTextBytes == 900 * 1024)
    #expect(cfg.pull.enabled == false)  // promote 后 pull 应关闭

    // 嵌套未知字段保留
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile)) as! [String: Any]
    let pull = raw["pull"] as? [String: Any]
    #expect((pull?["x_pull_custom"] as? String) == "保留我")
    #expect((pull?["future_max_concurrency"] as? Int) == 4)
    #expect((pull?["enabled"] as? Bool) == false)

    let capture = raw["capture"] as? [String: Any]
    #expect((capture?["x_capture_note"] as? String) == "图片优先")
    #expect((capture?["future_dedupe_strategy"] as? String) == "fuzzy")
    #expect((capture?["max_blob_mb"] as? Int) == 16)
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

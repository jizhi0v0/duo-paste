import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-migrate-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writePrimaryConfig(
    to path: URL,
    extraKeys: [String: Any] = [:]
) throws {
    var dict: [String: Any] = [
        "serve": true,
        "serve_host": "0.0.0.0",
        "serve_port": 8443,
    ]
    for (k, v) in extraKeys { dict[k] = v }
    let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: path, options: [.atomic])
}

private func writeClientConfig(to path: URL) throws {
    let dict: [String: Any] = [
        "serve": false,
        "primary_url": "https://primary.example:8443",
        "pull": ["enabled": true, "interval_sec": 30, "eager_blobs": false],
    ]
    let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: path, options: [.atomic])
}

/// 往 item 表插一行。primary 模式 DB；用 SQL 直插绕过 CaptureService 的字节守门 / role 判断
private func insertItem(
    _ conn: GRDB.Database,
    id: String,
    origin: String,
    capturedAtNs: Int64,
    kind: String = "text",
    text: String = "x",
    blobSha: String? = nil,
    deletedAtNs: Int64? = nil
) throws {
    try conn.execute(sql: """
        INSERT INTO item
          (id, origin_device, captured_at_ns, ingested_at_ns, kind,
           source_app, source_app_name, preview, text_full,
           blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
           push_state, push_attempts, last_push_error)
        VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, NULL, NULL, 0, ?, 'acked', 0, NULL)
    """, arguments: [id, origin, capturedAtNs, capturedAtNs, kind, text, text, blobSha, deletedAtNs])
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

// MARK: - 模式校验

@Test func migrateRefusesStandaloneMode() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    // 不写 config → load 返回 .default（standalone）
    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.migratePrimary(
            dbPath: paths.mainDB,
            configPath: paths.configFile,
            blobsRoot: paths.blobsDir,
            snapshotsDir: paths.snapshotsDir
        )
    }
}

@Test func migrateRefusesClientMode() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writeClientConfig(to: paths.configFile)
    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.migratePrimary(
            dbPath: paths.mainDB,
            configPath: paths.configFile,
            blobsRoot: paths.blobsDir,
            snapshotsDir: paths.snapshotsDir
        )
    }
}

@Test func migrateRefusesWhenDaemonRunning() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writePrimaryConfig(to: paths.configFile)
    // primary DB 文件不存在也无所谓——daemon 检查在 DB 打开之前
    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.migratePrimary(
            dbPath: paths.mainDB,
            configPath: paths.configFile,
            blobsRoot: paths.blobsDir,
            snapshotsDir: paths.snapshotsDir,
            daemonRunning: true
        )
    }
}

@Test func migrateProceedsWhenDaemonNotRunning() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writePrimaryConfig(to: paths.configFile)
    let db = try Database(path: paths.mainDB, role: .primary)
    _ = db
    let r = try Admin.migratePrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobsRoot: paths.blobsDir,
        snapshotsDir: paths.snapshotsDir,
        daemonRunning: false
    )
    // snapshot 文件应已写
    #expect(FileManager.default.fileExists(atPath: r.snapshotPath.path))
}

// MARK: - 快照 + 统计

@Test func migrateWritesSnapshotWithItemCounts() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writePrimaryConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .primary)
    try db.pool.write { conn in
        try insertItem(conn, id: "a", origin: "mini", capturedAtNs: 1_000)
        try insertItem(conn, id: "b", origin: "mini", capturedAtNs: 2_000)
        try insertItem(conn, id: "c", origin: "mbp", capturedAtNs: 3_000)
    }

    let r = try Admin.migratePrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobsRoot: paths.blobsDir,
        snapshotsDir: paths.snapshotsDir
    )

    #expect(r.itemRowCount == 3)
    #expect(r.itemMirrorRowCount == 0)
    #expect(FileManager.default.fileExists(atPath: r.snapshotPath.path))
    #expect(r.snapshotBytes > 0)
    // snapshot 应落在传入的 snapshotsDir 下（URL trailing-slash 不稳，用 .path 比）
    #expect(r.snapshotPath.deletingLastPathComponent().path == paths.snapshotsDir.path)
}

@Test func migrateCountsBlobsRecursively() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writePrimaryConfig(to: paths.configFile)
    _ = try Database(path: paths.mainDB, role: .primary)

    let store = BlobStore(root: paths.blobsDir)
    let payloads: [Data] = [
        Data(repeating: 0x01, count: 100),
        Data(repeating: 0x02, count: 200),
        Data(repeating: 0x03, count: 300),
    ]
    for p in payloads {
        _ = try store.put(p, ext: "bin")
    }
    let expectedBytes: Int64 = 100 + 200 + 300

    let r = try Admin.migratePrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobsRoot: paths.blobsDir,
        snapshotsDir: paths.snapshotsDir
    )

    #expect(r.blobsTotalFiles == 3)
    #expect(r.blobsTotalBytes == expectedBytes)
}

@Test func migrateHandlesEmptyBlobsDir() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writePrimaryConfig(to: paths.configFile)
    _ = try Database(path: paths.mainDB, role: .primary)
    // blobs/ 存在但空（ensureExists 已建目录）

    let r = try Admin.migratePrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobsRoot: paths.blobsDir,
        snapshotsDir: paths.snapshotsDir
    )
    #expect(r.blobsTotalFiles == 0)
    #expect(r.blobsTotalBytes == 0)
}

@Test func migrateHandlesMissingBlobsDir() throws {
    // blobs 目录从未被创建（不调 ensureExists）→ walk 应返回 (0, 0) 而非 throw
    let dir = tempDir()
    let paths = Paths(root: dir)
    // 故意只建 db 目录、不调 paths.ensureExists()
    try FileManager.default.createDirectory(at: paths.dbDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.snapshotsDir, withIntermediateDirectories: true)
    try writePrimaryConfig(to: paths.configFile)
    _ = try Database(path: paths.mainDB, role: .primary)
    #expect(!FileManager.default.fileExists(atPath: paths.blobsDir.path))

    let r = try Admin.migratePrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobsRoot: paths.blobsDir,
        snapshotsDir: paths.snapshotsDir
    )
    #expect(r.blobsTotalFiles == 0)
    #expect(r.blobsTotalBytes == 0)
}

@Test func migrateReportsItemMirrorCountWhenNonZero() throws {
    // 边界：primary 模式下 item_mirror 不该有行，但若历史是 client → 残留行还在 schema 里。
    // 命令应如实报告非零，让操作员意识到 snapshot 会带走这些行
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writePrimaryConfig(to: paths.configFile)

    let db = try Database(path: paths.mainDB, role: .primary)
    try db.pool.write { conn in
        try insertMirrorRow(conn, id: "m1", origin: "old-A", capturedAtNs: 100)
        try insertMirrorRow(conn, id: "m2", origin: "old-B", capturedAtNs: 200)
    }

    let r = try Admin.migratePrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobsRoot: paths.blobsDir,
        snapshotsDir: paths.snapshotsDir
    )
    #expect(r.itemMirrorRowCount == 2)
}

// MARK: - 只读 invariant

@Test func migrateDoesNotMutateConfigOrMainDB() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writePrimaryConfig(to: paths.configFile, extraKeys: [
        "user_custom_field": "must-survive",  // 顺手验证非 Config 字段不被改
    ])

    // 主 DB 写点东西，让快照 vs 主 DB 区分开
    let db = try Database(path: paths.mainDB, role: .primary)
    try db.pool.write { conn in
        try insertItem(conn, id: "x", origin: "mini", capturedAtNs: 1)
    }
    // 关 DB 让 WAL/SHM checkpoint 落回主文件，否则字节比较会被 WAL 干扰
    _ = db  // 持有引用直到 migrate 调用前

    let configBefore = try Data(contentsOf: paths.configFile)
    // GRDB DatabasePool 在析构时 checkpoint。这里测试范围里 db 还活着，对比主 DB 文件意义不大；
    // 改成对比 config 完整保留 + 主 DB 文件**存在且行数没变**
    let countBefore = try db.pool.read { conn -> Int in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }

    _ = try Admin.migratePrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobsRoot: paths.blobsDir,
        snapshotsDir: paths.snapshotsDir
    )

    // config 字节级不变
    let configAfter = try Data(contentsOf: paths.configFile)
    #expect(configBefore == configAfter)

    // 主 DB 行数不变
    let countAfter = try db.pool.read { conn -> Int in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(countAfter == countBefore)
}

// MARK: - ShellTemplate（migrate-primary 命令模板渲染用）

@Test func shellTemplateAcceptsValidHostnames() throws {
    #expect(ShellTemplate.isSafeHost("mini"))
    #expect(ShellTemplate.isSafeHost("bobbys-mac-mini.tail69730a.ts.net"))
    #expect(ShellTemplate.isSafeHost("100.68.44.27"))
    #expect(ShellTemplate.isSafeHost("foo_bar.example-com.local"))
}

@Test func shellTemplateRejectsShellMetacharacters() throws {
    #expect(!ShellTemplate.isSafeHost(""))
    #expect(!ShellTemplate.isSafeHost("mini; rm -rf ~"))
    #expect(!ShellTemplate.isSafeHost("$(touch /tmp/pwned)"))
    #expect(!ShellTemplate.isSafeHost("`whoami`"))
    #expect(!ShellTemplate.isSafeHost("host with space"))
    #expect(!ShellTemplate.isSafeHost("host'name"))
    #expect(!ShellTemplate.isSafeHost("host\"name"))
    #expect(!ShellTemplate.isSafeHost("host|cat /etc/passwd"))
    #expect(!ShellTemplate.isSafeHost("host\nnewline"))
    #expect(!ShellTemplate.isSafeHost("host/slash"))
    #expect(!ShellTemplate.isSafeHost("host\\back"))
    // 拒绝 host:port —— ssh/scp 端口要走 -p / -P，不能嵌进 user@host: 字符串
    // （否则 scp 会把 :port 当成路径分隔符）
    #expect(!ShellTemplate.isSafeHost("host:8443"))
    #expect(!ShellTemplate.isSafeHost("[::1]"))
}

@Test func shellTemplateRejectsOverLongHost() throws {
    // FQDN 上限 253 chars。等长 OK，超 1 拒绝
    let ok = String(repeating: "a", count: 253)
    let tooLong = String(repeating: "a", count: 254)
    #expect(ShellTemplate.isSafeHost(ok))
    #expect(!ShellTemplate.isSafeHost(tooLong))
}

@Test func shellTemplateSingleQuoteEscapesEmbeddedQuotes() throws {
    #expect(ShellTemplate.singleQuote("simple") == "'simple'")
    #expect(ShellTemplate.singleQuote("/Users/bob/path") == "'/Users/bob/path'")
    // 内部 ' → '\''（POSIX 标准 single-quote escape）
    #expect(ShellTemplate.singleQuote("it's") == "'it'\\''s'")
    // 含空格 / 元字符 / 多个引号也安全
    #expect(ShellTemplate.singleQuote("a 'b' c") == "'a '\\''b'\\'' c'")
    #expect(ShellTemplate.singleQuote("$(evil)") == "'$(evil)'")
    #expect(ShellTemplate.singleQuote("") == "''")
}

@Test func migrateRunsTwiceProducesTwoDistinctSnapshots() throws {
    // 同一秒内两次跑——文件名按秒级，理论上可能撞名。这条用 DateFormatter 验：
    // 实际场景操作员手跑两次至少差几秒；本测试用不同 now 显式让快照名不同
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    try writePrimaryConfig(to: paths.configFile)
    _ = try Database(path: paths.mainDB, role: .primary)

    let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    let t2 = Date(timeIntervalSince1970: 1_700_000_060)  // +60s
    let r1 = try Admin.migratePrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobsRoot: paths.blobsDir,
        snapshotsDir: paths.snapshotsDir,
        now: t1
    )
    let r2 = try Admin.migratePrimary(
        dbPath: paths.mainDB,
        configPath: paths.configFile,
        blobsRoot: paths.blobsDir,
        snapshotsDir: paths.snapshotsDir,
        now: t2
    )
    #expect(r1.snapshotPath != r2.snapshotPath)
    #expect(FileManager.default.fileExists(atPath: r1.snapshotPath.path))
    #expect(FileManager.default.fileExists(atPath: r2.snapshotPath.path))
}

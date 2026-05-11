import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private typealias Database = DuoPasteCore.Database

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-paste-tests-" + UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeFixture() throws -> (Paths, Database, BlobStore, CaptureService) {
    let root = tempDir()
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try Database(path: paths.mainDB, role: .primary)
    let blobs = BlobStore(root: paths.blobsDir)
    let service = CaptureService(database: db, blobs: blobs, deviceID: "device-test")
    return (paths, db, blobs, service)
}

@Test func migrationCreatesItemTableAndFTS() throws {
    let (_, db, _, _) = try makeFixture()
    try db.pool.read { conn in
        let itemExists = try Bool.fetchOne(conn, sql: """
            SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='item')
        """)
        let ftsExists = try Bool.fetchOne(conn, sql: """
            SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='item_fts')
        """)
        #expect(itemExists == true)
        #expect(ftsExists == true)
    }
}

@Test func v2MigrationCreatesMirrorTables() throws {
    let (_, db, _, _) = try makeFixture()
    try db.pool.read { conn in
        for name in ["item_mirror", "item_mirror_fts", "pull_cursor"] {
            let exists = try Bool.fetchOne(conn, sql: """
                SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?)
            """, arguments: [name]) ?? false
            #expect(exists, "expected \(name) to exist after migration")
        }
    }
}

@Test func v2MigrationIsIdempotentOnReopen() throws {
    // 用一个固定 DB 文件，先 open 一次跑 migration，再 open 一次应零变更。
    let root = tempDir()
    let paths = Paths(root: root)
    paths.ensureExists()
    _ = try Database(path: paths.mainDB, role: .primary)
    // 第二次打开：GRDB 应跳过已应用的 migration。如果 v2 不幂等会因 CREATE TABLE 重复报错。
    _ = try Database(path: paths.mainDB, role: .primary)
}

@Test func mirrorFTSRoundTrip() throws {
    // 验证 item_mirror 的 FTS trigger 真的会被触发——这是 M3 pull worker 上线前
    // 唯一能验证 mirror 表 + FTS 是否串通的入口。
    let (_, db, _, _) = try makeFixture()
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item_mirror (id, origin_device, captured_at_ns, kind,
                                     preview, text_full, source_app_name,
                                     pinned, mirrored_at_ns)
            VALUES ('m1', 'remote-device', 1000, 'text',
                    'hello mirror', 'hello mirror world', 'WeChat',
                    0, 2000);
        """)
    }
    try db.pool.read { conn in
        let hit = try String.fetchOne(conn, sql: """
            SELECT id FROM item_mirror
            WHERE rowid IN (SELECT rowid FROM item_mirror_fts WHERE item_mirror_fts MATCH ?)
        """, arguments: ["mirror"])
        #expect(hit == "m1")
    }
}

@Test func uuidv7IsMonotonicByMs() {
    let a = UUIDv7.generate(timestampMs: 1_000_000)
    let b = UUIDv7.generate(timestampMs: 2_000_000)
    let sa = a.uuidString
    let sb = b.uuidString
    #expect(sa < sb)
    let version = sa.split(separator: "-")[2].first!
    #expect(version == "7")
}

@Test func blobStorePutDedupsByHash() throws {
    let (_, _, blobs, _) = try makeFixture()
    let data = Data("hello world".utf8)
    let first = try blobs.put(data, ext: "txt")
    let second = try blobs.put(data, ext: "txt")
    #expect(first.sha256 == second.sha256)
    #expect(first.wasExisting == false)
    #expect(second.wasExisting == true)
    #expect(blobs.exists(sha256: first.sha256))
    let roundTrip = try blobs.read(sha256: first.sha256)
    #expect(roundTrip == data)
}

@Test func captureInsertsAndRetrievesText() async throws {
    let (_, db, _, service) = try makeFixture()
    let c = CapturedPasteboard(
        kind: .text,
        text: "hello capture world",
        sourceAppBundleID: "com.example",
        sourceAppName: "Example",
        capturedAtNs: 1_000_000_000_000_000_000
    )
    let result = try await service.ingest(c)
    #expect(result.outcome == .inserted)

    let items = try await db.pool.read { conn in
        try Item.fetchAll(conn)
    }
    #expect(items.count == 1)
    #expect(items[0].kind == .text)
    #expect(items[0].textFull == "hello capture world")
    #expect(items[0].pushState == .acked) // primary mode
}

@Test func captureMergesIdenticalWithinWindow() async throws {
    let (_, db, _, service) = try makeFixture()
    let baseNs: Int64 = 5_000_000_000_000_000_000
    let first = CapturedPasteboard(kind: .text, text: "dup", capturedAtNs: baseNs)
    let second = CapturedPasteboard(kind: .text, text: "dup", capturedAtNs: baseNs + 500_000_000) // +0.5s

    let r1 = try await service.ingest(first)
    let r2 = try await service.ingest(second)
    #expect(r1.outcome == .inserted)
    #expect(r2.outcome == .mergedWithPrevious)

    let count = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
    }
    #expect(count == 1)
    let only = try await db.pool.read { conn in try Item.fetchOne(conn)! }
    #expect(only.capturedAtNs == baseNs + 500_000_000)
    // primary 合并必须 bump ingested_at_ns，否则 /since cursor 已推进的 mirror 永远看不到
    // 这次 capturedAt 刷新（见 plan moonlit-wave.md "primary 在 /since 里也回放"）
    #expect(only.ingestedAtNs != nil)
    #expect(only.ingestedAtNs! >= baseNs + 500_000_000)
}

@Test func captureDoesNotMergeAcrossWindow() async throws {
    let (_, db, _, service) = try makeFixture()
    let baseNs: Int64 = 6_000_000_000_000_000_000
    let first = CapturedPasteboard(kind: .text, text: "dup", capturedAtNs: baseNs)
    let later = CapturedPasteboard(kind: .text, text: "dup", capturedAtNs: baseNs + 3 * 1_000_000_000) // +3s

    _ = try await service.ingest(first)
    _ = try await service.ingest(later)

    let count = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
    }
    #expect(count == 2)
}

@Test func captureFileAsTextPath() async throws {
    let (_, db, _, service) = try makeFixture()
    let c = CapturedPasteboard(
        kind: .file,
        text: "/Users/bobby/foo.jpg\n/Users/bobby/bar.png",
        fileName: nil,
        sourceAppBundleID: "com.apple.finder",
        sourceAppName: "Finder",
        capturedAtNs: 6_500_000_000_000_000_000
    )
    let r = try await service.ingest(c)
    #expect(r.outcome == .inserted)
    let items = try await db.pool.read { conn in try Item.fetchAll(conn) }
    #expect(items.count == 1)
    #expect(items[0].kind == .file)
    #expect(items[0].textFull?.contains("foo.jpg") == true)
    #expect(items[0].blobSha256 == nil)
}

@Test func searchByText() async throws {
    let (_, db, _, service) = try makeFixture()
    let entries = [
        "alpha bravo charlie",
        "delta echo foxtrot",
        "alpha golf hotel",
    ]
    for (i, text) in entries.enumerated() {
        let c = CapturedPasteboard(
            kind: .text,
            text: text,
            capturedAtNs: Int64(7_000_000_000_000_000_000 + Int64(i) * 1_000_000_000)
        )
        _ = try await service.ingest(c)
    }

    let api = SearchAPI(database: db)
    let alpha = try api.search(SearchQuery(text: "alpha"))
    #expect(alpha.count == 2)
    // 最新的应该排在前面
    #expect(alpha[0].textFull == "alpha golf hotel")

    let foxtrot = try api.search(SearchQuery(text: "foxtr"))
    #expect(foxtrot.count == 1)
    #expect(foxtrot[0].textFull == "delta echo foxtrot")

    let multi = try api.search(SearchQuery(text: "alpha hotel"))
    #expect(multi.count == 1)
    #expect(multi[0].textFull == "alpha golf hotel")
}

@Test func searchTimeAndKindFilter() async throws {
    let (_, db, blobs, service) = try makeFixture()
    let base: Int64 = 8_000_000_000_000_000_000

    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "txt-old", capturedAtNs: base))
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "txt-new", capturedAtNs: base + 10 * 1_000_000_000))
    _ = try await service.ingest(CapturedPasteboard(
        kind: .image,
        blob: Data([0x89, 0x50, 0x4E, 0x47]),
        blobExt: "png",
        blobMime: "image/png",
        capturedAtNs: base + 5 * 1_000_000_000
    ))

    let api = SearchAPI(database: db)

    let images = try api.search(SearchQuery(kinds: [.image]))
    #expect(images.count == 1)
    #expect(images[0].kind == .image)

    let newOnly = try api.search(SearchQuery(fromNs: base + 8 * 1_000_000_000))
    #expect(newOnly.count == 1)
    #expect(newOnly[0].textFull == "txt-new")

    let blobOnDisk = try blobs.read(sha256: images[0].blobSha256!)
    #expect(blobOnDisk != nil)
}

@Test func exportJSONRoundTrip() async throws {
    let (paths, db, blobs, service) = try makeFixture()
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "first", capturedAtNs: 9_000_000_000_000_000_000))
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "second", capturedAtNs: 9_000_000_001_000_000_000))

    let exporter = Exporter(database: db, blobs: blobs)
    let dest = paths.root.appendingPathComponent("export-json", isDirectory: true)
    let result = try exporter.export(to: dest, options: ExportOptions(format: .json))
    #expect(result.itemCount == 2)
    let data = try Data(contentsOf: result.destination)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let itemsAny = json?["items"] as? [Any]
    #expect(itemsAny?.count == 2)
}

@Test func snapshotTakeProducesUsableDB() async throws {
    let (paths, db, _, service) = try makeFixture()
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "snap-1", capturedAtNs: 9_200_000_000_000_000_000))
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "snap-2", capturedAtNs: 9_200_000_001_000_000_000))

    let url = try Snapshot.takeSnapshot(database: db, paths: paths)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(url.lastPathComponent.hasPrefix(Snapshot.filenamePrefix))

    // 用独立 GRDB queue 打开 snapshot 验证内容
    let snap = try DatabaseQueue(path: url.path)
    let count = try await snap.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
    }
    #expect(count == 2)
}

@Test func snapshotPruneAppliesRetention() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dp-prune-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let now = Date(timeIntervalSince1970: 1_800_000_000) // 固定参照点

    // 编排一组测试快照：覆盖各分段
    let offsets: [TimeInterval] = [
        -1 * 3600,           // 1h ago      ← 24h 内，保留
        -10 * 3600,          // 10h ago     ← 24h 内，保留
        -25 * 3600,          // 25h ago     ← 24h~30d
        -26 * 3600,          // 26h ago     ← 与上一条同一天，淘汰
        -3 * 24 * 3600,      // 3 天前
        -3 * 24 * 3600 - 60, // 3 天前 1 分钟早，同一天 → 淘汰
        -5 * 24 * 3600,      // 5 天前
        -45 * 24 * 3600,     // 45 天前  ← 30d+ 段
        -46 * 24 * 3600,     // 46 天前  同月 → 淘汰
        -75 * 24 * 3600,     // 75 天前  另一个月
    ]
    var paths: [URL] = []
    for off in offsets {
        let d = now.addingTimeInterval(off)
        let name = Snapshot.filename(for: d)
        let p = dir.appendingPathComponent(name)
        try Data().write(to: p)
        paths.append(p)
    }

    let deleted = try Snapshot.prune(snapshotsDir: dir, now: now)

    // 应删除：3（24-30d 段同一天的较老）、5（同上）、9（30d+ 段同一月的较老）
    let deletedNames = Set(deleted.map(\.lastPathComponent))
    #expect(deletedNames.contains(paths[3].lastPathComponent))
    #expect(deletedNames.contains(paths[5].lastPathComponent))
    #expect(deletedNames.contains(paths[9].lastPathComponent))
    #expect(deleted.count == 3)

    // 保留：0,1（24h 内）、2,4,6（每天）、7,8（30d+ 不同月）
    for keptIdx in [0, 1, 2, 4, 6, 7, 8] {
        #expect(FileManager.default.fileExists(atPath: paths[keptIdx].path))
    }
}

@Test func exportSQLiteRoundTrip() async throws {
    let (paths, db, blobs, service) = try makeFixture()
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "alpha", capturedAtNs: 9_100_000_000_000_000_000))

    let exporter = Exporter(database: db, blobs: blobs)
    let dest = paths.root.appendingPathComponent("export-sqlite", isDirectory: true)
    let result = try exporter.export(to: dest, options: ExportOptions(format: .sqlite))
    #expect(FileManager.default.fileExists(atPath: result.destination.path))

    // 用 GRDB 重新打开导出的 db，应能读出
    let exported = try DatabaseQueue(path: result.destination.path)
    let count = try await exported.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
    }
    #expect(count == 1)
}

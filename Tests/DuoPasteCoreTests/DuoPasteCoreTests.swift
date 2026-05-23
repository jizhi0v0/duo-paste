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
    let db = try Database(path: paths.mainDB)
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

// PR 1 v7 migration 已 DROP item_mirror / item_mirror_fts。原 v2MigrationCreatesMirrorTables /
// mirrorFTSRoundTrip 测试不再适用——peer 行直接落 item 表，FTS 走 item_fts 触发器。

@Test func migrationIsIdempotentOnReopen() throws {
    // 用一个固定 DB 文件，先 open 一次跑 migration，再 open 一次应零变更。
    let root = tempDir()
    let paths = Paths(root: root)
    paths.ensureExists()
    _ = try Database(path: paths.mainDB)
    // 第二次打开：GRDB 应跳过已应用的 migration。如果不幂等会因 CREATE TABLE 重复报错。
    _ = try Database(path: paths.mainDB)
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
    #expect(items[0].ingestedAtNs != nil)  // mesh 拓扑下 capture 后立即 stamp
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
    // 验证「跨窗口必定分裂」的策略不变量，跟具体窗口数值解耦：
    // 显式构 2s 文本窗口的 service，间隔 3s 复制同一内容 → 应当分裂为两行。
    // 默认 textMergeWindowSec=nil（永久 dedup）会让 text 永远合并——本测试
    // 要的是"有限窗口下跨窗分裂"，所以显式注入 textMergeWindowNs。
    let root = tempDir()
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try Database(path: paths.mainDB)
    let blobs = BlobStore(root: paths.blobsDir)
    let service = CaptureService(
        database: db, blobs: blobs, deviceID: "device-test",
        textMergeWindowNs: .some(2 * 1_000_000_000)
    )
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

// MARK: - setPinnedAny (跨 origin 版,给 POST /pin handler 用)

/// own-origin 行 pin 切换:pinned 列翻转 + bump ingested_at_ns
@Test func setPinnedAnyFlipsOwnOriginRow() async throws {
    let (_, db, _, service) = try makeFixture()
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "x-any", capturedAtNs: 1_000_000_000))
    let id = try await db.pool.read { conn in
        try String.fetchOne(conn, sql: "SELECT id FROM item LIMIT 1") ?? ""
    }
    let nsBefore = try await db.pool.read { conn in
        try Int64.fetchOne(conn, sql: "SELECT ingested_at_ns FROM item WHERE id = ?", arguments: [id]) ?? 0
    }
    let newNs = try await db.setPinnedAny(id: id, pinned: true, now: nsBefore &+ 100)
    #expect(newNs != nil)
    #expect(newNs! > nsBefore)
    let row = try await db.pool.read { conn -> (Int, Int64) in
        let p = try Int.fetchOne(conn, sql: "SELECT pinned FROM item WHERE id = ?", arguments: [id]) ?? 0
        let n = try Int64.fetchOne(conn, sql: "SELECT ingested_at_ns FROM item WHERE id = ?", arguments: [id]) ?? 0
        return (p, n)
    }
    #expect(row.0 == 1)
    #expect(row.1 == newNs)
}

/// 关键契约: mirror 行(origin != self)也能 pin —— 不带 own-origin guard,这是跨 origin 版的存在意义
@Test func setPinnedAnyAcceptsMirrorRow() async throws {
    let (_, db, _, _) = try makeFixture()
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, ingested_at_ns, kind, pinned)
            VALUES ('mirror-id', 'other-device', 1_000_000, 500_000, 'text', 0)
        """)
    }
    let newNs = try await db.setPinnedAny(id: "mirror-id", pinned: true, now: 2_000_000)
    #expect(newNs != nil)
    let p = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT pinned FROM item WHERE id = ?", arguments: ["mirror-id"]) ?? -1
    }
    #expect(p == 1)
}

/// 目标 pinned 跟当前一致 → 返 nil,不 bump cursor 防无意义 fan-out
@Test func setPinnedAnyNoOpWhenSameState() async throws {
    let (_, db, _, service) = try makeFixture()
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "y-any", capturedAtNs: 1_000_000_000))
    let id = try await db.pool.read { conn in
        try String.fetchOne(conn, sql: "SELECT id FROM item LIMIT 1") ?? ""
    }
    let nsBefore = try await db.pool.read { conn in
        try Int64.fetchOne(conn, sql: "SELECT ingested_at_ns FROM item WHERE id = ?", arguments: [id]) ?? 0
    }
    // 当前 pinned=0,再设 false → noop
    let result = try await db.setPinnedAny(id: id, pinned: false, now: nsBefore &+ 5_000)
    #expect(result == nil)
    let nsAfter = try await db.pool.read { conn in
        try Int64.fetchOne(conn, sql: "SELECT ingested_at_ns FROM item WHERE id = ?", arguments: [id]) ?? 0
    }
    #expect(nsAfter == nsBefore)
}

/// 不存在的 id → 抛 .notFound(跟 softDelete / bumpCapturedAt 行为一致)
@Test func setPinnedAnyThrowsNotFoundForGhostID() async throws {
    let (_, db, _, _) = try makeFixture()
    await #expect(throws: BumpError.notFound) {
        _ = try await db.setPinnedAny(id: "ghost", pinned: true, now: 1)
    }
}

/// tombstone 行 → 抛 .deleted(不该让用户 pin 一条已删的行)
@Test func setPinnedAnyRejectsTombstoned() async throws {
    let (_, db, _, _) = try makeFixture()
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, ingested_at_ns, kind, pinned, deleted_at_ns)
            VALUES ('dead-id', 'device-test', 1_000_000, 500_000, 'text', 0, 1_500_000)
        """)
    }
    await #expect(throws: BumpError.deleted) {
        _ = try await db.setPinnedAny(id: "dead-id", pinned: true, now: 2_000_000)
    }
}

// MARK: - getPinned (给 togglePin 在 Task 内重读真值用,防快速双击 stale-snapshot 倒转)

/// 读出当前真实 pinned 值——翻转后再读得到新值
@Test func getPinnedReturnsCurrentState() async throws {
    let (_, db, _, service) = try makeFixture()
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "p-state", capturedAtNs: 1_000_000_000))
    let id = try await db.pool.read { conn in
        try String.fetchOne(conn, sql: "SELECT id FROM item LIMIT 1") ?? ""
    }
    var got = try await db.getPinned(id: id)
    #expect(got == false)

    // 翻成 true
    _ = try await db.setPinnedAny(id: id, pinned: true, now: 2_000_000_000)
    got = try await db.getPinned(id: id)
    #expect(got == true)
}

/// 不存在的 id → 抛 .notFound(跟 setPinnedAny 错误集合对齐)
@Test func getPinnedThrowsNotFoundForUnknownID() async throws {
    let (_, db, _, _) = try makeFixture()
    await #expect(throws: BumpError.notFound) {
        _ = try await db.getPinned(id: "ghost")
    }
}

/// tombstone 行 → 抛 .deleted(同 setPinnedAny 语义,调用方 silently 视作 race)
@Test func getPinnedThrowsDeletedForTombstone() async throws {
    let (_, db, _, _) = try makeFixture()
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, ingested_at_ns, kind, pinned, deleted_at_ns)
            VALUES ('dead-pin', 'device-test', 1_000_000, 500_000, 'text', 0, 1_500_000)
        """)
    }
    await #expect(throws: BumpError.deleted) {
        _ = try await db.getPinned(id: "dead-pin")
    }
}

// MARK: - togglePinAny (原子 read+flip+write,关 getPinned+setPinnedAny 两步走的 TOCTOU race)

/// pinned=false → toggle → newPinned=true + DB pinned 列翻转 + bump ingested_at_ns
@Test func togglePinAnyFlipsFromFalseToTrue() async throws {
    let (_, db, _, service) = try makeFixture()
    _ = try await service.ingest(CapturedPasteboard(kind: .text, text: "t-false", capturedAtNs: 1_000_000_000))
    let id = try await db.pool.read { conn in
        try String.fetchOne(conn, sql: "SELECT id FROM item LIMIT 1") ?? ""
    }
    let nsBefore = try await db.pool.read { conn in
        try Int64.fetchOne(conn, sql: "SELECT ingested_at_ns FROM item WHERE id = ?", arguments: [id]) ?? 0
    }
    let (newPinned, newIngest) = try await db.togglePinAny(id: id, now: nsBefore &+ 100)
    #expect(newPinned == true)
    #expect(newIngest > nsBefore)
    let row = try await db.pool.read { conn -> (Int, Int64) in
        let p = try Int.fetchOne(conn, sql: "SELECT pinned FROM item WHERE id = ?", arguments: [id]) ?? 0
        let n = try Int64.fetchOne(conn, sql: "SELECT ingested_at_ns FROM item WHERE id = ?", arguments: [id]) ?? 0
        return (p, n)
    }
    #expect(row.0 == 1)
    #expect(row.1 == newIngest)
}

/// pinned=true → toggle → newPinned=false
@Test func togglePinAnyFlipsFromTrueToFalse() async throws {
    let (_, db, _, _) = try makeFixture()
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, ingested_at_ns, kind, pinned)
            VALUES ('pin-true', 'device-test', 1_000_000, 500_000, 'text', 1)
        """)
    }
    let (newPinned, newIngest) = try await db.togglePinAny(id: "pin-true", now: 2_000_000)
    #expect(newPinned == false)
    #expect(newIngest > 500_000)
    let p = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT pinned FROM item WHERE id = ?", arguments: ["pin-true"]) ?? -1
    }
    #expect(p == 0)
}

/// 关键契约:mirror 行(origin != self)也能 toggle —— 不带 own-origin guard,跟 setPinnedAny 心智一致
@Test func togglePinAnyFlipsMirrorRowToo() async throws {
    let (_, db, _, _) = try makeFixture()
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, ingested_at_ns, kind, pinned)
            VALUES ('mirror-toggle', 'other-device', 1_000_000, 500_000, 'text', 0)
        """)
    }
    let (newPinned, _) = try await db.togglePinAny(id: "mirror-toggle", now: 2_000_000)
    #expect(newPinned == true)
    let p = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT pinned FROM item WHERE id = ?", arguments: ["mirror-toggle"]) ?? -1
    }
    #expect(p == 1)
}

/// 不存在的 id → 抛 .notFound
@Test func togglePinAnyThrowsNotFoundForUnknownID() async throws {
    let (_, db, _, _) = try makeFixture()
    await #expect(throws: BumpError.notFound) {
        _ = try await db.togglePinAny(id: "ghost", now: 1_000_000)
    }
}

/// tombstone 行 → 抛 .deleted(不该让用户 toggle 一条已删的行)
@Test func togglePinAnyThrowsDeletedForTombstone() async throws {
    let (_, db, _, _) = try makeFixture()
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, ingested_at_ns, kind, pinned, deleted_at_ns)
            VALUES ('dead-toggle', 'device-test', 1_000_000, 500_000, 'text', 0, 1_500_000)
        """)
    }
    await #expect(throws: BumpError.deleted) {
        _ = try await db.togglePinAny(id: "dead-toggle", now: 2_000_000)
    }
}

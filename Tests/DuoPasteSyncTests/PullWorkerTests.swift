import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

private func makeClientDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-pull-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB, role: .client)
}

private func mkItem(
    id: String,
    origin: String,
    ingestedAtNs: Int64,
    text: String = "x",
    pinned: Bool = false,
    deletedAtNs: Int64? = nil
) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: ingestedAtNs,
        ingestedAtNs: ingestedAtNs,
        kind: .text,
        sourceAppName: "Test",
        preview: text,
        textFull: text,
        pinned: pinned,
        deletedAtNs: deletedAtNs,
        pushState: .acked
    )
}

/// Fake SinceTransport with scriptable responses.
/// 串行 pop 直到 `pages` 空，之后所有调用回 unreachable（"no more scripted pages"）。
/// /health 调用单独计数 + 可配返回值。
private actor FakeSinceTransport: SinceTransport {
    private var pages: [SincePageWire]
    private var healthDeviceID: String
    private(set) var fetchSinceCalls: [(SinceCursor, Int)] = []
    private(set) var healthCalls: Int = 0

    init(pages: [SincePageWire], healthDeviceID: String) {
        self.pages = pages
        self.healthDeviceID = healthDeviceID
    }

    func setHealthDeviceID(_ id: String) {
        self.healthDeviceID = id
    }

    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        await self._fetchSince(cursor: cursor, limit: limit)
    }

    private func _fetchSince(cursor: SinceCursor, limit: Int) async -> RemoteSinceResult {
        fetchSinceCalls.append((cursor, limit))
        guard !pages.isEmpty else {
            return RemoteSinceResult(outcome: .unreachable(reason: "no more scripted pages"))
        }
        let p = pages.removeFirst()
        return RemoteSinceResult(outcome: .ok(p))
    }

    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        await self._fetchPrimaryHealth()
    }

    private func _fetchPrimaryHealth() async -> PrimaryHealthResult {
        healthCalls += 1
        return PrimaryHealthResult(outcome: .ok(deviceID: healthDeviceID, nowMs: 1_000))
    }
}

private func page(items: [Item], nextNs: Int64, nextID: String, hasMore: Bool) -> SincePageWire {
    SincePageWire(
        ok: true,
        count: items.count,
        items: items,
        nextCursor: SinceCursor(ingestedAtNs: nextNs, id: nextID),
        hasMore: hasMore
    )
}

private func runWorkerBriefly(_ worker: PullWorker, ms: Int = 250) async {
    await worker.start()
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    await worker.stop()
}

@Test func pullWorkerInsertsMirrorRowsAndAdvancesCursor() async throws {
    let db = try makeClientDB()
    let items = [
        mkItem(id: "p-1", origin: "primary-device", ingestedAtNs: 100, text: "from primary"),
        mkItem(id: "p-2", origin: "primary-device", ingestedAtNs: 200, text: "more primary"),
    ]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 200, nextID: "p-2", hasMore: false)],
        healthDeviceID: "primary-device"
    )
    let status = MirrorStatus()
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "client-self",
        mirrorStatus: status,
        config: PullWorker.Config(intervalSec: 60),
        nowNs: { 999 }
    )
    await runWorkerBriefly(worker)

    let mirrored = try await db.pool.read { conn in
        try Row.fetchAll(conn, sql: "SELECT id FROM item_mirror ORDER BY id")
    }
    #expect(mirrored.map { $0["id"] as String } == ["p-1", "p-2"])
    let cur = try await db.pool.read { conn in
        try Row.fetchOne(conn, sql: "SELECT cursor_ns, cursor_id, primary_id FROM pull_cursor")
    }
    #expect(cur?["cursor_ns"] as Int64? == 200)
    #expect(cur?["cursor_id"] as String? == "p-2")
    #expect(cur?["primary_id"] as String? == "primary-device")
    // lastPullNs 应该被标 —— 完整追平（hasMore=false）
    #expect(status.lastPullNs() == 999)
}

@Test func pullWorkerSkipsOwnOriginRows() async throws {
    // origin == selfDeviceID 的条目不应该入 item_mirror（避免和 item 表重复）
    let db = try makeClientDB()
    let items = [
        mkItem(id: "self-row", origin: "client-self", ingestedAtNs: 50),
        mkItem(id: "primary-row", origin: "primary-device", ingestedAtNs: 60),
    ]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 60, nextID: "primary-row", hasMore: false)],
        healthDeviceID: "primary-device"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "client-self",
        mirrorStatus: MirrorStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runWorkerBriefly(worker)

    let mirrored = try await db.pool.read { conn in
        try Row.fetchAll(conn, sql: "SELECT id FROM item_mirror")
    }
    #expect(mirrored.map { $0["id"] as String } == ["primary-row"])
    // cursor 应该照样推进到 page 末（包括自家 origin 那次也"算"过）
    let curNs = try await db.pool.read { conn -> Int64? in
        try Int64.fetchOne(conn, sql: "SELECT cursor_ns FROM pull_cursor")
    }
    #expect(curNs == 60)
}

@Test func pullWorkerFollowsMultiplePagesWhenHasMore() async throws {
    let db = try makeClientDB()
    let p1 = page(
        items: [mkItem(id: "a", origin: "primary", ingestedAtNs: 10)],
        nextNs: 10, nextID: "a", hasMore: true
    )
    let p2 = page(
        items: [mkItem(id: "b", origin: "primary", ingestedAtNs: 20)],
        nextNs: 20, nextID: "b", hasMore: false
    )
    let transport = FakeSinceTransport(
        pages: [p1, p2], healthDeviceID: "primary"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "self",
        mirrorStatus: MirrorStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runWorkerBriefly(worker, ms: 500)

    let mirrored = try await db.pool.read { conn in
        try Row.fetchAll(conn, sql: "SELECT id FROM item_mirror ORDER BY id")
    }
    #expect(mirrored.map { $0["id"] as String } == ["a", "b"])
    let calls = await transport.fetchSinceCalls
    // 至少两次 since 调用，第二次 cursor 应该是 (10, "a")
    #expect(calls.count >= 2)
    #expect(calls[1].0.ingestedAtNs == 10)
    #expect(calls[1].0.id == "a")
}

@Test func pullWorkerResetsMirrorWhenPrimaryDeviceChanges() async throws {
    let db = try makeClientDB()
    // 预先放一些"旧 primary" 留下的 mirror 数据 + cursor
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item_mirror
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, mirrored_at_ns)
            VALUES ('stale-1', 'old-primary', 100, 100, 'text', NULL, 'old', 'old', 'old', NULL, NULL, NULL, 0, NULL, 100)
        """)
        try conn.execute(sql: """
            INSERT INTO pull_cursor (primary_id, cursor_ns, cursor_id, updated_at_ns)
            VALUES ('old-primary', 999, 'stale-1', 100)
        """)
    }

    // /health 返回新 primary id → worker 应该清空 mirror + cursor，然后从 0 拉新数据
    let newItems = [mkItem(id: "fresh", origin: "new-primary", ingestedAtNs: 50, text: "fresh data")]
    let transport = FakeSinceTransport(
        pages: [page(items: newItems, nextNs: 50, nextID: "fresh", hasMore: false)],
        healthDeviceID: "new-primary"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "self",
        mirrorStatus: MirrorStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runWorkerBriefly(worker)

    let ids = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT id FROM item_mirror ORDER BY id")
    }
    #expect(ids == ["fresh"])  // 旧的 stale-1 应已被清掉
    let row = try await db.pool.read { conn in
        try Row.fetchOne(conn, sql: "SELECT primary_id, cursor_ns, cursor_id FROM pull_cursor")
    }
    #expect(row?["primary_id"] as String? == "new-primary")
    #expect(row?["cursor_ns"] as Int64? == 50)
    #expect(row?["cursor_id"] as String? == "fresh")
    // /since 第一次调用 cursor 应该是 .zero（重置后从头拉）
    let calls = await transport.fetchSinceCalls
    #expect(calls.first?.0 == SinceCursor.zero)
}

@Test func pullWorkerHandlesSoftDeletedRows() async throws {
    // /since 含 deleted_at_ns 非空的行：mirror 应该写入（mirror 表也支持软删，
    // searchUnion 的 fetchHitsMirror 会过滤掉）
    let db = try makeClientDB()
    let items = [mkItem(id: "dead", origin: "primary", ingestedAtNs: 100, deletedAtNs: 999)]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 100, nextID: "dead", hasMore: false)],
        healthDeviceID: "primary"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "self",
        mirrorStatus: MirrorStatus()
    )
    await runWorkerBriefly(worker)

    let row = try await db.pool.read { conn in
        try Row.fetchOne(conn, sql: "SELECT deleted_at_ns FROM item_mirror WHERE id='dead'")
    }
    #expect(row?["deleted_at_ns"] as Int64? == 999)
}

@Test func pullWorkerHTTPEndToEnd() async throws {
    // 起 in-process primary server → client PullWorker 真打 HTTP → 验证 mirror 落行 + cursor
    let primaryDB = try makeClientDB()  // role 不影响这里——直接 INSERT
    let primaryDeviceID = "primary-e2e"
    try await primaryDB.pool.write { conn in
        let it1 = Item(id: "a", originDevice: "other-mac", capturedAtNs: 100, ingestedAtNs: 100,
                       kind: .text, preview: "alpha", textFull: "alpha", pushState: .acked)
        let it2 = Item(id: "b", originDevice: "another-mac", capturedAtNs: 200, ingestedAtNs: 200,
                       kind: .text, preview: "bravo", textFull: "bravo", pushState: .acked)
        try it1.insert(conn)
        try it2.insert(conn)
    }
    let blobs = BlobStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-pull-e2e-blobs-\(UUID().uuidString)"))
    try FileManager.default.createDirectory(at: blobs.root, withIntermediateDirectories: true)
    let secret = Data(repeating: 0xAB, count: 32)
    let auth = HMACAuth(secret: secret)
    let port = Int.random(in: 19000..<20000)
    let server = SyncServer(deviceID: primaryDeviceID, database: primaryDB, blobs: blobs,
                            host: "127.0.0.1", port: port, auth: auth)
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    // 等 server 起：用 HTTPIngestClient.fetchPrimaryHealth() 轮询
    let probe = HTTPIngestClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, auth: auth)
    var ready = false
    for _ in 0..<50 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        if let r = try? await probe.fetchPrimaryHealth(),
           case .ok = r.outcome { ready = true; break }
    }
    #expect(ready)
    let clientDB = try makeClientDB()
    let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    let httpClient = HTTPIngestClient(baseURL: baseURL, auth: auth)
    let status = MirrorStatus()
    let worker = PullWorker(
        database: clientDB,
        transport: httpClient,
        selfDeviceID: "client-self",
        mirrorStatus: status,
        config: PullWorker.Config(intervalSec: 60)
    )
    await runWorkerBriefly(worker, ms: 600)

    let ids = try await clientDB.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT id FROM item_mirror ORDER BY id")
    }
    #expect(ids == ["a", "b"])
    #expect(status.primaryDeviceID() == primaryDeviceID)
    #expect(status.lastPullNs() != nil)
}

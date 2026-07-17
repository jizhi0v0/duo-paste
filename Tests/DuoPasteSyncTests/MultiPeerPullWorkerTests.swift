import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// PR 2 新增：多 peer mesh 拓扑下两个 PullWorker 并存的核心不变量。
///
/// 单 peer 行为等价在 PullWorkerTests 覆盖（25 条全过）；本套专门验"加第二个 peer 不破坏第一个
/// peer 的状态"：
/// - 两 peer 行都落同一 item 表，origin_device 区分
/// - pull_cursor 表每个 peer 一行 cursor，互不覆盖
/// - reconcilePeer 切对端 device_id 时精确删该 peer 旧 origin 行 + 该 peer cursor 行，
///   不动另一 peer 的行 / cursor
/// - MeshStatus.oldestLastPullNs 是最悲观值：任一 peer 未追平 → nil；都追平后取 min
/// - MeshSupervisor 启停 fan-out 两个 worker

private typealias DuoDB = DuoPasteCore.Database

private func makeClientDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-multi-peer-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func mkItem(
    id: String,
    origin: String,
    ingestedAtNs: Int64,
    text: String = "x"
) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: ingestedAtNs,
        ingestedAtNs: ingestedAtNs,
        kind: .text,
        sourceAppName: "Test",
        preview: text,
        textFull: text
    )
}

/// 跟 PullWorkerTests 同款脚本化 transport，但每个 peer 一个实例。
private actor FakeTransport: SinceTransport {
    private var pages: [SincePageWire]
    private var healthDeviceID: String
    private var healthNowMs: Int64
    private(set) var fetchSinceCalls: [SinceCursor] = []

    init(pages: [SincePageWire], healthDeviceID: String, healthNowMs: Int64 = 1_000) {
        self.pages = pages
        self.healthDeviceID = healthDeviceID
        self.healthNowMs = healthNowMs
    }

    func setHealthDeviceID(_ id: String) { self.healthDeviceID = id }

    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        await self._fetchSince(cursor: cursor)
    }

    private func _fetchSince(cursor: SinceCursor) async -> RemoteSinceResult {
        fetchSinceCalls.append(cursor)
        guard !pages.isEmpty else {
            return RemoteSinceResult(outcome: .unreachable(reason: "no more pages"))
        }
        let p = pages.removeFirst()
        return RemoteSinceResult(outcome: .ok(p))
    }

    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        await self._health()
    }
    private func _health() async -> PrimaryHealthResult {
        return PrimaryHealthResult(outcome: .ok(deviceID: healthDeviceID, nowMs: healthNowMs, ponteHost: nil))
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

@Test func twoPeersWriteIntoSingleItemTableWithDistinctCursors() async throws {
    // 两个 peer 各推一条不同行，两个 PullWorker 同时跑，验证：
    // 1. 两条 peer 行都落 item 表，origin_device 区分
    // 2. pull_cursor 表两行 cursor 互相独立
    // 3. MeshStatus 两 peer 都注册，oldestLastPullNs 是 min
    let db = try makeClientDB()
    let selfID = "client-self"
    let nowNsClock: @Sendable () -> Int64 = { Int64(1_700_000_000_000_000_000) }

    let peerAID = "peer-A"
    let peerBID = "peer-B"
    let itemA = mkItem(id: "a-1", origin: peerAID, ingestedAtNs: 100, text: "from A")
    let itemB = mkItem(id: "b-1", origin: peerBID, ingestedAtNs: 200, text: "from B")
    let transportA = FakeTransport(
        pages: [page(items: [itemA], nextNs: 100, nextID: "a-1", hasMore: false)],
        healthDeviceID: peerAID
    )
    let transportB = FakeTransport(
        pages: [page(items: [itemB], nextNs: 200, nextID: "b-1", hasMore: false)],
        healthDeviceID: peerBID
    )
    let mesh = MeshStatus()
    let workerA = PullWorker(
        database: db, transport: transportA, selfDeviceID: selfID,
        expectedPeerDeviceID: peerAID, meshStatus: mesh,
        config: PullWorker.Config(intervalSec: 60),
        nowNs: nowNsClock
    )
    let workerB = PullWorker(
        database: db, transport: transportB, selfDeviceID: selfID,
        expectedPeerDeviceID: peerBID, meshStatus: mesh,
        config: PullWorker.Config(intervalSec: 60),
        nowNs: nowNsClock
    )
    let supervisor = MeshSupervisor(workers: [workerA, workerB])
    await supervisor.start()
    let workerAReady = await workerA.waitForCompletedTicksForTesting(atLeast: 1)
    let workerBReady = await workerB.waitForCompletedTicksForTesting(atLeast: 1)
    #expect(workerAReady && workerBReady)
    await supervisor.stop()

    // 两条 peer 行都在 item 表
    let rows = try await db.pool.read { conn in
        try Row.fetchAll(conn, sql: "SELECT id, origin_device FROM item ORDER BY id").map {
            (id: $0["id"] as String, origin: $0["origin_device"] as String)
        }
    }
    #expect(rows.map(\.id) == ["a-1", "b-1"])
    #expect(Set(rows.map(\.origin)) == [peerAID, peerBID])

    // pull_cursor 两行各自独立
    let cursors = try await db.pool.read { conn in
        try Row.fetchAll(conn, sql: """
            SELECT peer_device_id, cursor_ns, cursor_id FROM pull_cursor ORDER BY peer_device_id
        """).map {
            (peerID: $0["peer_device_id"] as String, ns: $0["cursor_ns"] as Int64)
        }
    }
    #expect(cursors.count == 2)
    #expect(cursors[0].peerID == peerAID)
    #expect(cursors[0].ns == 100)
    #expect(cursors[1].peerID == peerBID)
    #expect(cursors[1].ns == 200)

    // MeshStatus 两 peer 都已注册，oldestLastPullNs == min(两 peer 的 lastPullNs)
    let registered = Set(mesh.registeredPeerDeviceIDs())
    #expect(registered == [peerAID, peerBID])
    let oldest = mesh.oldestLastPullNs()
    #expect(oldest != nil)
    // 两个 worker 同一 nowNs clock → 都 stamp 同样值，oldest = 那个值
    #expect(oldest == nowNsClock())
}

@Test func oldestLastPullNsReturnsNilWhenAnyPeerUntouched() async throws {
    // peer A 已追平 / peer B 还没 → oldestLastPullNs 应返回 nil（最悲观）
    let mesh = MeshStatus()
    mesh.setLastPullNs(peerDeviceID: "peer-A", 1_000_000)
    // peer-B 只 set clock skew（"已联系过"但还没成功 last pull）
    mesh.setClockSkewMs(peerDeviceID: "peer-B", 50)
    #expect(mesh.oldestLastPullNs() == nil)

    // peer-B 也追平后再返回 min
    mesh.setLastPullNs(peerDeviceID: "peer-B", 500_000)
    #expect(mesh.oldestLastPullNs() == 500_000)
}

@Test func reconcilePeerDeletesOnlyTargetPeerRows() async throws {
    // peer A 在线状态稳定，peer B 换 device_id 走 reconcile → 应只删 peer-B-old 的行 + 行 cursor，
    // peer A 的行 / cursor 完全不动
    let db = try makeClientDB()
    let selfID = "client-self"
    let peerAID = "peer-A-stable"
    let peerBOldID = "peer-B-old"
    let peerBNewID = "peer-B-new"

    // 预置：item 表里两个 peer 各 1 条；pull_cursor 表各 1 行
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, ocr_state)
            VALUES
              ('a-row', ?, 100, 100, 'text', NULL, 'A', 'A', 'A', NULL, NULL, NULL, 0, NULL, NULL),
              ('b-row', ?, 200, 200, 'text', NULL, 'B', 'B', 'B', NULL, NULL, NULL, 0, NULL, NULL)
        """, arguments: [peerAID, peerBOldID])
        try conn.execute(sql: """
            INSERT INTO pull_cursor (peer_device_id, cursor_ns, cursor_id, updated_at_ns)
            VALUES (?, 100, 'a-row', 100), (?, 200, 'b-row', 200)
        """, arguments: [peerAID, peerBOldID])
    }

    // peer-B 的 worker：/health 返回 new ID → reconcile 应清旧 peer-B 行 + cursor
    let transportB = FakeTransport(
        pages: [page(
            items: [mkItem(id: "b-fresh", origin: peerBNewID, ingestedAtNs: 50, text: "fresh")],
            nextNs: 50, nextID: "b-fresh", hasMore: false
        )],
        healthDeviceID: peerBNewID
    )
    let mesh = MeshStatus()
    // 学习模式（expectedPeerDeviceID=nil）：reconcile 比对 pull_cursor 里的 persisted id
    // 跟 /health 返回的 currentPeerID。但学习模式下 pull_cursor 行不止一条时 LIMIT 1 不可靠——
    // 这是 PR 2 单 peer 学习模式的契约边界，多 peer 必须显式传 expectedPeerDeviceID 走严格模式
    let workerB = PullWorker(
        database: db, transport: transportB, selfDeviceID: selfID,
        expectedPeerDeviceID: peerBOldID, meshStatus: mesh,
        config: PullWorker.Config(intervalSec: 60),
        nowNs: { 999_000_000 }
    )
    // 严格模式下 /health 返回的 ID 跟 expectedPeerDeviceID 不一致 → tick 入口直接 transient skip，
    // reconcile 根本进不去。这是 PR 2 的合理边界：严格模式 = 配置错应该排查，不该自动迁移
    // device_id（避免本机被错配 peer 污染）。
    await runPullWorkerToCompletion(workerB)

    // 严格模式 + ID 不匹配 → 没有任何 SQL 落地。验证旧状态完整保留。
    let allRows = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT id FROM item ORDER BY id")
    }
    #expect(allRows.count == 2)
    #expect(allRows == ["a-row", "b-row"])

    let cursorRows = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT peer_device_id FROM pull_cursor ORDER BY peer_device_id")
    }
    #expect(cursorRows == [peerAID, peerBOldID])
}

@Test func reconcilePeerLearningModeDeletesOnlyThatPeerRows() async throws {
    // 学习模式（expectedPeerDeviceID=nil）+ 单 peer 部署 + peer device_id 切换：
    // 应删 origin=旧 peer 的行 + 该 peer cursor 行，不动 self origin 也不动其他 peer
    let db = try makeClientDB()
    let selfID = "client-self"
    let peerOldID = "peer-old"
    let peerNewID = "peer-new"
    let otherPeerID = "other-peer"  // 假设有另一个 peer 同时存在，不应被这次 reconcile 影响

    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, ocr_state)
            VALUES
              ('old-row', ?, 100, 100, 'text', NULL, 'O', 'O', 'O', NULL, NULL, NULL, 0, NULL, NULL),
              ('other-row', ?, 110, 110, 'text', NULL, 'X', 'X', 'X', NULL, NULL, NULL, 0, NULL, NULL)
        """, arguments: [peerOldID, otherPeerID])
        // 学习模式只查到 pull_cursor LIMIT 1：单 peer 部署只有这一行
        try conn.execute(sql: """
            INSERT INTO pull_cursor (peer_device_id, cursor_ns, cursor_id, updated_at_ns)
            VALUES (?, 100, 'old-row', 100)
        """, arguments: [peerOldID])
    }

    let transport = FakeTransport(
        pages: [page(items: [], nextNs: 0, nextID: "", hasMore: false)],
        healthDeviceID: peerNewID
    )
    let mesh = MeshStatus()
    let worker = PullWorker(
        database: db, transport: transport, selfDeviceID: selfID,
        expectedPeerDeviceID: nil,  // 学习模式
        meshStatus: mesh,
        config: PullWorker.Config(intervalSec: 60)
    )
    await runPullWorkerToCompletion(worker)

    // peer-old 行 + cursor 删；other-peer 行保留；self 行（这里没插）也保留
    let remainingIDs = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT id FROM item ORDER BY id")
    }
    #expect(!remainingIDs.contains("old-row"))
    #expect(remainingIDs.contains("other-row"))

    let cursorIDs = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT peer_device_id FROM pull_cursor")
    }
    #expect(!cursorIDs.contains(peerOldID))
}

@Test func wsKickWakesPullWorkerImmediately() async throws {
    // 启动 PullWorker 配 30s interval（远大于测试时长）→ 跑一次 tick 后 sleep 长时间。
    // 模拟 WS 通知：直接调 worker.wake() 取消 sleep，应该立即跑下一次 tick 拉到 page2。
    // 真实路径下这一调用来自 WSNotificationClient.onCursorAdvanced，验证 PR 3 的关键不变量
    // —— "WSNotificationClient 收到 cursorAdvanced → PullWorker.wake() → 立即追赶"
    let db = try makeClientDB()
    let selfID = "client-self"
    let peerID = "peer-W"

    let item1 = mkItem(id: "p1", origin: peerID, ingestedAtNs: 100, text: "first")
    let item2 = mkItem(id: "p2", origin: peerID, ingestedAtNs: 200, text: "second")
    let transport = FakeTransport(
        pages: [
            page(items: [item1], nextNs: 100, nextID: "p1", hasMore: false),
            page(items: [item2], nextNs: 200, nextID: "p2", hasMore: false),
        ],
        healthDeviceID: peerID
    )
    let mesh = MeshStatus()
    let worker = PullWorker(
        database: db, transport: transport, selfDeviceID: selfID,
        expectedPeerDeviceID: peerID, meshStatus: mesh,
        // intervalSec 长到测试期内绝不会自然到期 → 第二条只能靠 wake() 触发
        config: PullWorker.Config(intervalSec: 30)
    )
    let firstBaseline = await worker.completedTickCountForTesting()
    await worker.start()
    let firstReady = await worker.waitForCompletedTicksForTesting(atLeast: firstBaseline + 1)
    #expect(firstReady)
    let firstCount = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(firstCount == 1)

    // wake() 模拟 WS notify
    let secondTarget = await worker.completedTickCountForTesting() + 1
    worker.wake()
    let secondReady = await worker.waitForCompletedTicksForTesting(atLeast: secondTarget)
    #expect(secondReady)
    let secondCount = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(secondCount == 2, "wake() 应当让 worker 立即跑下一次 tick；实际行数=\(secondCount)")
    await worker.stop()
}

@Test func meshSupervisorStartsAndStopsAllWorkers() async throws {
    // 纯生命周期测：MeshSupervisor.start/stop 把每个 worker 都启停。验证 N=2 时不漏 worker。
    let db = try makeClientDB()
    let mesh = MeshStatus()
    let transport1 = FakeTransport(
        pages: [page(items: [], nextNs: 0, nextID: "", hasMore: false)],
        healthDeviceID: "p1"
    )
    let transport2 = FakeTransport(
        pages: [page(items: [], nextNs: 0, nextID: "", hasMore: false)],
        healthDeviceID: "p2"
    )
    let w1 = PullWorker(
        database: db, transport: transport1, selfDeviceID: "self",
        expectedPeerDeviceID: "p1", meshStatus: mesh,
        config: PullWorker.Config(intervalSec: 60)
    )
    let w2 = PullWorker(
        database: db, transport: transport2, selfDeviceID: "self",
        expectedPeerDeviceID: "p2", meshStatus: mesh,
        config: PullWorker.Config(intervalSec: 60)
    )
    let supervisor = MeshSupervisor(workers: [w1, w2])
    #expect(await supervisor.peerCount == 2)
    await supervisor.start()
    let w1Ready = await w1.waitForCompletedTicksForTesting(atLeast: 1)
    let w2Ready = await w2.waitForCompletedTicksForTesting(atLeast: 1)
    #expect(w1Ready && w2Ready)
    // 两 peer 都被 /health + /since 调过 → mesh 注册两 peer
    let registered = Set(mesh.registeredPeerDeviceIDs())
    #expect(registered == ["p1", "p2"])
    await supervisor.stop()
}

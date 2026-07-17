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
    return try DuoDB(path: paths.mainDB)
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
        deletedAtNs: deletedAtNs
    )
}

/// Fake SinceTransport with scriptable responses.
/// 串行 pop 直到 `pages` 空，之后所有调用回 unreachable（"no more scripted pages"）。
/// /health 调用单独计数 + 可配返回值。
private actor FakeSinceTransport: SinceTransport {
    private var pages: [SincePageWire]
    private var healthDeviceID: String
    private var healthNowMs: Int64
    private(set) var fetchSinceCalls: [(SinceCursor, Int)] = []
    private(set) var healthCalls: Int = 0

    init(pages: [SincePageWire], healthDeviceID: String, healthNowMs: Int64 = 1_000) {
        self.pages = pages
        self.healthDeviceID = healthDeviceID
        self.healthNowMs = healthNowMs
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
    let status = MeshStatus()
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "client-self",
        meshStatus: status,
        config: PullWorker.Config(intervalSec: 60),
        nowNs: { 999 }
    )
    await runPullWorkerToCompletion(worker)

    let mirrored = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT id FROM item ORDER BY id")
    }
    #expect(mirrored == ["p-1", "p-2"])
    let cur = try await db.pool.read { conn in
        try Row.fetchOne(conn, sql: "SELECT cursor_ns, cursor_id, peer_device_id FROM pull_cursor").map {
            (ns: $0["cursor_ns"] as Int64,
             id: $0["cursor_id"] as String,
             peerID: $0["peer_device_id"] as String)
        }
    }
    #expect(cur?.ns == 200)
    #expect(cur?.id == "p-2")
    #expect(cur?.peerID == "primary-device")
    // lastPullNs 应该被标 —— 完整追平（hasMore=false）
    // 学习模式下 PullWorker 用 /health 学到的 peer device_id 当 MeshStatus key，
    // oldestLastPullNs == 单 peer 的 lastPullNs（PR 2 单 peer 部署等价语义）
    #expect(status.oldestLastPullNs() == 999)
}

@Test func pullWorkerSkipsOwnOriginRows() async throws {
    // origin == selfDeviceID 的条目不应该入表（避免和本机 own 行重复）
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
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runPullWorkerToCompletion(worker)

    let mirrored = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT id FROM item")
    }
    #expect(mirrored == ["primary-row"])
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
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runPullWorkerToCompletion(worker, ticks: 2)

    let mirrored = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT id FROM item ORDER BY id")
    }
    #expect(mirrored == ["a", "b"])
    let calls = await transport.fetchSinceCalls
    // 至少两次 since 调用，第二次 cursor 应该是 (10, "a")
    #expect(calls.count >= 2)
    #expect(calls[1].0.ingestedAtNs == 10)
    #expect(calls[1].0.id == "a")
}

@Test func pullWorkerResetsMirrorWhenPrimaryDeviceChanges() async throws {
    let db = try makeClientDB()
    // 预先放一些"旧 peer" 留下的 peer 行 + cursor。v7 合表后 peer 行直接落 item 表，
    // push_state='acked' 维持 PullWorker INSERT 路径兼容。
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, ocr_state)
            VALUES ('stale-1', 'old-primary', 100, 100, 'text', NULL, 'old', 'old', 'old', NULL, NULL, NULL, 0, NULL, NULL)
        """)
        try conn.execute(sql: """
            INSERT INTO pull_cursor (peer_device_id, cursor_ns, cursor_id, updated_at_ns)
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
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runPullWorkerToCompletion(worker)

    let ids = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT id FROM item ORDER BY id")
    }
    #expect(ids == ["fresh"])  // 旧的 stale-1 应已被清掉
    let row = try await db.pool.read { conn in
        try Row.fetchOne(conn, sql: "SELECT peer_device_id, cursor_ns, cursor_id FROM pull_cursor").map {
            (peerID: $0["peer_device_id"] as String,
             ns: $0["cursor_ns"] as Int64,
             id: $0["cursor_id"] as String)
        }
    }
    #expect(row?.peerID == "new-primary")
    #expect(row?.ns == 50)
    #expect(row?.id == "fresh")
    // /since 第一次调用 cursor 应该是 .zero（重置后从头拉）
    let calls = await transport.fetchSinceCalls
    #expect(calls.first?.0 == SinceCursor.zero)
}

@Test func pullWorkerSkipsCrossDeviceContinuityDuplicate() async throws {
    // 场景：mbp = client 复制内容 X 后通过 macOS Universal Clipboard，mini = primary 也
    // 独立 capture 了一份。primary push /since 把 mini 的 X 推给 mbp 时，mbp PullWorker
    // 应该发现"本机 origin=self 同内容已存（窗口内）"→ skip 不写 mirror。
    let db = try makeClientDB()
    let selfID = "mbp-self"
    let baseline: Int64 = 1_700_000_000_000_000_000
    // mbp 自己 capture 了一条 (origin=mbp, capturedAt=baseline)
    try await db.pool.write { conn in
        let own = Item(
            id: "own-1", originDevice: selfID,
            capturedAtNs: baseline, ingestedAtNs: nil,  // client 自家 capture，ingested_at_ns 还没打
            kind: .text, preview: "shared text", textFull: "shared text"
        )
        try own.insert(conn)
    }
    // primary 那边也 capture 了一份（origin=mini, capturedAt baseline+100ms），通过 /since 推过来
    let mirrorItem = mkItem(
        id: "mini-side", origin: "mini-primary",
        ingestedAtNs: baseline + 100_000_000, text: "shared text"
    )
    // 重要：mkItem 默认让 capturedAtNs = ingestedAtNs，所以 mirrorItem.capturedAtNs = baseline+100ms
    // 跟 own 的 capturedAt 差 100ms < 5s 窗口 → 应被 dedup
    let transport = FakeSinceTransport(
        pages: [page(items: [mirrorItem], nextNs: baseline + 100_000_000, nextID: "mini-side", hasMore: false)],
        healthDeviceID: "mini-primary"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60, crossDeviceDedupWindowNs: 5_000_000_000)
    )
    await runPullWorkerToCompletion(worker)

    // v7 合表后 item 表里既有 own 行也有 peer 行。dedup 命中 = peer 行不应入表。
    // 验证 origin != self 的 peer 行数 == 0
    let peerRowCount = try await db.pool.read { conn in
        try Int.fetchOne(
            conn,
            sql: "SELECT COUNT(*) FROM item WHERE origin_device != ?",
            arguments: [selfID]
        ) ?? -1
    }
    #expect(peerRowCount == 0)
    // own 那条还在
    let ownStill = try await db.pool.read { conn in
        try Item.filter(Column("id") == "own-1").fetchOne(conn)
    }
    #expect(ownStill != nil)
}

@Test func pullWorkerSkipsPasteEchoViaSuppressionSet() async throws {
    // 场景：本机 pasteBack "shared text" 后通过 macOS Universal Clipboard 反弹到对端，
    // 对端 watcher capture 后 push 回来。本机没有 own item（paste 不写 own）→
    // crossDeviceDedup 的 own-item dedup 找不到锚点，必须靠 PasteSuppressionSet 拦截。
    let db = try makeClientDB()
    let selfID = "mbp-self"
    let baseline: Int64 = 1_700_000_000_000_000_000
    let echoed = mkItem(
        id: "mini-echo", origin: "mini-primary",
        ingestedAtNs: baseline + 1_000_000_000,   // echo: capturedAt 比 record 晚 1s
        text: "shared text"
    )
    let transport = FakeSinceTransport(
        pages: [page(items: [echoed], nextNs: baseline + 1_000_000_000, nextID: "mini-echo", hasMore: false)],
        healthDeviceID: "mini-primary"
    )
    // 注入固定 nowNs = baseline，让 suppression record 的锚点正好在 baseline
    let suppressions = PasteSuppressionSet(nowNs: { baseline })
    // 模拟 pasteBack：把 "shared text" 指纹塞进 set
    suppressions.record(
        fingerprint: PasteSuppressionSet.fingerprint(text: "shared text"),
        ttlSec: 60
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        pasteSuppressions: suppressions,
        // crossDeviceDedupWindowNs=0：明确排除 own-item dedup 路径，保证测的是 paste-echo 拦截
        config: PullWorker.Config(intervalSec: 60, crossDeviceDedupWindowNs: 0)
    )
    await runPullWorkerToCompletion(worker)

    let mirrorCount = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(mirrorCount == 0)
}

@Test func pullWorkerCatchUpDoesNotSuppressHistoricalRowSameContent() async throws {
    // P2 review 回归：client 离线一段时间后 catch-up，恰好 paste 了一个常见短串 X，
    // /since 拉到一条**历史**的同内容 X 行（captured_at_ns 远早于 paste record）。
    // 之前 suppression 只看 fp → 误杀历史行 + cursor 仍前进 → 那条行永远拉不回来。
    // 修复后：suppression 要求 candidate.capturedAtNs >= recordedAtNs - skew，
    // 历史行不满足 → 正常写 mirror。
    let db = try makeClientDB()
    let selfID = "mbp-self"
    let pasteRecordNs: Int64 = 1_780_000_000_000_000_000   // 用户 paste 时刻
    let historicalCapturedNs = pasteRecordNs - 7 * 24 * 3600 * 1_000_000_000  // 一周前
    let historicalItem = Item(
        id: "old-row", originDevice: "mini-primary",
        capturedAtNs: historicalCapturedNs,
        ingestedAtNs: historicalCapturedNs + 1_000_000,
        kind: .text, preview: "ok", textFull: "ok"
    )
    let transport = FakeSinceTransport(
        pages: [page(
            items: [historicalItem],
            nextNs: historicalCapturedNs + 1_000_000,
            nextID: "old-row",
            hasMore: false
        )],
        healthDeviceID: "mini-primary"
    )
    let suppressions = PasteSuppressionSet(nowNs: { pasteRecordNs })
    suppressions.record(
        fingerprint: PasteSuppressionSet.fingerprint(text: "ok"),
        ttlSec: 300
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        pasteSuppressions: suppressions,
        config: PullWorker.Config(intervalSec: 60, crossDeviceDedupWindowNs: 0)
    )
    await runPullWorkerToCompletion(worker)

    // 历史行应该正常写入 mirror —— 不被 suppression 误杀
    let mirrorCount = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item WHERE id='old-row'") ?? -1
    }
    #expect(mirrorCount == 1)
}

@Test func pullWorkerPasteEchoDoesNotBlockAlreadyMirroredRowUpdate() async throws {
    // 回归：paste-echo 抑制只对**首次入表** 生效。若 item 表里 peer 行已有此 id
    // （race 中 mirror 先写、suppression 才 record；或 paste 同一历史项第二次），
    // 后续 state update（软删 / pin 变更）必须能盖上 mirror 行，不被 suppression 误挡。
    let db = try makeClientDB()
    let selfID = "mbp-self"
    let baseline: Int64 = 1_700_000_000_000_000_000

    // 预置 item 表里已有 (id="mini-echo", origin=mini-primary, "shared text") 一行
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, ocr_state)
            VALUES (?, 'mini-primary', ?, ?, 'text', NULL, NULL, 'shared text', 'shared text',
                    NULL, NULL, NULL, 0, NULL, NULL)
        """, arguments: ["mini-echo", baseline, baseline])
    }
    // primary 推过来一次软删（同 id，新 ingested_at_ns）
    let softDelete = Item(
        id: "mini-echo", originDevice: "mini-primary",
        capturedAtNs: baseline, ingestedAtNs: baseline + 1_000_000_000,
        kind: .text, preview: "shared text", textFull: "shared text",
        deletedAtNs: baseline + 1_000_000_000
    )
    let transport = FakeSinceTransport(
        pages: [page(items: [softDelete], nextNs: baseline + 1_000_000_000, nextID: "mini-echo", hasMore: false)],
        healthDeviceID: "mini-primary"
    )
    let suppressions = PasteSuppressionSet(nowNs: { baseline })
    // suppression 命中（模拟用户最近又 paste 了一次"shared text"）
    suppressions.record(
        fingerprint: PasteSuppressionSet.fingerprint(text: "shared text"),
        ttlSec: 60
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        pasteSuppressions: suppressions,
        config: PullWorker.Config(intervalSec: 60, crossDeviceDedupWindowNs: 0)
    )
    await runPullWorkerToCompletion(worker)

    // mirror 行应被软删盖上，不被 suppression 误挡
    let deletedAt: Int64? = try await db.pool.read { conn in
        try Int64.fetchOne(conn, sql: "SELECT deleted_at_ns FROM item WHERE id='mini-echo'")
    }
    #expect(deletedAt == baseline + 1_000_000_000)
}

@Test func pullWorkerWritesMirrorWhenNoOwnDuplicate() async throws {
    // 反向回归：本机 item 表里没有同内容时，mirror 行应正常写入（dedup 不能误伤）。
    let db = try makeClientDB()
    let selfID = "mbp-self"
    let baseline: Int64 = 1_700_000_000_000_000_000
    let mirrorItem = mkItem(
        id: "mini-only", origin: "mini-primary",
        ingestedAtNs: baseline, text: "unique remote content"
    )
    let transport = FakeSinceTransport(
        pages: [page(items: [mirrorItem], nextNs: baseline, nextID: "mini-only", hasMore: false)],
        healthDeviceID: "mini-primary"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60, crossDeviceDedupWindowNs: 5_000_000_000)
    )
    await runPullWorkerToCompletion(worker)

    let mirrorCount = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item WHERE id='mini-only'") ?? -1
    }
    #expect(mirrorCount == 1)
}

@Test func pullWorkerReplaysSoftDeleteOnAlreadyMirroredRowEvenWithOwnDup() async throws {
    // 回归 P2：dedup 只对首次入 mirror 生效。如果 mirror 表里已有此 id（race 时
    // own 表写晚了一拍，mirror 已收下副本），后续 primary 软删该行通过 /since 推
    // 过来时 dedup 不能再挡——必须让 INSERT OR REPLACE 把 deleted_at_ns 盖上，
    // 否则 mirror 表里的 stale row 永远不会被标软删，searchHits 继续返回。
    let db = try makeClientDB()
    let selfID = "mbp-self"
    let baseline: Int64 = 1_700_000_000_000_000_000

    // 模拟 race 已发生后的稳态：own + mirror 都有同内容 X
    try await db.pool.write { conn in
        let own = Item(
            id: "own-x", originDevice: selfID,
            capturedAtNs: baseline, ingestedAtNs: nil,
            kind: .text, preview: "stale text", textFull: "stale text"
        )
        try own.insert(conn)
        // item 表里也有这条 peer 行（已经入过，靠 fixture SQL 写入，避免被 dedup）
        try conn.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns, ocr_state)
            VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, NULL, NULL, NULL, 0, NULL, NULL)
        """, arguments: [
            "mini-x", "mini-primary", baseline + 100_000_000, baseline + 100_000_000, "text",
            "Test", "stale text", "stale text"
        ])
    }

    // primary 现在软删 mini-x，/since 回放（id 不变 + deleted_at_ns 非空）
    let softDeleted = Item(
        id: "mini-x", originDevice: "mini-primary",
        capturedAtNs: baseline + 100_000_000,
        ingestedAtNs: baseline + 200_000_000,
        kind: .text, sourceAppName: "Test",
        preview: "stale text", textFull: "stale text",
        deletedAtNs: 999_999_999    // primary 标了软删
    )
    let transport = FakeSinceTransport(
        pages: [page(items: [softDeleted], nextNs: baseline + 200_000_000, nextID: "mini-x", hasMore: false)],
        healthDeviceID: "mini-primary"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60, crossDeviceDedupWindowNs: 5_000_000_000)
    )
    await runPullWorkerToCompletion(worker)

    // mirror 表里 mini-x 的 deleted_at_ns 必须已被盖上，否则 stale 内容继续可搜
    let deletedAt = try await db.pool.read { conn in
        try Int64.fetchOne(conn, sql: "SELECT deleted_at_ns FROM item WHERE id='mini-x'")
    }
    #expect(deletedAt == 999_999_999)
}

@Test func pullWorkerWritesMirrorOutsideDedupWindow() async throws {
    // own 同内容存在但 capturedAt 超 5s 之外——是真正的"不同时刻"，不是 Continuity 副本。
    // mirror 应正常入库（用户能看到"我之前也复制过同样的"）。
    let db = try makeClientDB()
    let selfID = "mbp-self"
    let baseline: Int64 = 1_700_000_000_000_000_000
    try await db.pool.write { conn in
        let own = Item(
            id: "own-old", originDevice: selfID,
            capturedAtNs: baseline, ingestedAtNs: nil,
            kind: .text, preview: "same text", textFull: "same text"
        )
        try own.insert(conn)
    }
    let mirrorItem = mkItem(
        id: "mini-late", origin: "mini-primary",
        ingestedAtNs: baseline + 10_000_000_000,  // +10s
        text: "same text"
    )
    let transport = FakeSinceTransport(
        pages: [page(items: [mirrorItem], nextNs: baseline + 10_000_000_000, nextID: "mini-late", hasMore: false)],
        healthDeviceID: "mini-primary"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60, crossDeviceDedupWindowNs: 5_000_000_000)
    )
    await runPullWorkerToCompletion(worker)

    let mirrorCount = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item WHERE id='mini-late'") ?? -1
    }
    #expect(mirrorCount == 1)
}

@Test func pullWorkerHandlesSoftDeletedRows() async throws {
    // /since 含 deleted_at_ns 非空的行：mirror 应该写入（mirror 表也支持软删，
    // searchHits 的 fetchHitsMirror 会过滤掉）
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
        meshStatus: MeshStatus()
    )
    await runPullWorkerToCompletion(worker)

    let deletedAt = try await db.pool.read { conn -> Int64? in
        try Int64.fetchOne(conn, sql: "SELECT deleted_at_ns FROM item WHERE id='dead'")
    }
    #expect(deletedAt == 999)
}

@Test func pullWorkerRecordsClockSkewFromHealth() async throws {
    // /health 报 peer now_ms 比本机快 45s → MeshStatus.worstClockSkewMs() 应反映出来。
    // 用 nowNs 注入固定值让 skew 计算可预测：local = 1_000_000 ms，peer = 1_045_000 ms。
    let db = try makeClientDB()
    let primaryNowMs: Int64 = 1_045_000
    let localNowNs: Int64 = 1_000_000 * 1_000_000  // 1_000_000 ms in ns
    let transport = FakeSinceTransport(
        pages: [page(items: [], nextNs: 0, nextID: "", hasMore: false)],
        healthDeviceID: "primary",
        healthNowMs: primaryNowMs
    )
    let status = MeshStatus()
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "client-self",
        meshStatus: status,
        config: PullWorker.Config(intervalSec: 60, clockSkewWarnMs: 30_000),
        nowNs: { localNowNs }
    )
    await runPullWorkerToCompletion(worker)
    #expect(status.worstClockSkewMs() == 45_000)
}

@Test func pullWorkerRecordsNegativeClockSkew() async throws {
    // 反向：primary 比本机慢 60s。
    let db = try makeClientDB()
    let transport = FakeSinceTransport(
        pages: [page(items: [], nextNs: 0, nextID: "", hasMore: false)],
        healthDeviceID: "primary",
        healthNowMs: 940_000
    )
    let status = MeshStatus()
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "self",
        meshStatus: status,
        config: PullWorker.Config(intervalSec: 60),
        nowNs: { 1_000_000 * 1_000_000 }
    )
    await runPullWorkerToCompletion(worker)
    #expect(status.worstClockSkewMs() == -60_000)
}

@Test func pullWorkerHTTPEndToEnd() async throws {
    // 起 in-process primary server → client PullWorker 真打 HTTP → 验证 mirror 落行 + cursor
    let fixture = try TestSyncServerFixture(prefix: "duo-pull-e2e")
    let primaryDB = fixture.database  // role 不影响这里——直接 INSERT
    let primaryDeviceID = "primary-e2e"
    try await primaryDB.pool.write { conn in
        let it1 = Item(id: "a", originDevice: "other-mac", capturedAtNs: 100, ingestedAtNs: 100,
                       kind: .text, preview: "alpha", textFull: "alpha")
        let it2 = Item(id: "b", originDevice: "another-mac", capturedAtNs: 200, ingestedAtNs: 200,
                       kind: .text, preview: "bravo", textFull: "bravo")
        try it1.insert(conn)
        try it2.insert(conn)
    }
    let server = SyncServer(deviceID: primaryDeviceID, database: primaryDB, blobs: fixture.blobs,
                            host: "127.0.0.1", port: 0, auth: fixture.auth)
    let (ids, status) = try await fixture.withServer(server) { baseURL in
        let clientDB = try makeClientDB()
        let httpClient = HTTPPeerClient(baseURL: baseURL, auth: fixture.auth)
        let status = MeshStatus()
        let worker = PullWorker(
            database: clientDB,
            transport: httpClient,
            selfDeviceID: "client-self",
            meshStatus: status,
            config: PullWorker.Config(intervalSec: 60)
        )
        await runPullWorkerToCompletion(worker)
        let ids = try await clientDB.pool.read { conn in
            try String.fetchAll(conn, sql: "SELECT id FROM item ORDER BY id")
        }
        return (ids, status)
    }
    #expect(ids == ["a", "b"])
    // MeshStatus 学习模式：PullWorker 用 /health 学到的 peer device_id 注册状态
    #expect(status.registeredPeerDeviceIDs().contains(primaryDeviceID))
    #expect(status.oldestLastPullNs() != nil)
}

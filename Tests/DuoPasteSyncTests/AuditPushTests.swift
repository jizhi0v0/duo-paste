import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

private func makeClientDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-audit-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB, role: .client)
}

private func insertItem(
    _ db: DuoDB,
    id: String,
    origin: String,
    pushState: PushState,
    pushAttempts: Int = 0,
    lastError: String? = nil,
    capturedAtNs: Int64 = 100,
    textFull: String? = nil,
    kind: ItemKind = .text,
    blobSha256: String? = nil,
    pinned: Bool = false,
    deletedAtNs: Int64? = nil
) async throws {
    let text = textFull ?? id
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
               push_state, push_attempts, last_push_error)
            VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, NULL, NULL, ?, ?,
                    ?, ?, ?)
        """, arguments: [id, origin, capturedAtNs, capturedAtNs, kind.rawValue, id, text,
                         blobSha256, pinned ? 1 : 0, deletedAtNs,
                         pushState.rawValue, pushAttempts, lastError])
    }
}

/// 默认 capturedAtNs=100 跟 insertItem 对齐 —— 这样 id 同名行 state 对比时
/// capturedAtNs 自然相同，不会触发 stale。需要测 stale / dedup 的用例显式覆写。
private func pageOf(_ ids: [String], originDevice: String = "other", capturedAtNs: Int64 = 100) -> SincePageWire {
    let items = ids.map { id in
        Item(id: id, originDevice: originDevice,
             capturedAtNs: capturedAtNs, ingestedAtNs: capturedAtNs,
             kind: .text, preview: id, textFull: id,
             pushState: .acked)
    }
    return SincePageWire(
        ok: true, count: items.count, items: items,
        nextCursor: SinceCursor(ingestedAtNs: capturedAtNs, id: ids.last ?? ""),
        hasMore: false
    )
}

@Test func auditDetectsMissingOwnItemsOnPrimary() async throws {
    let db = try makeClientDB()
    let self_ = "mbp"
    try await insertItem(db, id: "own-1", origin: self_, pushState: .acked)
    try await insertItem(db, id: "own-2", origin: self_, pushState: .pending)
    try await insertItem(db, id: "own-3", origin: self_, pushState: .failed, pushAttempts: 5, lastError: "timeout")
    try await insertItem(db, id: "other-x", origin: "mini", pushState: .acked)  // 不该参与 audit

    // primary 只承认 own-1，own-2 / own-3 还没到达
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: self_,
        fetchPage: { _, _ in pageOf(["own-1"]) }
    )

    #expect(report.localOwnTotal == 3)
    #expect(report.acked == 1)
    #expect(report.pending == 1)
    #expect(report.failed == 1)
    #expect(report.primaryItemTotal == 1)
    #expect(report.missingTotal == 2)
    #expect(Set(report.missingOnPrimary) == Set(["own-2", "own-3"]))
    #expect(report.failedSamples.count == 1)
    #expect(report.failedSamples.first?.id == "own-3")
    #expect(report.failedSamples.first?.lastError == "timeout")
    #expect(report.failedSamples.first?.attempts == 5)
    // own-2/own-3 是 pending/failed，不走 dedup 吸收路径（只有 acked 才允许）。stale 也无（同 id 本地状态匹配）
    #expect(report.dedupAbsorbed == 0)
    #expect(report.staleTotal == 0)
}

@Test func auditCleanWhenAllAcked() async throws {
    let db = try makeClientDB()
    try await insertItem(db, id: "a", origin: "self", pushState: .acked)
    try await insertItem(db, id: "b", origin: "self", pushState: .acked)

    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "self",
        fetchPage: { _, _ in pageOf(["a", "b", "extra-from-primary"]) }
    )
    #expect(report.missingTotal == 0)
    #expect(report.failed == 0)
    #expect(report.pending == 0)
    #expect(report.acked == 2)
    #expect(report.primaryItemTotal == 3)
    #expect(report.dedupAbsorbed == 0)
    #expect(report.staleTotal == 0)
}

@Test func auditFollowsPaginationUntilHasMoreFalse() async throws {
    let db = try makeClientDB()
    try await insertItem(db, id: "p1", origin: "s", pushState: .acked)
    try await insertItem(db, id: "p2", origin: "s", pushState: .acked)
    try await insertItem(db, id: "p3", origin: "s", pushState: .acked)

    // 三页 /since，cursor 严格推进，模拟真实 server 行为。capturedAtNs 用 100 匹配 insertItem 默认，
    // 否则会触发 stale state 检测干扰 missing 断言
    actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
    let counter = Counter()
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "s",
        fetchPage: { _, _ in
            let n = await counter.next()
            switch n {
            case 1:
                return SincePageWire(ok: true, count: 1,
                    items: [Item(id: "p1", originDevice: "s", capturedAtNs: 100, ingestedAtNs: 1,
                                 kind: .text, preview: "p1", textFull: "p1", pushState: .acked)],
                    nextCursor: SinceCursor(ingestedAtNs: 1, id: "p1"), hasMore: true)
            case 2:
                return SincePageWire(ok: true, count: 1,
                    items: [Item(id: "p2", originDevice: "s", capturedAtNs: 100, ingestedAtNs: 2,
                                 kind: .text, preview: "p2", textFull: "p2", pushState: .acked)],
                    nextCursor: SinceCursor(ingestedAtNs: 2, id: "p2"), hasMore: true)
            default:
                return SincePageWire(ok: true, count: 1,
                    items: [Item(id: "p3", originDevice: "s", capturedAtNs: 100, ingestedAtNs: 3,
                                 kind: .text, preview: "p3", textFull: "p3", pushState: .acked)],
                    nextCursor: SinceCursor(ingestedAtNs: 3, id: "p3"), hasMore: false)
            }
        }
    )
    #expect(report.primaryItemTotal == 3)
    #expect(report.missingTotal == 0)
}

@Test func auditAbortsOnStuckCursor() async throws {
    // server bug 模拟：hasMore=true 但 cursor 不推进 → 应该报 pageLoopGuard，不能死循环
    let db = try makeClientDB()
    try await insertItem(db, id: "a", origin: "s", pushState: .acked)
    let stuck = SincePageWire(
        ok: true, count: 0, items: [],
        nextCursor: SinceCursor.zero, hasMore: true
    )
    await #expect(throws: AuditPush.AuditError.self) {
        _ = try await AuditPush.run(
            database: db,
            selfDeviceID: "s",
            fetchPage: { _, _ in stuck }
        )
    }
}

@Test func auditTruncatesSamplesAtLimit() async throws {
    let db = try makeClientDB()
    for i in 0..<10 {
        try await insertItem(db, id: "m-\(i)", origin: "self", pushState: .pending)
    }
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "self",
        fetchPage: { _, _ in pageOf([]) },
        sampleLimit: 3
    )
    #expect(report.missingTotal == 10)
    #expect(report.missingOnPrimary.count == 3)
}

// MARK: - P2 修正（PR#4 review）

@Test func auditTreatsCrossOriginContinuityDedupAsAbsorbedNotMissing() async throws {
    // 场景：MBP capture 一条文本 "hello"，push 到 primary。primary 之前 2s 自己也 capture 过
    // "hello"，RemoteIngester 走 Continuity dedup 路径 ACK 但**不**插入 MBP 的 id。
    // MBP 把这行标 acked。audit 应识别为 dedupAbsorbed，不计 missing。
    let db = try makeClientDB()
    try await insertItem(db, id: "mbp-abc", origin: "mbp", pushState: .acked,
                         capturedAtNs: 10_000_000_000, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "mbp",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "mini-xyz", originDevice: "mini",
                             capturedAtNs: 8_000_000_000, ingestedAtNs: 8_000_000_000,
                             kind: .text, preview: "hello", textFull: "hello", pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 8_000_000_000, id: "mini-xyz"),
                hasMore: false
            )
        }
    )
    #expect(report.missingTotal == 0)
    #expect(report.dedupAbsorbed == 1)
    #expect(report.dedupAbsorbedSamples.first?.localID == "mbp-abc")
    #expect(report.dedupAbsorbedSamples.first?.absorbedByID == "mini-xyz")
}

@Test func auditSplitsAbsorbedBySoftDeleteState() async throws {
    // 吸收源在 primary 是软删 → 归入 dedupAbsorbedThenDeleted，不混入 dedupAbsorbed 主计数。
    // 同时另一条吸收源活着 → 归 dedupAbsorbed。两桶不重叠
    let db = try makeClientDB()
    try await insertItem(db, id: "mbp-alive", origin: "mbp", pushState: .acked,
                         capturedAtNs: 10_000_000_000, textFull: "alive")
    try await insertItem(db, id: "mbp-tomb", origin: "mbp", pushState: .acked,
                         capturedAtNs: 10_000_000_000, textFull: "tomb")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "mbp",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 2,
                items: [
                    Item(id: "mini-alive", originDevice: "mini",
                         capturedAtNs: 8_000_000_000, ingestedAtNs: 8_000_000_000,
                         kind: .text, preview: "alive", textFull: "alive",
                         deletedAtNs: nil, pushState: .acked),
                    Item(id: "mini-tomb", originDevice: "mini",
                         capturedAtNs: 8_000_000_000, ingestedAtNs: 8_000_000_000,
                         kind: .text, preview: "tomb", textFull: "tomb",
                         deletedAtNs: 9_500_000_000, pushState: .acked),
                ],
                nextCursor: SinceCursor(ingestedAtNs: 8_000_000_000, id: "mini-tomb"),
                hasMore: false
            )
        }
    )
    #expect(report.missingTotal == 0)
    #expect(report.dedupAbsorbed == 1)
    #expect(report.dedupAbsorbedSamples.first?.localID == "mbp-alive")
    #expect(report.dedupAbsorbedSamples.first?.absorbedByID == "mini-alive")
    #expect(report.dedupAbsorbedThenDeleted == 1)
    #expect(report.dedupAbsorbedThenDeletedSamples.first?.localID == "mbp-tomb")
    #expect(report.dedupAbsorbedThenDeletedSamples.first?.absorbedByID == "mini-tomb")
}

@Test func auditDoesNotTreatSameOriginContentMatchAsAbsorbed() async throws {
    // 反例：primary 有同内容但 origin == 本机 selfDeviceID（不可能是 Continuity dedup 触发的，
    // 那条路径只对跨设备本地行有效）。audit 应保守报 missing 而不是误判为 absorbed。
    let db = try makeClientDB()
    try await insertItem(db, id: "mbp-abc", origin: "mbp", pushState: .acked,
                         capturedAtNs: 10_000_000_000, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "mbp",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "mbp-other", originDevice: "mbp",
                             capturedAtNs: 9_000_000_000, ingestedAtNs: 9_000_000_000,
                             kind: .text, preview: "hello", textFull: "hello", pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 9_000_000_000, id: "mbp-other"),
                hasMore: false
            )
        }
    )
    #expect(report.missingTotal == 1)
    #expect(report.dedupAbsorbed == 0)
}

@Test func auditDoesNotAbsorbWhenContentMatchOutsideWindow() async throws {
    // primary 有同内容但 capturedAt 距本地行 > 默认 5s 窗口 → 不算 Continuity 吸收。
    // 区别一条 "数据真丢失了" vs "时机巧合内容重叠"
    let db = try makeClientDB()
    try await insertItem(db, id: "mbp-abc", origin: "mbp", pushState: .acked,
                         capturedAtNs: 20_000_000_000, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "mbp",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "mini-old", originDevice: "mini",
                             capturedAtNs: 1_000_000_000, ingestedAtNs: 1_000_000_000,
                             kind: .text, preview: "hello", textFull: "hello", pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 1_000_000_000, id: "mini-old"),
                hasMore: false
            )
        }
    )
    #expect(report.missingTotal == 1)
    #expect(report.dedupAbsorbed == 0)
}

@Test func auditDoesNotAbsorbPendingOrFailedRows() async throws {
    // 即使内容能匹配，pending/failed 也不能算 dedup 吸收——这些是真的没推到 primary。
    // 只有 acked 才走得到 RemoteIngester 的 ACK 路径
    let db = try makeClientDB()
    try await insertItem(db, id: "p1", origin: "mbp", pushState: .pending,
                         capturedAtNs: 10_000_000_000, textFull: "hello")
    try await insertItem(db, id: "f1", origin: "mbp", pushState: .failed,
                         capturedAtNs: 10_000_000_000, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "mbp",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "mini-x", originDevice: "mini",
                             capturedAtNs: 9_500_000_000, ingestedAtNs: 9_500_000_000,
                             kind: .text, preview: "hello", textFull: "hello", pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 9_500_000_000, id: "mini-x"),
                hasMore: false
            )
        }
    )
    #expect(report.missingTotal == 2)
    #expect(Set(report.missingOnPrimary) == Set(["p1", "f1"]))
    #expect(report.dedupAbsorbed == 0)
}

@Test func auditDetectsStalePinnedOnSameID() async throws {
    // 本地 pin 了，PushWorker 重 push 但 RemoteIngester 见同 id 直接 ACK 不更新。primary 仍是 unpinned。
    // 同 id 比对必须发现 pinned 不一致 → stale
    let db = try makeClientDB()
    try await insertItem(db, id: "x", origin: "mbp", pushState: .acked,
                         pinned: true)
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "mbp",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "x", originDevice: "mbp",
                             capturedAtNs: 100, ingestedAtNs: 100,
                             kind: .text, preview: "x", textFull: "x",
                             pinned: false, pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 100, id: "x"),
                hasMore: false
            )
        }
    )
    #expect(report.missingTotal == 0)
    #expect(report.staleTotal == 1)
    #expect(report.staleSamples.first?.id == "x")
    #expect(report.staleSamples.first?.reasons.contains(where: { $0.contains("pinned") }) == true)
}

@Test func auditDetectsStaleSoftDeleteOnSameID() async throws {
    // 本地软删，primary 还是 alive。同 id 但 deletedAtNs diverge → stale
    let db = try makeClientDB()
    try await insertItem(db, id: "y", origin: "mbp", pushState: .acked,
                         deletedAtNs: 999)
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "mbp",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "y", originDevice: "mbp",
                             capturedAtNs: 100, ingestedAtNs: 100,
                             kind: .text, preview: "y", textFull: "y",
                             deletedAtNs: nil, pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 100, id: "y"),
                hasMore: false
            )
        }
    )
    #expect(report.staleTotal == 1)
    #expect(report.staleSamples.first?.reasons.contains(where: { $0.contains("deleted_at_ns") }) == true)
}

@Test func auditDetectsStaleCapturedAtBumpFromMerge() async throws {
    // 本地 merge 把 capturedAtNs 从 100 bump 到 500，但 RemoteIngester 见同 id 不更新。
    // primary 还停在 100，local > primary → stale
    let db = try makeClientDB()
    try await insertItem(db, id: "z", origin: "mbp", pushState: .acked,
                         capturedAtNs: 500)
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "mbp",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "z", originDevice: "mbp",
                             capturedAtNs: 100, ingestedAtNs: 100,
                             kind: .text, preview: "z", textFull: "z",
                             pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 100, id: "z"),
                hasMore: false
            )
        }
    )
    #expect(report.staleTotal == 1)
    #expect(report.staleSamples.first?.reasons.contains(where: { $0.contains("captured_at_ns") }) == true)
}

// MARK: - lineage-aware 吸收源过滤

private func insertLineage(
    _ db: DuoDB, deviceID: String, startedAtNs: Int64, endedAtNs: Int64?
) async throws {
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO primary_lineage(device_id, started_at_ns, ended_at_ns)
            VALUES (?, ?, ?)
        """, arguments: [deviceID, startedAtNs, endedAtNs])
    }
}

@Test func auditLineageAwareRestrictsAbsorberToActivePrimary() async throws {
    // 跨任期内容碰撞场景。lineage 记录 mini 任期到 T_promote 结束、mbp 任期 T_promote 开始。
    // self=air 推一条 "hello" 在 T_air_push（mbp 任期内）→ 只有 mbp-origin 行才能算合法吸收，
    // mini 的同内容历史行在 5s 窗口内但 lineage 说它已不是 primary，必须被严格匹配挡掉。
    // 老 `origin != self` 启发式会同时让 mini 和 mbp 都通过，误算为 mini 吸收 → 这条测试
    // 锁定新行为：candidates 里同时有 mini-origin 和 mbp-origin 时只选 active primary
    let db = try makeClientDB()
    let selfID = "air"
    let tPromote: Int64 = 15_000_000_000
    try await insertLineage(db, deviceID: "mini", startedAtNs: 0, endedAtNs: tPromote)
    try await insertLineage(db, deviceID: "mbp", startedAtNs: tPromote, endedAtNs: nil)
    // air push 在 mbp 任期内（capturedAtNs > tPromote）。期望 absorber=mbp-origin
    try await insertItem(db, id: "air-x", origin: selfID, pushState: .acked,
                         capturedAtNs: 16_000_000_000, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: selfID,
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 2,
                items: [
                    // 干扰项：mini-origin 同内容、在 5s 窗内（capturedAt=12s 距 16s=4s）。
                    // 老启发式会吸收，lineage-aware 必须挡掉
                    Item(id: "mini-old", originDevice: "mini",
                         capturedAtNs: 12_000_000_000, ingestedAtNs: 12_000_000_000,
                         kind: .text, preview: "hello", textFull: "hello", pushState: .acked),
                    // 合法吸收源：mbp-origin，5s 窗内、且 mbp 是 capturedAt=16s 的 active primary
                    Item(id: "mbp-new", originDevice: "mbp",
                         capturedAtNs: 15_500_000_000, ingestedAtNs: 15_500_000_000,
                         kind: .text, preview: "hello", textFull: "hello", pushState: .acked),
                ],
                nextCursor: SinceCursor(ingestedAtNs: 15_500_000_000, id: "mbp-new"),
                hasMore: false
            )
        }
    )
    #expect(report.missingTotal == 0)
    #expect(report.dedupAbsorbed == 1)
    #expect(report.dedupAbsorbedSamples.first?.absorbedByID == "mbp-new")
}

@Test func auditLineageAwareRejectsWrongTenureCandidate() async throws {
    // 只有错任期的 candidate（mini-origin 在 mbp 任期内推的 row）→ 严格匹配挡掉 → missing。
    // 区别 "正确任期吸收源在但被错选" vs "压根没合法吸收源"，第二种应正确报 missing
    let db = try makeClientDB()
    let selfID = "air"
    let tPromote: Int64 = 15_000_000_000
    try await insertLineage(db, deviceID: "mini", startedAtNs: 0, endedAtNs: tPromote)
    try await insertLineage(db, deviceID: "mbp", startedAtNs: tPromote, endedAtNs: nil)
    try await insertItem(db, id: "air-x", origin: selfID, pushState: .acked,
                         capturedAtNs: 16_000_000_000, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: selfID,
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [
                    // 只有 mini-origin（错任期），mbp 任期内应该 mbp-origin 才合法
                    Item(id: "mini-only", originDevice: "mini",
                         capturedAtNs: 15_500_000_000, ingestedAtNs: 15_500_000_000,
                         kind: .text, preview: "hello", textFull: "hello", pushState: .acked),
                ],
                nextCursor: SinceCursor(ingestedAtNs: 15_500_000_000, id: "mini-only"),
                hasMore: false
            )
        }
    )
    #expect(report.dedupAbsorbed == 0)
    #expect(report.missingTotal == 1)
    #expect(report.missingOnPrimary == ["air-x"])
}

@Test func auditLineageAwareAcceptsHistoricTenureAbsorber() async throws {
    // air 在 mini 任期早期（capturedAtNs=8s < tPromote=15s）push "hello"，mini-origin 同内容
    // 在 5s 窗内 → 正确识别为 mini 吸收。验证 startedAtNs=0 sentinel "未知起点" 能匹配 t < 15s
    let db = try makeClientDB()
    let selfID = "air"
    let tPromote: Int64 = 15_000_000_000
    try await insertLineage(db, deviceID: "mini", startedAtNs: 0, endedAtNs: tPromote)
    try await insertLineage(db, deviceID: "mbp", startedAtNs: tPromote, endedAtNs: nil)
    try await insertItem(db, id: "air-x", origin: selfID, pushState: .acked,
                         capturedAtNs: 8_000_000_000, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: selfID,
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [
                    Item(id: "mini-old", originDevice: "mini",
                         capturedAtNs: 8_500_000_000, ingestedAtNs: 8_500_000_000,
                         kind: .text, preview: "hello", textFull: "hello", pushState: .acked),
                ],
                nextCursor: SinceCursor(ingestedAtNs: 8_500_000_000, id: "mini-old"),
                hasMore: false
            )
        }
    )
    #expect(report.dedupAbsorbed == 1)
    #expect(report.dedupAbsorbedSamples.first?.absorbedByID == "mini-old")
    #expect(report.missingTotal == 0)
}

@Test func auditLineageFallbackWhenTimeNotCovered() async throws {
    // lineage 只覆盖未来时段（startedAtNs=100s 未来）。row push 在 10s（早于所有任期）
    // → activePrimaryDeviceID 返回 nil → 回退 origin != self 启发式 → mini-origin 同内容吸收
    let db = try makeClientDB()
    try await insertLineage(db, deviceID: "mbp", startedAtNs: 100_000_000_000, endedAtNs: nil)
    try await insertItem(db, id: "air-x", origin: "air", pushState: .acked,
                         capturedAtNs: 10_000_000_000, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "air",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "mini-y", originDevice: "mini",
                             capturedAtNs: 9_500_000_000, ingestedAtNs: 9_500_000_000,
                             kind: .text, preview: "hello", textFull: "hello", pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 9_500_000_000, id: "mini-y"),
                hasMore: false
            )
        }
    )
    #expect(report.dedupAbsorbed == 1)
}

@Test func auditLineageFallbackWhenActivePrimaryIsSelf() async throws {
    // self 曾 promote 过，lineage (self, T_promote, NULL) 仍 "开着"；之后手动改 config 回
    // client 跑 audit。严格匹配会让 expected=self 拒所有 candidate → 误报 missing。
    // activePrimaryDeviceID 见 expected == selfDeviceID 时返回 nil → 回退 origin != self 启发式
    let db = try makeClientDB()
    let selfID = "mbp"
    try await insertLineage(db, deviceID: selfID, startedAtNs: 5_000_000_000, endedAtNs: nil)
    try await insertItem(db, id: "mbp-x", origin: selfID, pushState: .acked,
                         capturedAtNs: 10_000_000_000, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: selfID,
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "mini-y", originDevice: "mini",
                             capturedAtNs: 9_500_000_000, ingestedAtNs: 9_500_000_000,
                             kind: .text, preview: "hello", textFull: "hello", pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 9_500_000_000, id: "mini-y"),
                hasMore: false
            )
        }
    )
    // 回退到 origin != self → mini != mbp → 吸收成立
    #expect(report.dedupAbsorbed == 1)
    #expect(report.missingTotal == 0)
}

@Test func auditLineageHalfOpenBoundary() async throws {
    // Half-open `[started, ended)` 右开端点。锁定 `t < endedAtNs` 不能被改成 `t <= endedAtNs`。
    //
    // 单 entry lineage `(mini, 0, T)` + candidate origin = "mbp"（既非 mini 也非 self）让两条
    // 路径输出严格不同：
    //   - 正确 `<`：t == T → mini 不覆盖（右端点开）→ activePrimary=nil → 回退 `origin != self`
    //     → mbp ≠ air → 吸收成立 → dedupAbsorbed=1, missingTotal=0
    //   - 误改 `<=`：t == T → mini 覆盖 → expected=mini → candidate origin "mbp" ≠ mini → 拒收
    //     → missingTotal=1
    //
    // 不能跟 mbp 任期共享 boundary timestamp——那会让 `max(by: startedAtNs)` 在 `<=` 误改下
    // 仍选 mbp，掩盖 off-by-one
    let db = try makeClientDB()
    let selfID = "air"
    let tBoundary: Int64 = 15_000_000_000
    try await insertLineage(db, deviceID: "mini", startedAtNs: 0, endedAtNs: tBoundary)
    try await insertItem(db, id: "air-x", origin: selfID, pushState: .acked,
                         capturedAtNs: tBoundary, textFull: "hello")
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: selfID,
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [
                    Item(id: "mbp-other", originDevice: "mbp",
                         capturedAtNs: tBoundary &+ 500_000_000,
                         ingestedAtNs: tBoundary &+ 500_000_000,
                         kind: .text, preview: "hello", textFull: "hello", pushState: .acked),
                ],
                nextCursor: SinceCursor(ingestedAtNs: tBoundary &+ 500_000_000, id: "mbp-other"),
                hasMore: false
            )
        }
    )
    #expect(report.dedupAbsorbed == 1)
    #expect(report.dedupAbsorbedSamples.first?.absorbedByID == "mbp-other")
    #expect(report.missingTotal == 0)
}

@Test func auditDoesNotReportStaleWhenPrimaryAhead() async throws {
    // primary 自家有 merge 行为 → primary 的 capturedAtNs 可能比 local 高。
    // 这是 primary 的合法状态，不应该被 audit 当 stale 报。audit 关心的是
    // "我推的更新是否落到 primary"，反向 diff 不在职责内
    let db = try makeClientDB()
    try await insertItem(db, id: "q", origin: "mbp", pushState: .acked,
                         capturedAtNs: 100)
    let report = try await AuditPush.run(
        database: db,
        selfDeviceID: "mbp",
        fetchPage: { _, _ in
            SincePageWire(
                ok: true, count: 1,
                items: [Item(id: "q", originDevice: "mbp",
                             capturedAtNs: 500, ingestedAtNs: 500,
                             kind: .text, preview: "q", textFull: "q",
                             pushState: .acked)],
                nextCursor: SinceCursor(ingestedAtNs: 500, id: "q"),
                hasMore: false
            )
        }
    )
    #expect(report.staleTotal == 0)
}

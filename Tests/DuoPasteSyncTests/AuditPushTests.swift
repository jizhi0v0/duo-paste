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

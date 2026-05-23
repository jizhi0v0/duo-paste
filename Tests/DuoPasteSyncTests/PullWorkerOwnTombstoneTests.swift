import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

// plan hashed-allen §B:PullWorker.applyPage 对自家 origin 的 incoming tombstone
// 例外接收(local active + ingested 单增 → UPDATE)。
//
// 触发场景:softDelete cascade 在 peer Mac 上删了同 text_full 的所有 sibling,
// 本机 own 行的 mirror 也被 tombstone → 通过 /since 推回本机 → 必须能写本机 own 行,
// 否则三端不一致(MBP own 永远删不掉但 mini / iOS 都显示已删)。

private typealias DuoDB = DuoPasteCore.Database

private func makeClientDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-pull-owntomb-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func mkOwnTextItem(
    id: String,
    selfDeviceID: String,
    capturedAtNs: Int64,
    ingestedAtNs: Int64,
    text: String,
    deletedAtNs: Int64? = nil
) -> Item {
    Item(
        id: id,
        originDevice: selfDeviceID,
        capturedAtNs: capturedAtNs,
        ingestedAtNs: ingestedAtNs,
        kind: .text,
        sourceAppName: "Test",
        preview: text,
        textFull: text,
        deletedAtNs: deletedAtNs
    )
}

private actor FakePagedTransport: SinceTransport {
    private var pages: [SincePageWire]
    private let healthDeviceID: String

    init(pages: [SincePageWire], healthDeviceID: String) {
        self.pages = pages
        self.healthDeviceID = healthDeviceID
    }

    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        await self._fetch()
    }

    private func _fetch() async -> RemoteSinceResult {
        guard !pages.isEmpty else {
            return RemoteSinceResult(outcome: .unreachable(reason: "drained"))
        }
        return RemoteSinceResult(outcome: .ok(pages.removeFirst()))
    }

    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        PrimaryHealthResult(outcome: .ok(deviceID: healthDeviceID, nowMs: 1_000, ponteHost: nil))
    }
}

private func page(_ items: [Item], nextNs: Int64, nextID: String) -> SincePageWire {
    SincePageWire(
        ok: true,
        count: items.count,
        items: items,
        nextCursor: SinceCursor(ingestedAtNs: nextNs, id: nextID),
        hasMore: false
    )
}

private func runWorker(_ worker: PullWorker, ms: Int = 250) async {
    await worker.start()
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    await worker.stop()
}

@Test func ownTombstoneUpdatesLocalActiveRow() async throws {
    // 本机 own 行 active(ingested=100) → /since 推回带 deletedAtNs 的 own tombstone
    // (ingested=200,严格单增)→ 应用 UPDATE,deleted_at_ns 落,ingested 顶,
    // captured_at_ns / textFull 不动
    let selfID = "client-self"
    let db = try makeClientDB()
    let original = mkOwnTextItem(id: "own1", selfDeviceID: selfID, capturedAtNs: 50, ingestedAtNs: 100, text: "hello")
    try await db.pool.write { try original.insert($0) }

    // peer cascade 后 /since 推回 tombstone(textFull 故意改值验证不回写)
    let incoming = mkOwnTextItem(id: "own1", selfDeviceID: selfID, capturedAtNs: 9999, ingestedAtNs: 200, text: "REWRITTEN", deletedAtNs: 300)
    let transport = FakePagedTransport(
        pages: [page([incoming], nextNs: 200, nextID: "own1")],
        healthDeviceID: "peer-mac"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runWorker(worker)

    let after = try await db.pool.read { try Item.filter(Column("id") == "own1").fetchOne($0)! }
    #expect(after.deletedAtNs == 300, "tombstone 必须落")
    #expect(after.ingestedAtNs == 200, "ingested 必须顶到 incoming")
    #expect(after.capturedAtNs == 50, "captured_at_ns 不动")
    #expect(after.textFull == "hello", "textFull 不回写")
    #expect(after.originDevice == selfID, "origin 不动")
}

@Test func ownTombstoneNoOpWhenLocalAlreadyTombstoned() async throws {
    // local 已 tombstone(deletedAtNs=999) → incoming own tombstone 不该再写
    let selfID = "client-self"
    let db = try makeClientDB()
    let dead = mkOwnTextItem(id: "own1", selfDeviceID: selfID, capturedAtNs: 50, ingestedAtNs: 100, text: "x", deletedAtNs: 999)
    try await db.pool.write { try dead.insert($0) }

    let incoming = mkOwnTextItem(id: "own1", selfDeviceID: selfID, capturedAtNs: 50, ingestedAtNs: 200, text: "x", deletedAtNs: 500)
    let transport = FakePagedTransport(
        pages: [page([incoming], nextNs: 200, nextID: "own1")],
        healthDeviceID: "peer-mac"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runWorker(worker)

    let after = try await db.pool.read { try Item.filter(Column("id") == "own1").fetchOne($0)! }
    #expect(after.deletedAtNs == 999, "原 tombstone 时间戳不动")
    #expect(after.ingestedAtNs == 100, "ingested 不动")
}

@Test func ownTombstoneNoOpWhenIncomingNotNewer() async throws {
    // local ingested=300,incoming ingested=200 → 不满足严格单增 → 跳过
    // (防 race:本机后续 capture 已 bump 这条 row,远端旧 tombstone 不该回卷)
    let selfID = "client-self"
    let db = try makeClientDB()
    let original = mkOwnTextItem(id: "own1", selfDeviceID: selfID, capturedAtNs: 50, ingestedAtNs: 300, text: "hello")
    try await db.pool.write { try original.insert($0) }

    let incoming = mkOwnTextItem(id: "own1", selfDeviceID: selfID, capturedAtNs: 50, ingestedAtNs: 200, text: "hello", deletedAtNs: 250)
    let transport = FakePagedTransport(
        pages: [page([incoming], nextNs: 300, nextID: "own1")],
        healthDeviceID: "peer-mac"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runWorker(worker)

    let after = try await db.pool.read { try Item.filter(Column("id") == "own1").fetchOne($0)! }
    #expect(after.deletedAtNs == nil, "incoming 不够新,不该 tombstone")
    #expect(after.ingestedAtNs == 300, "ingested 不动")
}

@Test func ownActiveIncomingStillSkipped() async throws {
    // incoming 是 own active(非 tombstone)→ 走旧的"自家 origin 跳过"语义,
    // 不该 INSERT OR REPLACE 把 own 行覆盖
    let selfID = "client-self"
    let db = try makeClientDB()
    let original = mkOwnTextItem(id: "own1", selfDeviceID: selfID, capturedAtNs: 50, ingestedAtNs: 100, text: "hello")
    try await db.pool.write { try original.insert($0) }

    // incoming 非 tombstone(deletedAtNs=nil)+ textFull 故意改名
    let incoming = mkOwnTextItem(id: "own1", selfDeviceID: selfID, capturedAtNs: 999, ingestedAtNs: 200, text: "REWRITTEN")
    let transport = FakePagedTransport(
        pages: [page([incoming], nextNs: 200, nextID: "own1")],
        healthDeviceID: "peer-mac"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runWorker(worker)

    let after = try await db.pool.read { try Item.filter(Column("id") == "own1").fetchOne($0)! }
    #expect(after.deletedAtNs == nil)
    #expect(after.ingestedAtNs == 100, "ingested 不动(non-tombstone own incoming 完全跳过)")
    #expect(after.capturedAtNs == 50)
    #expect(after.textFull == "hello")
}

@Test func ownTombstoneNoOpWhenLocalMissing() async throws {
    // local 根本没这条 own 行(罕见,但理论 race 可能)→ 不该意外创建 row
    let selfID = "client-self"
    let db = try makeClientDB()
    // 不 insert 任何行

    let incoming = mkOwnTextItem(id: "own1", selfDeviceID: selfID, capturedAtNs: 50, ingestedAtNs: 200, text: "x", deletedAtNs: 300)
    let transport = FakePagedTransport(
        pages: [page([incoming], nextNs: 200, nextID: "own1")],
        healthDeviceID: "peer-mac"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: selfID,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runWorker(worker)

    let count = try await db.pool.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE id = 'own1'") ?? 0
    }
    #expect(count == 0, "local 没这条行时不该意外创建 row")
}

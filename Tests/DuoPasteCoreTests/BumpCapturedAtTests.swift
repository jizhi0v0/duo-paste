import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private typealias Database = DuoPasteCore.Database

private func makeBumpDB() throws -> (Database, BlobStore) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-bump-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try Database(path: paths.mainDB)
    let blobs = BlobStore(root: paths.blobsDir)
    return (db, blobs)
}

@Test func bumpUpdatesCapturedAndIngestedKeepsOrigin() async throws {
    // Mac 端 origin=mac-X 的行被 iOS POST /bump → captured/ingested bump,origin 不变
    let (db, _) = try makeBumpDB()
    let original = Item(
        id: "row-1",
        originDevice: "mac-X",
        capturedAtNs: 100,
        ingestedAtNs: 100,
        kind: .text,
        sourceAppName: "Notes",
        preview: "hi",
        textFull: "hi"
    )
    try await db.pool.write { try original.insert($0) }
    let now: Int64 = 5_000_000_000_000_000_000
    let newIngest = try await db.bumpCapturedAt(id: "row-1", now: now)
    #expect(newIngest >= now)

    let after = try await db.pool.read { try Item.fetchOne($0)! }
    #expect(after.id == "row-1")
    #expect(after.originDevice == "mac-X")           // 归属不动
    #expect(after.capturedAtNs == now)               // 顶到 now
    #expect(after.ingestedAtNs == newIngest)
    #expect(after.textFull == "hi")                  // 内容不动
}

@Test func bumpUsesMaxPlusOneWhenNowIsStale() async throws {
    // wall clock 倒退 / 多次同 ms 调用——captured_at_ns 用 max(prev+1, now) 单增
    let (db, _) = try makeBumpDB()
    let original = Item(
        id: "row-2",
        originDevice: "self",
        capturedAtNs: 1_000_000_000_000_000_000,
        ingestedAtNs: 1_000_000_000_000_000_000,
        kind: .text,
        preview: "x",
        textFull: "x"
    )
    try await db.pool.write { try original.insert($0) }
    // 模拟 wall clock 比 prev 还小
    let staleNow: Int64 = 500_000_000_000_000_000
    _ = try await db.bumpCapturedAt(id: "row-2", now: staleNow)
    let after = try await db.pool.read { try Item.fetchOne($0)! }
    #expect(after.capturedAtNs == 1_000_000_000_000_000_001)  // prev + 1
}

@Test func bumpRejectsTombstone() async throws {
    let (db, _) = try makeBumpDB()
    let dead = Item(
        id: "row-dead",
        originDevice: "self",
        capturedAtNs: 100,
        ingestedAtNs: 100,
        kind: .text,
        preview: "gone",
        textFull: "gone",
        deletedAtNs: 200    // 软删
    )
    try await db.pool.write { try dead.insert($0) }
    await #expect(throws: BumpError.deleted) {
        _ = try await db.bumpCapturedAt(id: "row-dead", now: 999)
    }
    let after = try await db.pool.read { try Item.fetchOne($0)! }
    #expect(after.capturedAtNs == 100)               // 没动
    #expect(after.deletedAtNs == 200)
}

@Test func bumpRejectsUnknownID() async throws {
    let (db, _) = try makeBumpDB()
    await #expect(throws: BumpError.notFound) {
        _ = try await db.bumpCapturedAt(id: "not-here", now: 100)
    }
}

@Test func bumpAdvancesIngestedAcrossMultipleCalls() async throws {
    // 连续 bump 同 id 多次,ingested_at_ns 必须单增——/since cursor 正确性前提
    let (db, _) = try makeBumpDB()
    let row = Item(
        id: "row-multi",
        originDevice: "self",
        capturedAtNs: 100,
        ingestedAtNs: 100,
        kind: .text,
        preview: "p",
        textFull: "p"
    )
    try await db.pool.write { try row.insert($0) }
    var prev: Int64 = 0
    for i in 1...5 {
        let now: Int64 = 1_000_000_000_000_000_000 + Int64(i)
        let ns = try await db.bumpCapturedAt(id: "row-multi", now: now)
        #expect(ns > prev)
        prev = ns
    }
}

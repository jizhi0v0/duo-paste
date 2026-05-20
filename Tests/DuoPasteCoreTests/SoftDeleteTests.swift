import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private typealias Database = DuoPasteCore.Database

private func makeSoftDeleteDB() throws -> Database {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-softdel-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try Database(path: paths.mainDB)
}

@Test func softDeleteSetsTombstoneAndBumpsIngested() async throws {
    // 软删:deleted_at_ns 写入,ingested_at_ns 顶到当前 max+1 让 /since cursor 推进。
    // captured_at_ns / origin / 内容字段不动——删是元数据变化不是归属变化
    let db = try makeSoftDeleteDB()
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
    let newIngest = try await db.softDelete(id: "row-1", now: now)
    #expect(newIngest >= now)

    let after = try await db.pool.read { try Item.fetchOne($0)! }
    #expect(after.id == "row-1")
    #expect(after.originDevice == "mac-X")           // 归属不动
    #expect(after.capturedAtNs == 100)               // **不动**
    #expect(after.ingestedAtNs == newIngest)         // 顶
    #expect(after.deletedAtNs == now)                // tombstone 落
    #expect(after.textFull == "hi")                  // 内容不动
}

@Test func softDeleteRejectsAlreadyDeleted() async throws {
    let db = try makeSoftDeleteDB()
    let dead = Item(
        id: "row-dead",
        originDevice: "self",
        capturedAtNs: 100,
        ingestedAtNs: 100,
        kind: .text,
        preview: "gone",
        textFull: "gone",
        deletedAtNs: 200
    )
    try await db.pool.write { try dead.insert($0) }
    await #expect(throws: BumpError.alreadyDeleted) {
        _ = try await db.softDelete(id: "row-dead", now: 999)
    }
    let after = try await db.pool.read { try Item.fetchOne($0)! }
    #expect(after.deletedAtNs == 200)                // 原 tombstone 时间戳不动
    #expect(after.ingestedAtNs == 100)               // 没 bump(没改动)
}

@Test func softDeleteRejectsUnknownID() async throws {
    let db = try makeSoftDeleteDB()
    await #expect(throws: BumpError.notFound) {
        _ = try await db.softDelete(id: "not-here", now: 100)
    }
}

@Test func softDeleteAdvancesIngestedAcrossMultipleRows() async throws {
    // 多行连续软删,每行的 ingested_at_ns 必须单增——/since cursor 正确性前提
    let db = try makeSoftDeleteDB()
    for i in 1...3 {
        let row = Item(
            id: "row-\(i)",
            originDevice: "self",
            capturedAtNs: Int64(i),
            ingestedAtNs: Int64(i),
            kind: .text,
            preview: "p\(i)",
            textFull: "p\(i)"
        )
        try await db.pool.write { try row.insert($0) }
    }
    var prev: Int64 = 0
    for i in 1...3 {
        let now: Int64 = 1_000_000_000_000_000_000 + Int64(i)
        let ns = try await db.softDelete(id: "row-\(i)", now: now)
        #expect(ns > prev)
        prev = ns
    }
}

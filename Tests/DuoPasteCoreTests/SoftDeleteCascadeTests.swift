import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

// plan hashed-allen §C:softDelete cascade 同 text_full 所有 active sibling。
// 这是三端删除一致性的核心:删一条 = fold group 全部 tombstone,跨 origin 一并删。

private typealias Database = DuoPasteCore.Database

private func makeCascadeDB() throws -> Database {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-softdel-cascade-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try Database(path: paths.mainDB)
}

private func insertText(
    _ db: Database,
    id: String,
    origin: String,
    text: String,
    capturedNs: Int64,
    ingestedNs: Int64,
    deletedNs: Int64? = nil
) async throws {
    let row = Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedNs,
        ingestedAtNs: ingestedNs,
        kind: .text,
        preview: text,
        textFull: text,
        deletedAtNs: deletedNs
    )
    try await db.pool.write { try row.insert($0) }
}

private func insertImage(
    _ db: Database,
    id: String,
    origin: String,
    sha: String,
    capturedNs: Int64,
    ingestedNs: Int64
) async throws {
    let row = Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedNs,
        ingestedAtNs: ingestedNs,
        kind: .image,
        preview: "[image]",
        blobSha256: sha,
        blobSize: 1024,
        blobMime: "image/png"
    )
    try await db.pool.write { try row.insert($0) }
}

@Test func cascadeFalseOnlyDeletesTarget() async throws {
    // cascade=false → 即使有同 text_full 的 sibling 也不波及
    let db = try makeCascadeDB()
    try await insertText(db, id: "a", origin: "mbp", text: "hello", capturedNs: 100, ingestedNs: 100)
    try await insertText(db, id: "b", origin: "mini", text: "hello", capturedNs: 200, ingestedNs: 200)

    let now: Int64 = 5_000_000_000_000_000_000
    let results = try await db.softDelete(id: "a", now: now, cascade: false)
    #expect(results.count == 1)
    #expect(results[0].id == "a")

    let a = try await db.pool.read { try Item.filter(Column("id") == "a").fetchOne($0)! }
    let b = try await db.pool.read { try Item.filter(Column("id") == "b").fetchOne($0)! }
    #expect(a.deletedAtNs == now)
    #expect(b.deletedAtNs == nil)  // sibling 未受影响
}

@Test func cascadeTombstonesAllSiblingsAcrossOrigins() async throws {
    // cascade=true(default) + text-kind + 3 个跨 origin sibling → 全部 tombstone +
    // ingested 严格单增
    let db = try makeCascadeDB()
    try await insertText(db, id: "own-mbp", origin: "mbp", text: "shared", capturedNs: 100, ingestedNs: 100)
    try await insertText(db, id: "own-mini", origin: "mini", text: "shared", capturedNs: 200, ingestedNs: 200)
    try await insertText(db, id: "mirror", origin: "ios", text: "shared", capturedNs: 300, ingestedNs: 300)
    // 不同 text 的干扰行 — 不应被波及
    try await insertText(db, id: "unrelated", origin: "mbp", text: "other", capturedNs: 400, ingestedNs: 400)

    let now: Int64 = 5_000_000_000_000_000_000
    let results = try await db.softDelete(id: "own-mbp", now: now)
    #expect(results.count == 3)
    // ingested 严格单增
    var prev: Int64 = 0
    for r in results {
        #expect(r.ingestedAtNs > prev)
        prev = r.ingestedAtNs
    }

    let ids = Set(results.map(\.id))
    #expect(ids == ["own-mbp", "own-mini", "mirror"])

    // 干扰行不动
    let unrelated = try await db.pool.read { try Item.filter(Column("id") == "unrelated").fetchOne($0)! }
    #expect(unrelated.deletedAtNs == nil)

    // 所有 sibling 都 tombstone
    for sid in ["own-mbp", "own-mini", "mirror"] {
        let row = try await db.pool.read { try Item.filter(Column("id") == sid).fetchOne($0)! }
        #expect(row.deletedAtNs == now, "sibling \(sid) 未 tombstone")
    }
}

@Test func cascadeSkipsAlreadyDeletedSibling() async throws {
    // 已 tombstone 的 sibling 不重写 deleted_at_ns,跳过
    let db = try makeCascadeDB()
    try await insertText(db, id: "alive", origin: "mbp", text: "shared", capturedNs: 100, ingestedNs: 100)
    try await insertText(db, id: "dead", origin: "mini", text: "shared", capturedNs: 200, ingestedNs: 200, deletedNs: 999)

    let now: Int64 = 5_000_000_000_000_000_000
    let results = try await db.softDelete(id: "alive", now: now)
    #expect(results.count == 1, "只该 tombstone 一条(alive),dead 已 tombstone 跳过")
    #expect(results[0].id == "alive")

    // dead 的 deletedAtNs 不动(SQL WHERE 加了 deleted_at_ns IS NULL,根本不会进 siblingIDs)
    let dead = try await db.pool.read { try Item.filter(Column("id") == "dead").fetchOne($0)! }
    #expect(dead.deletedAtNs == 999)
    #expect(dead.ingestedAtNs == 200)
}

@Test func cascadeDoesNotApplyToBlobKind() async throws {
    // blob-kind(blob_sha256 非空) → 即使 cascade=true 也不 cascade,只删单 id
    let db = try makeCascadeDB()
    try await insertImage(db, id: "img-a", origin: "mbp", sha: "deadbeef", capturedNs: 100, ingestedNs: 100)
    try await insertImage(db, id: "img-b", origin: "mini", sha: "deadbeef", capturedNs: 200, ingestedNs: 200)

    let now: Int64 = 5_000_000_000_000_000_000
    let results = try await db.softDelete(id: "img-a", now: now)
    #expect(results.count == 1)
    #expect(results[0].id == "img-a")

    let imgB = try await db.pool.read { try Item.filter(Column("id") == "img-b").fetchOne($0)! }
    #expect(imgB.deletedAtNs == nil, "blob-kind sibling 不该被 cascade")
}

@Test func cascadeRejectsAlreadyDeletedTarget() async throws {
    // 目标自己已 tombstone → 仍然 throw alreadyDeleted(跟 sibling 跳过不同)
    let db = try makeCascadeDB()
    try await insertText(db, id: "dead", origin: "mbp", text: "x", capturedNs: 100, ingestedNs: 100, deletedNs: 999)
    await #expect(throws: BumpError.alreadyDeleted) {
        _ = try await db.softDelete(id: "dead", now: 5_000_000_000_000_000_000)
    }
}

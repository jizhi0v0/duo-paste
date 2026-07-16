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

@Test func cascadeDoesNotMergeSameOriginBlobTimeline() async throws {
    // 同一设备主动重复复制同一 blob → 两张独立时间线卡，删除只动目标。
    let db = try makeCascadeDB()
    try await insertImage(db, id: "img-a", origin: "mbp", sha: "deadbeef", capturedNs: 100, ingestedNs: 100)
    try await insertImage(db, id: "img-b", origin: "mbp", sha: "deadbeef", capturedNs: 200, ingestedNs: 200)

    let now: Int64 = 5_000_000_000_000_000_000
    let results = try await db.softDelete(id: "img-a", now: now)
    #expect(results.count == 1)
    #expect(results[0].id == "img-a")

    let imgB = try await db.pool.read { try Item.filter(Column("id") == "img-b").fetchOne($0)! }
    #expect(imgB.deletedAtNs == nil, "同 origin 的独立时间线不该被 cascade")
}

@Test func cascadeRejectsAlreadyDeletedTarget() async throws {
    // 目标自己已 tombstone → 仍然 throw alreadyDeleted(跟 sibling 跳过不同)
    let db = try makeCascadeDB()
    try await insertText(db, id: "dead", origin: "mbp", text: "x", capturedNs: 100, ingestedNs: 100, deletedNs: 999)
    await #expect(throws: BumpError.alreadyDeleted) {
        _ = try await db.softDelete(id: "dead", now: 5_000_000_000_000_000_000)
    }
}

// MARK: - 补加回归 (PR review follow-up)

@Test func cascadeHandlesManySiblings() async throws {
    // N>3 stress:50 个跨 origin sibling 同 text_full,一次 softDelete 应全部 tombstone +
    // ingested_at_ns 严格单增。压一下 v12 partial index 路径
    let db = try makeCascadeDB()
    let n = 50
    for i in 0..<n {
        try await insertText(
            db,
            id: "row-\(i)",
            origin: "origin-\(i % 5)",     // 5 个不同 origin 模拟 cross-device 副本
            text: "shared-text",
            capturedNs: Int64(100 + i),
            ingestedNs: Int64(100 + i)
        )
    }
    // 干扰行 - 不该被波及
    try await insertText(db, id: "noise-1", origin: "mbp", text: "other", capturedNs: 999, ingestedNs: 999)

    let now: Int64 = 5_000_000_000_000_000_000
    let results = try await db.softDelete(id: "row-0", now: now)
    #expect(results.count == n, "应 tombstone 所有 \(n) 条 sibling")

    // ingested 严格单增
    var prev: Int64 = 0
    for r in results {
        #expect(r.ingestedAtNs > prev, "ingested_at_ns 必须严格单增")
        prev = r.ingestedAtNs
    }

    // 全部 tombstone
    for i in 0..<n {
        let row = try await db.pool.read {
            try Item.filter(Column("id") == "row-\(i)").fetchOne($0)!
        }
        #expect(row.deletedAtNs == now)
    }
    // 干扰行不动
    let noise = try await db.pool.read {
        try Item.filter(Column("id") == "noise-1").fetchOne($0)!
    }
    #expect(noise.deletedAtNs == nil)
}

@Test func cascadeSkipsBlobSiblingsWithSameTextFull() async throws {
    // 边角:同 text_full 但 blob-kind sibling(理论上不该出现,但 schema 不禁止——比如
    // OCR worker 把图片 text_full 写到了相同字符串)。cascade SQL 的 `blob_sha256 IS NULL`
    // filter 应当排除它们,只 cascade 纯 text-kind
    let db = try makeCascadeDB()
    try await insertText(db, id: "t1", origin: "mbp", text: "shared", capturedNs: 100, ingestedNs: 100)
    try await insertText(db, id: "t2", origin: "mini", text: "shared", capturedNs: 200, ingestedNs: 200)
    // 假装 blob-kind 行也有 text_full=shared(OCR 路径可能写入)
    let imgRow = Item(
        id: "img-1",
        originDevice: "mbp",
        capturedAtNs: 300,
        ingestedAtNs: 300,
        kind: .image,
        preview: "shared",
        textFull: "shared",
        blobSha256: "deadbeef",
        blobSize: 1024,
        blobMime: "image/png"
    )
    try await db.pool.write { try imgRow.insert($0) }

    let now: Int64 = 5_000_000_000_000_000_000
    let results = try await db.softDelete(id: "t1", now: now)
    let deletedIDs = Set(results.map(\.id))
    #expect(deletedIDs == ["t1", "t2"], "cascade 只该带 text-kind sibling,不该波及 blob-kind")

    let img = try await db.pool.read { try Item.filter(Column("id") == "img-1").fetchOne($0)! }
    #expect(img.deletedAtNs == nil, "blob-kind 同 text_full 不该被 cascade")
}

@Test func cascadeDeletesOnlyTheMatchingCrossOriginBlobFoldGroup() async throws {
    let db = try makeCascadeDB()
    let sha = String(repeating: "c", count: 64)
    // 同 origin 两次主动 copy 应是两张卡；peer 副本跟更近的 own-new 折叠。
    try await insertImage(db, id: "own-old", origin: "mbp", sha: sha,
                          capturedNs: 0, ingestedNs: 1)
    try await insertImage(db, id: "own-new", origin: "mbp", sha: sha,
                          capturedNs: 5_000_000_000, ingestedNs: 2)
    try await insertImage(db, id: "peer-copy", origin: "mini", sha: sha,
                          capturedNs: 6_000_000_000, ingestedNs: 3)

    let results = try await db.softDelete(
        id: "own-new",
        now: 5_000_000_000_000_000_000
    )
    #expect(Set(results.map(\.id)) == ["own-new", "peer-copy"])

    let old = try await db.pool.read { try Item.filter(Column("id") == "own-old").fetchOne($0)! }
    let peer = try await db.pool.read { try Item.filter(Column("id") == "peer-copy").fetchOne($0)! }
    #expect(old.deletedAtNs == nil, "同 origin 的独立时间线卡不应被误删")
    #expect(peer.deletedAtNs != nil, "折叠的跨 origin 副本必须一起 tombstone")
}

@Test func cascadeMatchesFoldPredicate() async throws {
    // 不变量:softDelete cascade 选 sibling 的范围必须跟 Item.foldByTextFull 一致——
    // UI 看到的 fold group 全部 tombstone。fold 跳过 deleted_at_ns 非空 + 要 blob_sha256
    // IS NULL + textFull 非空;cascade SQL 同口径。两边 byte-equal text_full 比较
    let db = try makeCascadeDB()

    // 准备 6 行混合 case:
    // - alive_text_a (text=A) <- target
    // - alive_text_a_mini (text=A)
    // - alive_text_a_ios (text=A)
    // - dead_text_a (text=A 但 deleted)        ← fold 跳过 / cascade 跳过
    // - alive_blob_a (text=A 但 blob-kind)     ← fold 跳过 / cascade 跳过
    // - alive_text_b (text=B)                  ← fold 不同桶 / cascade 不 match
    try await insertText(db, id: "alive_text_a", origin: "mbp", text: "A", capturedNs: 100, ingestedNs: 100)
    try await insertText(db, id: "alive_text_a_mini", origin: "mini", text: "A", capturedNs: 200, ingestedNs: 200)
    try await insertText(db, id: "alive_text_a_ios", origin: "ios", text: "A", capturedNs: 300, ingestedNs: 300)
    try await insertText(db, id: "dead_text_a", origin: "mbp", text: "A", capturedNs: 50, ingestedNs: 50, deletedNs: 49)
    let blobA = Item(
        id: "alive_blob_a", originDevice: "mbp", capturedAtNs: 400, ingestedAtNs: 400,
        kind: .image, preview: "A", textFull: "A",
        blobSha256: "sha-a", blobSize: 10, blobMime: "image/png"
    )
    try await db.pool.write { try blobA.insert($0) }
    try await insertText(db, id: "alive_text_b", origin: "mbp", text: "B", capturedNs: 500, ingestedNs: 500)

    // fold 视角:active rows 跑 foldByTextFull,找跟 target 同 text_full 的 fold group ids
    let allItems: [Item] = try await db.pool.read { conn in
        try Item.fetchAll(conn)
    }
    let activeForFold = allItems.filter { $0.deletedAtNs == nil }
    let folded = Item.foldByTextFull(activeForFold)
    // 找出 fold 后跟 target 同桶的所有 active 行 ids(target text=A 的纯 text-kind 兄弟)
    let targetText = "A"
    let foldSiblingIDs: Set<String> = Set(activeForFold.filter {
        $0.blobSha256 == nil && $0.textFull == targetText
    }.map(\.id))

    // cascade 视角:跑 softDelete 拿实际 tombstone 的 ids
    let results = try await db.softDelete(id: "alive_text_a", now: 5_000_000_000_000_000_000)
    let cascadeIDs = Set(results.map(\.id))

    // 两边必须一致 — fold 把 A 桶认作一组,cascade 也只删 A 桶里所有 active text-kind
    #expect(cascadeIDs == foldSiblingIDs,
        "cascade(\(cascadeIDs)) 跟 fold sibling set(\(foldSiblingIDs)) 不一致")
    // smoke:fold 后 winner 应当是 captured_at_ns 最大的(alive_text_a_ios=300)
    let aWinner = folded.first(where: { $0.textFull == "A" })
    #expect(aWinner?.id == "alive_text_a_ios")
}

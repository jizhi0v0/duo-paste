import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-admin-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func initSecretWritesHexFile() throws {
    let path = tempDir().appendingPathComponent("shared-secret")
    let r = try Admin.initSecret(at: path, force: false)
    #expect(r.replaced == false)
    #expect(r.path == path)
    let content = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(content.count == 64)
    #expect(content.allSatisfy { $0.isHexDigit })
    let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
    let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    #expect(mode == 0o600)
}

@Test func initSecretRefusesExistingWithoutForce() throws {
    let path = tempDir().appendingPathComponent("shared-secret")
    _ = try Admin.initSecret(at: path, force: false)
    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.initSecret(at: path, force: false)
    }
}

@Test func initSecretOverwritesWithForce() throws {
    let path = tempDir().appendingPathComponent("shared-secret")
    let first = try Admin.initSecret(at: path, force: false)
    let firstContent = try String(contentsOf: path, encoding: .utf8)
    let second = try Admin.initSecret(at: path, force: true)
    #expect(second.replaced == true)
    let secondContent = try String(contentsOf: path, encoding: .utf8)
    // 极小概率两次随机相同——把它当算 SecRandom 坏了，重跑就行；
    // 但断言它们不同是合理的（PRNG 健康）
    #expect(firstContent != secondContent)
    _ = first
}

// PR 4 删了 push_state / push_attempts / last_push_error 列 + Admin.retryFailed 子命令——
// 原 retryFailedResetsOnlyFailedItems / retryFailedNoopWhenNoneFailed 测试不再适用。

// MARK: - retry-failed-ocr

private func seedOCRItem(
    db: DuoPasteCore.Database,
    id: String,
    originDevice: String,
    kind: ItemKind = .image,
    ocrState: OCRState?,
    deletedAtNs: Int64? = nil
) throws {
    let it = Item(
        id: id, originDevice: originDevice,
        capturedAtNs: 1000, kind: kind,
        preview: "p-\(id)",
        blobSha256: kind == .image ? String(repeating: "a", count: 64) : nil,
        deletedAtNs: deletedAtNs,
        ocrState: ocrState
    )
    try db.pool.write { try it.insert($0) }
}

@Test func retryFailedOCRResetsFailedAndSkipped() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    try seedOCRItem(db: db, id: "f1", originDevice: "me", ocrState: .failed)
    try seedOCRItem(db: db, id: "s1", originDevice: "me", ocrState: .skipped)
    try seedOCRItem(db: db, id: "d1", originDevice: "me", ocrState: .done)
    try seedOCRItem(db: db, id: "p1", originDevice: "me", ocrState: .pending)
    let n = try Admin.retryFailedOCR(dbPath: paths.mainDB, selfDeviceID: "me", scope: .all)
    #expect(n == 2)
    let after: [Item] = try db.pool.read { try Item.order(Column("id")).fetchAll($0) }
    let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    #expect(byID["f1"]?.ocrState == .pending)
    #expect(byID["s1"]?.ocrState == .pending)
    #expect(byID["d1"]?.ocrState == .done)  // 不动
    #expect(byID["p1"]?.ocrState == .pending)
}

@Test func retryFailedOCRByIDForcesEvenDone() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    try seedOCRItem(db: db, id: "done-row", originDevice: "me", ocrState: .done)
    let n = try Admin.retryFailedOCR(
        dbPath: paths.mainDB, selfDeviceID: "me", scope: .id("done-row")
    )
    #expect(n == 1)
    let after = try db.pool.read { conn in
        try Item.filter(Column("id") == "done-row").fetchOne(conn)
    }
    #expect(after?.ocrState == .pending)
}

@Test func retryFailedOCRSkipsOtherOriginByDefault() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    try seedOCRItem(db: db, id: "mine", originDevice: "me", ocrState: .failed)
    try seedOCRItem(db: db, id: "theirs", originDevice: "other", ocrState: .failed)
    let n = try Admin.retryFailedOCR(dbPath: paths.mainDB, selfDeviceID: "me", scope: .all)
    #expect(n == 1)
    let after = try db.pool.read { conn -> [Item] in
        try Item.order(Column("id")).fetchAll(conn)
    }
    let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    #expect(byID["mine"]?.ocrState == .pending)
    #expect(byID["theirs"]?.ocrState == .failed)
}

// PR 4 删了 last_push_error 列——原 retryFailedOCRPreservesLastErrorWhenPushFailed 测试不再适用。

@Test func retryFailedOCRSkipsSoftDeleted() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    try seedOCRItem(db: db, id: "del", originDevice: "me", ocrState: .failed, deletedAtNs: 999)
    let n = try Admin.retryFailedOCR(dbPath: paths.mainDB, selfDeviceID: "me", scope: .all)
    #expect(n == 0)
    let after = try db.pool.read { conn in
        try Item.filter(Column("id") == "del").fetchOne(conn)
    }
    #expect(after?.ocrState == .failed)
}

@Test func retryFailedOCRByIDSkipsOtherOrigin() throws {
    // .id 路径必须跟 .all 一样守 origin_device——否则会把 remote-origin image 翻回
    // pending 但 OCRWorker.fetchPending 只扫 own-origin，结果永卡
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    try seedOCRItem(db: db, id: "theirs", originDevice: "other", ocrState: .failed)
    let n = try Admin.retryFailedOCR(
        dbPath: paths.mainDB, selfDeviceID: "me", scope: .id("theirs")
    )
    #expect(n == 0)
    let after = try db.pool.read { conn in
        try Item.filter(Column("id") == "theirs").fetchOne(conn)
    }
    #expect(after?.ocrState == .failed)
}

@Test func retryFailedOCRByIDSkipsSoftDeleted() throws {
    // .id 路径必须守 deleted_at_ns IS NULL——否则会在 tombstone 上翻 ocr_state，
    // 但 worker 不扫，永卡
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    try seedOCRItem(db: db, id: "del", originDevice: "me", ocrState: .failed, deletedAtNs: 999)
    let n = try Admin.retryFailedOCR(
        dbPath: paths.mainDB, selfDeviceID: "me", scope: .id("del")
    )
    #expect(n == 0)
    let after = try db.pool.read { conn in
        try Item.filter(Column("id") == "del").fetchOne(conn)
    }
    #expect(after?.ocrState == .failed)
}

private extension Character {
    var isHexDigit: Bool {
        isASCII && (isNumber || ("a"..."f").contains(self) || ("A"..."F").contains(self))
    }
}

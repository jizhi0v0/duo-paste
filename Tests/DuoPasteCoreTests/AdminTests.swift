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

@Test func retryFailedResetsOnlyFailedItems() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try Database(path: paths.mainDB, role: .client)
    // 准备：pending / acked / failed 各一条
    let pending = Item(id: "p1", originDevice: "me", capturedAtNs: 1000, kind: .text,
                      preview: "p", pushState: .pending)
    let acked = Item(id: "a1", originDevice: "me", capturedAtNs: 2000, kind: .text,
                     preview: "a", pushState: .acked, pushAttempts: 3)
    let failed1 = Item(id: "f1", originDevice: "me", capturedAtNs: 3000, kind: .text,
                       preview: "f1", pushState: .failed, pushAttempts: 50,
                       lastPushError: "max attempts: connection refused")
    let failed2 = Item(id: "f2", originDevice: "me", capturedAtNs: 4000, kind: .text,
                       preview: "f2", pushState: .failed, pushAttempts: 50,
                       lastPushError: "rejected: bad blob")
    try db.pool.write {
        try pending.insert($0)
        try acked.insert($0)
        try failed1.insert($0)
        try failed2.insert($0)
    }

    let count = try Admin.retryFailed(dbPath: paths.mainDB)
    #expect(count == 2)

    let after: [Item] = try db.pool.read { conn in
        try Item.order(Column("id")).fetchAll(conn)
    }
    #expect(after[0].id == "a1" && after[0].pushState == .acked && after[0].pushAttempts == 3)
    #expect(after[1].id == "f1" && after[1].pushState == .pending && after[1].pushAttempts == 0)
    #expect(after[1].lastPushError == nil)
    #expect(after[2].id == "f2" && after[2].pushState == .pending && after[2].pushAttempts == 0)
    #expect(after[3].id == "p1" && after[3].pushState == .pending)
}

@Test func retryFailedNoopWhenNoneFailed() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try Database(path: paths.mainDB, role: .client)
    let pending = Item(id: "p1", originDevice: "me", capturedAtNs: 1000, kind: .text,
                       preview: "p", pushState: .pending)
    try db.pool.write { try pending.insert($0) }

    let count = try Admin.retryFailed(dbPath: paths.mainDB)
    #expect(count == 0)
}

// MARK: - retry-failed-ocr

private func seedOCRItem(
    db: DuoPasteCore.Database,
    id: String,
    originDevice: String,
    kind: ItemKind = .image,
    ocrState: OCRState?,
    deletedAtNs: Int64? = nil,
    lastError: String? = "old error",
    pushState: PushState = .acked
) throws {
    let it = Item(
        id: id, originDevice: originDevice,
        capturedAtNs: 1000, kind: kind,
        preview: "p-\(id)",
        blobSha256: kind == .image ? String(repeating: "a", count: 64) : nil,
        deletedAtNs: deletedAtNs,
        pushState: pushState,
        lastPushError: lastError,
        ocrState: ocrState
    )
    try db.pool.write { try it.insert($0) }
}

@Test func retryFailedOCRResetsFailedAndSkipped() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB, role: .client)
    try seedOCRItem(db: db, id: "f1", originDevice: "me", ocrState: .failed)
    try seedOCRItem(db: db, id: "s1", originDevice: "me", ocrState: .skipped)
    try seedOCRItem(db: db, id: "d1", originDevice: "me", ocrState: .done)
    try seedOCRItem(db: db, id: "p1", originDevice: "me", ocrState: .pending)
    let n = try Admin.retryFailedOCR(dbPath: paths.mainDB, selfDeviceID: "me", scope: .all)
    #expect(n == 2)
    let after: [Item] = try db.pool.read { try Item.order(Column("id")).fetchAll($0) }
    let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    #expect(byID["f1"]?.ocrState == .pending)
    #expect(byID["f1"]?.lastPushError == nil)
    #expect(byID["s1"]?.ocrState == .pending)
    #expect(byID["s1"]?.lastPushError == nil)
    #expect(byID["d1"]?.ocrState == .done)
    #expect(byID["d1"]?.lastPushError == "old error")  // 不动
    #expect(byID["p1"]?.ocrState == .pending)
}

@Test func retryFailedOCRByIDForcesEvenDone() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB, role: .client)
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
    let db = try DuoPasteCore.Database(path: paths.mainDB, role: .client)
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

@Test func retryFailedOCRPreservesLastErrorWhenPushFailed() throws {
    // 不变量：last_push_error 列被 OCR 跟 push 共享，retry-failed-ocr 在 push 真的失败
    // 着的时候不该抹掉 push 的真实错误（"rejected: bad blob"）
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB, role: .client)
    try seedOCRItem(
        db: db, id: "double-trouble", originDevice: "me",
        ocrState: .failed,
        lastError: "rejected: bad blob",
        pushState: .failed
    )
    let n = try Admin.retryFailedOCR(dbPath: paths.mainDB, selfDeviceID: "me", scope: .all)
    #expect(n == 1)
    let after = try db.pool.read { conn in
        try Item.filter(Column("id") == "double-trouble").fetchOne(conn)
    }
    #expect(after?.ocrState == .pending)
    // push 失败的真实原因不被 OCR 重置抹掉
    #expect(after?.lastPushError == "rejected: bad blob")
}

@Test func retryFailedOCRSkipsSoftDeleted() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB, role: .client)
    try seedOCRItem(db: db, id: "del", originDevice: "me", ocrState: .failed, deletedAtNs: 999)
    let n = try Admin.retryFailedOCR(dbPath: paths.mainDB, selfDeviceID: "me", scope: .all)
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

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

// MARK: - ocrStats / rebuildOCRIndex / abortOCRQueue (plan A: 半致警告 + 一键重建/中止)

@Test func ocrStatsGroupsByStateAndOriginsOnly() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    // own-origin 各状态
    try seedOCRItem(db: db, id: "p1", originDevice: "me", ocrState: .pending)
    try seedOCRItem(db: db, id: "p2", originDevice: "me", ocrState: .pending)
    try seedOCRItem(db: db, id: "d1", originDevice: "me", ocrState: .done)
    try seedOCRItem(db: db, id: "s1", originDevice: "me", ocrState: .skipped)
    try seedOCRItem(db: db, id: "f1", originDevice: "me", ocrState: .failed)
    // peer 行 + tombstone + 非 image,都不应计入
    try seedOCRItem(db: db, id: "peer", originDevice: "other", ocrState: .pending)
    try seedOCRItem(db: db, id: "del", originDevice: "me", ocrState: .pending, deletedAtNs: 1)
    try seedOCRItem(db: db, id: "txt", originDevice: "me", kind: .text, ocrState: nil)

    let stats = try Admin.ocrStats(dbPath: paths.mainDB, selfDeviceID: "me")
    #expect(stats.pending == 2)
    #expect(stats.done == 1)
    #expect(stats.skipped == 1)
    #expect(stats.failed == 1)
    #expect(stats.total == 5)
}

/// 关键回归:`ocrStats` 必须跟 OCRWorker.fetchPending 同口径——`kind='file'`
/// 但 `blob_mime LIKE 'image/%'` + 有 blob 的行也是 OCR 路径覆盖范围,必须计入
@Test func ocrStatsIncludesFileKindWithImageMime() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    let imageBlob = String(repeating: "a", count: 64)
    // file + image mime + has blob → 算
    let it1 = Item(id: "fa", originDevice: "me",
                   capturedAtNs: 1000, kind: .file,
                   preview: "/tmp/x.png",
                   blobSha256: imageBlob,
                   blobMime: "image/png",
                   ocrState: .done)
    try db.pool.write { try it1.insert($0) }
    // file + image mime + 无 blob → 不算(blob_sha256 IS NULL)
    let it2 = Item(id: "fb", originDevice: "me",
                   capturedAtNs: 1001, kind: .file,
                   preview: "/tmp/y.png",
                   blobMime: "image/png",
                   ocrState: .pending)
    try db.pool.write { try it2.insert($0) }
    // file + 非 image mime → 不算
    let it3 = Item(id: "fc", originDevice: "me",
                   capturedAtNs: 1002, kind: .file,
                   preview: "/tmp/z.pdf",
                   blobSha256: imageBlob,
                   blobMime: "application/pdf",
                   ocrState: .pending)
    try db.pool.write { try it3.insert($0) }
    // 真 image kind → 算
    try seedOCRItem(db: db, id: "img", originDevice: "me", ocrState: .pending)

    let stats = try Admin.ocrStats(dbPath: paths.mainDB, selfDeviceID: "me")
    #expect(stats.done == 1)      // fa
    #expect(stats.pending == 1)   // img
    #expect(stats.total == 2)
}

// MARK: - refillMissingImageBlobs (lazy migration)

@Test func refillReadsLocalFileAndUpdatesRow() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    // 写一个真实 PNG 字节文件
    let tmpPNG = dir.appendingPathComponent("CleanShot.png")
    let payload = Data("fake-png-bytes-for-test-\(UUID().uuidString)".utf8)
    try payload.write(to: tmpPNG)
    // 种子行:本机 file + 图片扩展 + 无 blob
    let it = Item(id: "row-x", originDevice: "me",
                  capturedAtNs: 1000, kind: .file,
                  preview: tmpPNG.path)
    try db.pool.write { try it.insert($0) }

    let report = try Admin.refillMissingImageBlobs(
        dbPath: paths.mainDB,
        blobsDir: paths.blobsDir,
        selfDeviceID: "me",
        maxBlobBytes: 32 * 1024 * 1024
    )
    #expect(report.scanned == 1)
    #expect(report.refilled == 1)
    #expect(report.fileMissing == 0)

    let after = try db.pool.read { conn in
        try Item.filter(Column("id") == "row-x").fetchOne(conn)
    }
    #expect(after?.blobSha256 != nil)
    #expect(after?.blobSize == Int64(payload.count))
    #expect(after?.blobMime == "image/png")
    #expect(after?.ocrState == .pending)
    // BlobStore 里字节确实在
    let store = BlobStore(root: paths.blobsDir)
    #expect(store.locate(sha256: after?.blobSha256 ?? "") != nil)
}

@Test func refillSkipsPeerOriginAndHasBlobAndTombstone() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    let tmp = dir.appendingPathComponent("x.png")
    try Data("png".utf8).write(to: tmp)

    // peer 行 + 同条件 → 不该 refill(只动 own-origin)
    let peer = Item(id: "peer", originDevice: "other",
                    capturedAtNs: 1000, kind: .file, preview: tmp.path)
    try db.pool.write { try peer.insert($0) }
    // own 行但已有 blob → 不该再 refill
    let already = Item(id: "already", originDevice: "me",
                       capturedAtNs: 1001, kind: .file,
                       preview: tmp.path,
                       blobSha256: String(repeating: "0", count: 64),
                       blobMime: "image/png")
    try db.pool.write { try already.insert($0) }
    // 软删行 → 不该 refill
    let del = Item(id: "del", originDevice: "me",
                   capturedAtNs: 1002, kind: .file,
                   preview: tmp.path, deletedAtNs: 1)
    try db.pool.write { try del.insert($0) }
    // 非图片扩展(.txt) → 不该 refill
    let txt = Item(id: "txt", originDevice: "me",
                   capturedAtNs: 1003, kind: .file,
                   preview: "/tmp/foo.txt")
    try db.pool.write { try txt.insert($0) }

    let report = try Admin.refillMissingImageBlobs(
        dbPath: paths.mainDB,
        blobsDir: paths.blobsDir,
        selfDeviceID: "me",
        maxBlobBytes: 32 * 1024 * 1024
    )
    #expect(report.scanned == 0)   // SQL WHERE 已经过滤掉所有 4 个
    #expect(report.refilled == 0)
}

@Test func refillRecordsFileMissingWhenPathGone() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    // 路径指向不存在的文件
    let it = Item(id: "ghost", originDevice: "me",
                  capturedAtNs: 1000, kind: .file,
                  preview: "/tmp/never-existed-\(UUID().uuidString).png")
    try db.pool.write { try it.insert($0) }

    let report = try Admin.refillMissingImageBlobs(
        dbPath: paths.mainDB,
        blobsDir: paths.blobsDir,
        selfDeviceID: "me",
        maxBlobBytes: 32 * 1024 * 1024
    )
    #expect(report.scanned == 1)
    #expect(report.fileMissing == 1)
    #expect(report.refilled == 0)
    // 行字段没被动
    let after = try db.pool.read { conn in
        try Item.filter(Column("id") == "ghost").fetchOne(conn)
    }
    #expect(after?.blobSha256 == nil)
    #expect(after?.ocrState == nil)
}

@Test func refillIsIdempotent() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    let tmp = dir.appendingPathComponent("x.png")
    try Data("png-bytes".utf8).write(to: tmp)
    let it = Item(id: "row", originDevice: "me",
                  capturedAtNs: 1000, kind: .file, preview: tmp.path)
    try db.pool.write { try it.insert($0) }

    let r1 = try Admin.refillMissingImageBlobs(
        dbPath: paths.mainDB,
        blobsDir: paths.blobsDir,
        selfDeviceID: "me",
        maxBlobBytes: 32 * 1024 * 1024
    )
    #expect(r1.refilled == 1)

    // 第二次跑:行已有 blob,WHERE 过滤掉,scanned=0
    let r2 = try Admin.refillMissingImageBlobs(
        dbPath: paths.mainDB,
        blobsDir: paths.blobsDir,
        selfDeviceID: "me",
        maxBlobBytes: 32 * 1024 * 1024
    )
    #expect(r2.scanned == 0)
    #expect(r2.refilled == 0)
}

@Test func refillSkipsMultilinePreview() throws {
    // PasteboardWatcher 多文件 capture 时 preview 是 \n-join 多路径——单 sha 无法对应,跳过
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    let it = Item(id: "multi", originDevice: "me",
                  capturedAtNs: 1000, kind: .file,
                  preview: "/tmp/a.png\n/tmp/b.png")
    try db.pool.write { try it.insert($0) }

    let report = try Admin.refillMissingImageBlobs(
        dbPath: paths.mainDB,
        blobsDir: paths.blobsDir,
        selfDeviceID: "me",
        maxBlobBytes: 32 * 1024 * 1024
    )
    #expect(report.scanned == 1)
    #expect(report.nonAbsolute == 1)
    #expect(report.refilled == 0)
}

@Test func refillSkipsOversizedFile() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    let tmp = dir.appendingPathComponent("big.png")
    try Data(repeating: 0xAA, count: 4096).write(to: tmp)
    let it = Item(id: "big", originDevice: "me",
                  capturedAtNs: 1000, kind: .file, preview: tmp.path)
    try db.pool.write { try it.insert($0) }

    // cap 设 1KB,4KB 文件超 cap
    let report = try Admin.refillMissingImageBlobs(
        dbPath: paths.mainDB,
        blobsDir: paths.blobsDir,
        selfDeviceID: "me",
        maxBlobBytes: 1024
    )
    #expect(report.scanned == 1)
    #expect(report.tooLarge == 1)
    #expect(report.refilled == 0)
}

@Test func rebuildOCRIndexTurnsDoneIntoPendingOnlyForOwnImage() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    try seedOCRItem(db: db, id: "own-done", originDevice: "me", ocrState: .done)
    try seedOCRItem(db: db, id: "own-skipped", originDevice: "me", ocrState: .skipped)
    try seedOCRItem(db: db, id: "own-failed", originDevice: "me", ocrState: .failed)
    try seedOCRItem(db: db, id: "own-pending", originDevice: "me", ocrState: .pending)
    try seedOCRItem(db: db, id: "peer-done", originDevice: "other", ocrState: .done)
    try seedOCRItem(db: db, id: "del-done", originDevice: "me", ocrState: .done, deletedAtNs: 1)

    let n = try Admin.rebuildOCRIndex(dbPath: paths.mainDB, selfDeviceID: "me")
    #expect(n == 1)

    let after: [Item] = try db.pool.read { try Item.order(Column("id")).fetchAll($0) }
    let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    #expect(byID["own-done"]?.ocrState == .pending)
    #expect(byID["own-skipped"]?.ocrState == .skipped)   // skipped 不动
    #expect(byID["own-failed"]?.ocrState == .failed)     // failed 不动
    #expect(byID["own-pending"]?.ocrState == .pending)   // 已 pending 不重复算
    #expect(byID["peer-done"]?.ocrState == .done)        // 跨 origin 不动,单一归属契约
    #expect(byID["del-done"]?.ocrState == .done)         // tombstone 不动
}

@Test func abortOCRQueueTurnsPendingIntoSkippedOnlyForOwnImage() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    try seedOCRItem(db: db, id: "own-p1", originDevice: "me", ocrState: .pending)
    try seedOCRItem(db: db, id: "own-p2", originDevice: "me", ocrState: .pending)
    try seedOCRItem(db: db, id: "own-done", originDevice: "me", ocrState: .done)
    try seedOCRItem(db: db, id: "peer-p", originDevice: "other", ocrState: .pending)
    try seedOCRItem(db: db, id: "del-p", originDevice: "me", ocrState: .pending, deletedAtNs: 1)

    let n = try Admin.abortOCRQueue(dbPath: paths.mainDB, selfDeviceID: "me")
    #expect(n == 2)

    let after: [Item] = try db.pool.read { try Item.order(Column("id")).fetchAll($0) }
    let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    #expect(byID["own-p1"]?.ocrState == .skipped)
    #expect(byID["own-p2"]?.ocrState == .skipped)
    #expect(byID["own-done"]?.ocrState == .done)
    #expect(byID["peer-p"]?.ocrState == .pending)
    #expect(byID["del-p"]?.ocrState == .pending)
}

/// abort 完 retry-failed-ocr 能拉回 pending——验证两个动作组合形成可逆 cycle
@Test func abortThenRetryRestoresPendingState() throws {
    let dir = tempDir()
    let paths = Paths(root: dir)
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    try seedOCRItem(db: db, id: "p1", originDevice: "me", ocrState: .pending)

    _ = try Admin.abortOCRQueue(dbPath: paths.mainDB, selfDeviceID: "me")
    let mid = try db.pool.read { conn in
        try Item.filter(Column("id") == "p1").fetchOne(conn)
    }
    #expect(mid?.ocrState == .skipped)

    let restored = try Admin.retryFailedOCR(dbPath: paths.mainDB, selfDeviceID: "me", scope: .all)
    #expect(restored == 1)
    let after = try db.pool.read { conn in
        try Item.filter(Column("id") == "p1").fetchOne(conn)
    }
    #expect(after?.ocrState == .pending)
}

private extension Character {
    var isHexDigit: Bool {
        isASCII && (isNumber || ("a"..."f").contains(self) || ("A"..."F").contains(self))
    }
}

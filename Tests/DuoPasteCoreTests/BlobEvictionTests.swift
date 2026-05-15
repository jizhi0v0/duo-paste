import Testing
import Foundation
import CryptoKit
import GRDB
@testable import DuoPasteCore

/// 基建测试：BlobStore.evict/size + Database.refCountForBlob/oldestEvictableShas。
/// 上层驱逐编排（BlobEvictor / ENOSPC catch / watermark scheduler）的测试在落地那一步加。

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-evict-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeStore(at dir: URL) -> BlobStore {
    let root = dir.appendingPathComponent("blobs")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root)
}

private func makeDB(at dir: URL) throws -> DuoPasteCore.Database {
    let dbDir = dir.appendingPathComponent("db")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    return try DuoPasteCore.Database(path: dbDir.appendingPathComponent("main.sqlite"))
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 测试用助手：直接 SQL 插入 item 行
private func insertItem(
    _ db: DuoPasteCore.Database,
    id: String,
    sha: String?,
    capturedAtNs: Int64,
    pinned: Bool = false,
    deletedAtNs: Int64? = nil,
    kind: String = "image",
    origin: String = "self"
) throws {
    try db.pool.write { d in
        let blobSize: Int64? = sha == nil ? nil : 100
        let blobMime: String? = sha == nil ? nil : "image/png"
        try d.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
               ocr_state, extracted_text, extracted_text_source)
            VALUES (?, ?, ?, ?, ?,
                    NULL, NULL, NULL, NULL,
                    ?, ?, ?, ?, ?,
                    NULL, NULL, NULL)
        """, arguments: [
            id, origin, capturedAtNs, capturedAtNs, kind,
            sha, blobSize, blobMime,
            pinned ? 1 : 0, deletedAtNs
        ])
    }
}

// MARK: - BlobStore.evict

@Test func evictRemovesFileAndReportsSize() throws {
    let store = makeStore(at: tempDir())
    let data = Data(repeating: 0x42, count: 1024)
    let info = try store.put(data)
    #expect(store.exists(sha256: info.sha256))

    let outcome = store.evict(sha256: info.sha256)
    switch outcome {
    case .deleted(let size):
        #expect(size == 1024)
    default:
        Issue.record("evict 应返回 .deleted，实际 \(outcome)")
    }
    #expect(!store.exists(sha256: info.sha256))
}

@Test func evictNotFoundReturnsNotFound() throws {
    let store = makeStore(at: tempDir())
    let fakeSha = String(repeating: "ab", count: 32)
    let outcome = store.evict(sha256: fakeSha)
    if case .notFound = outcome { } else {
        Issue.record("evict 未存在 sha 应返回 .notFound，实际 \(outcome)")
    }
}

@Test func sizeReportsBytes() throws {
    let store = makeStore(at: tempDir())
    let data = Data((0..<4096).map { UInt8($0 & 0xFF) })
    let info = try store.put(data)
    #expect(store.size(sha256: info.sha256) == 4096)
}

@Test func sizeNilWhenMissing() {
    let store = makeStore(at: tempDir())
    let fakeSha = String(repeating: "cd", count: 32)
    #expect(store.size(sha256: fakeSha) == nil)
}

// MARK: - Database.refCountForBlob

@Test func refCountZeroWhenNoRows() async throws {
    let db = try makeDB(at: tempDir())
    let fakeSha = String(repeating: "ee", count: 32)
    #expect(try db.refCountForBlob(sha256: fakeSha) == 0)
}

@Test func refCountSkipsTombstones() async throws {
    let db = try makeDB(at: tempDir())
    let sha = String(repeating: "11", count: 32)
    try insertItem(db, id: "a", sha: sha, capturedAtNs: 1_000)
    try insertItem(db, id: "b", sha: sha, capturedAtNs: 2_000, deletedAtNs: 3_000)
    // 只有 a 是活跃 ref；b 是 tombstone 不算
    #expect(try db.refCountForBlob(sha256: sha) == 1)
}

@Test func refCountCountsMultipleOrigins() async throws {
    let db = try makeDB(at: tempDir())
    let sha = String(repeating: "22", count: 32)
    try insertItem(db, id: "a", sha: sha, capturedAtNs: 1_000, origin: "self")
    try insertItem(db, id: "b", sha: sha, capturedAtNs: 1_100, origin: "peer-X")
    try insertItem(db, id: "c", sha: sha, capturedAtNs: 1_200, origin: "peer-Y")
    #expect(try db.refCountForBlob(sha256: sha) == 3)
}

// MARK: - Database.oldestEvictableShas

@Test func oldestEvictableExcludesPinned() async throws {
    let db = try makeDB(at: tempDir())
    let sha1 = String(repeating: "11", count: 32)
    let sha2 = String(repeating: "22", count: 32)
    try insertItem(db, id: "old-pinned", sha: sha1, capturedAtNs: 1_000, pinned: true)
    try insertItem(db, id: "new-unpinned", sha: sha2, capturedAtNs: 2_000, pinned: false)

    let rows = try db.oldestEvictableShas(limit: 10)
    // pinned sha1 必须被排除——硬不变量
    #expect(rows.map { $0.sha } == [sha2])
}

@Test func oldestEvictableExcludesTombstones() async throws {
    let db = try makeDB(at: tempDir())
    let sha1 = String(repeating: "33", count: 32)
    let sha2 = String(repeating: "44", count: 32)
    try insertItem(db, id: "tombstoned", sha: sha1, capturedAtNs: 500, deletedAtNs: 600)
    try insertItem(db, id: "live", sha: sha2, capturedAtNs: 1_000)

    let rows = try db.oldestEvictableShas(limit: 10)
    #expect(rows.map { $0.sha } == [sha2])
}

@Test func oldestEvictableExcludesTextOnly() async throws {
    let db = try makeDB(at: tempDir())
    let sha = String(repeating: "55", count: 32)
    try insertItem(db, id: "text-row", sha: nil, capturedAtNs: 100, kind: "text")
    try insertItem(db, id: "image-row", sha: sha, capturedAtNs: 200)

    let rows = try db.oldestEvictableShas(limit: 10)
    // text-row 没 blob，必须排除——用户要"保留文本"
    #expect(rows.map { $0.sha } == [sha])
}

@Test func oldestEvictableOrdersByCapturedAtAsc() async throws {
    let db = try makeDB(at: tempDir())
    let shaA = String(repeating: "aa", count: 32)
    let shaB = String(repeating: "bb", count: 32)
    let shaC = String(repeating: "cc", count: 32)
    try insertItem(db, id: "c-newest", sha: shaC, capturedAtNs: 3_000)
    try insertItem(db, id: "a-oldest", sha: shaA, capturedAtNs: 1_000)
    try insertItem(db, id: "b-middle", sha: shaB, capturedAtNs: 2_000)

    let rows = try db.oldestEvictableShas(limit: 10)
    #expect(rows.map { $0.sha } == [shaA, shaB, shaC])
}

@Test func oldestEvictableDedupsSameSha() async throws {
    // 同 sha 跨 origin 多行（mesh dedup 场景）只算一个 sha；MIN(captured) 决定排序
    let db = try makeDB(at: tempDir())
    let shared = String(repeating: "77", count: 32)
    let other = String(repeating: "88", count: 32)
    try insertItem(db, id: "share-self", sha: shared, capturedAtNs: 500, origin: "self")
    try insertItem(db, id: "share-peer", sha: shared, capturedAtNs: 600, origin: "peer-A")
    try insertItem(db, id: "other-row",  sha: other,  capturedAtNs: 700)

    let rows = try db.oldestEvictableShas(limit: 10)
    #expect(rows.count == 2)
    // shared 出现一次且排前面（MIN=500 < 700）
    #expect(rows.map { $0.sha } == [shared, other])
}

@Test func oldestEvictableHonorsLimit() async throws {
    let db = try makeDB(at: tempDir())
    for i in 0..<5 {
        let sha = String(repeating: String(format: "%02x", i), count: 32)
        try insertItem(db, id: "row-\(i)", sha: sha, capturedAtNs: Int64(1_000 + i))
    }
    let rows = try db.oldestEvictableShas(limit: 2)
    #expect(rows.count == 2)
}

// MARK: - BlobEvictor.evictOneOldest

@Test func evictorDeletesOldestBlobByCapturedAt() async throws {
    let dir = tempDir()
    let store = makeStore(at: dir)
    let db = try makeDB(at: dir)
    // 写 3 个 blob，按 captured_at_ns 排序：old < mid < new
    let oldData = Data(repeating: 0x01, count: 100)
    let midData = Data(repeating: 0x02, count: 100)
    let newData = Data(repeating: 0x03, count: 100)
    let oldInfo = try store.put(oldData)
    let midInfo = try store.put(midData)
    let newInfo = try store.put(newData)
    try insertItem(db, id: "old", sha: oldInfo.sha256, capturedAtNs: 1_000)
    try insertItem(db, id: "mid", sha: midInfo.sha256, capturedAtNs: 2_000)
    try insertItem(db, id: "new", sha: newInfo.sha256, capturedAtNs: 3_000)

    let evictor = BlobEvictor(database: db, blobs: store)
    let freed = try evictor.evictOneOldest()
    #expect(freed == true)
    // old 被驱逐——fs 没了，DB 行还在（CloudBadge 状态）
    #expect(!store.exists(sha256: oldInfo.sha256))
    #expect(store.exists(sha256: midInfo.sha256))
    #expect(store.exists(sha256: newInfo.sha256))
    // DB 行没动
    let count = try db.refCountForBlob(sha256: oldInfo.sha256)
    #expect(count == 1)
}

@Test func evictorReturnsFalseWhenNothingEvictable() async throws {
    let dir = tempDir()
    let store = makeStore(at: dir)
    let db = try makeDB(at: dir)
    // 一条 pinned 行 + 一条 text 行——都不该被驱逐
    let pinnedBlob = try store.put(Data(repeating: 0x42, count: 50))
    try insertItem(db, id: "pinned", sha: pinnedBlob.sha256, capturedAtNs: 100, pinned: true)
    try insertItem(db, id: "text", sha: nil, capturedAtNs: 200, kind: "text")

    let evictor = BlobEvictor(database: db, blobs: store)
    let freed = try evictor.evictOneOldest()
    #expect(freed == false)
    // pinned blob 字节未动
    #expect(store.exists(sha256: pinnedBlob.sha256))
}

@Test func evictorSkipsCandidatesMissingFromBlobStore() async throws {
    // DB 有 sha 但 BlobStore 没字节（optimized-mode / 已被驱逐过的行）：跳过它，
    // 推进到下一个有字节的候选
    let dir = tempDir()
    let store = makeStore(at: dir)
    let db = try makeDB(at: dir)
    let realBlob = try store.put(Data(repeating: 0xAB, count: 200))
    let phantomSha = String(repeating: "ff", count: 32)
    // phantom 排前（更老）
    try insertItem(db, id: "phantom", sha: phantomSha, capturedAtNs: 500)
    try insertItem(db, id: "real", sha: realBlob.sha256, capturedAtNs: 1_000)

    let evictor = BlobEvictor(database: db, blobs: store)
    let freed = try evictor.evictOneOldest()
    #expect(freed == true)
    // real 被驱逐（phantom 跳过不消耗 evict 配额）
    #expect(!store.exists(sha256: realBlob.sha256))
}

// MARK: - BlobStore.retryOnFull retry loop

@Test func retryLoopReturnsImmediatelyWhenPutSucceeds() throws {
    var putCalls = 0
    var evictCalls = 0
    let info = try BlobStore.retryOnFull(
        maxRetries: 64,
        evictor: { evictCalls += 1; return true },
        put: {
            putCalls += 1
            return BlobInfo(sha256: String(repeating: "00", count: 32),
                            size: 0,
                            path: URL(fileURLWithPath: "/dev/null"),
                            wasExisting: false)
        }
    )
    #expect(putCalls == 1)
    #expect(evictCalls == 0)
    #expect(info.size == 0)
}

@Test func retryLoopRetriesUntilEvictorReturnsFalse() {
    // 模拟磁盘永远满：put 永远抛 ENOSPC；evictor 头三次返回 true 然后返回 false
    var putCalls = 0
    var evictCalls = 0
    let enospc = NSError(domain: NSPOSIXErrorDomain, code: 28)
    #expect(throws: (any Error).self) {
        _ = try BlobStore.retryOnFull(
            maxRetries: 64,
            evictor: {
                evictCalls += 1
                return evictCalls <= 3  // 第 4 次返回 false → 放弃
            },
            put: {
                putCalls += 1
                throw enospc
            }
        )
    }
    // put 被调 4 次（初次 + 3 次 evict 后重试）；evict 被调 4 次（第 4 次返 false）
    #expect(putCalls == 4)
    #expect(evictCalls == 4)
}

@Test func retryLoopRethrowsNonENOSPCImmediately() {
    var putCalls = 0
    var evictCalls = 0
    let permErr = NSError(domain: NSPOSIXErrorDomain, code: 13)  // EACCES
    #expect(throws: (any Error).self) {
        _ = try BlobStore.retryOnFull(
            maxRetries: 64,
            evictor: { evictCalls += 1; return true },
            put: { putCalls += 1; throw permErr }
        )
    }
    // 非 ENOSPC 立即抛——不该触发 evictor
    #expect(putCalls == 1)
    #expect(evictCalls == 0)
}

@Test func retryLoopHonorsMaxRetries() {
    var putCalls = 0
    let enospc = NSError(domain: NSPOSIXErrorDomain, code: 28)
    #expect(throws: (any Error).self) {
        _ = try BlobStore.retryOnFull(
            maxRetries: 2,
            evictor: { true },  // 永远有空间释放
            put: { putCalls += 1; throw enospc }
        )
    }
    // 初次 + 2 次 retry = 3
    #expect(putCalls == 3)
}

// MARK: - DiskFull detection

@Test func diskFullDetectsPosixENOSPC() {
    let err = NSError(domain: NSPOSIXErrorDomain, code: 28)
    #expect(DiskFull.isOutOfSpace(err))
}

@Test func diskFullDetectsCocoaWriteOutOfSpace() {
    let err = NSError(domain: NSCocoaErrorDomain, code: 640)
    #expect(DiskFull.isOutOfSpace(err))
}

@Test func diskFullDetectsCocoaWrappingPosix() {
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: 28)
    let wrapped = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: underlying]
    )
    #expect(DiskFull.isOutOfSpace(wrapped))
}

@Test func diskFullRejectsUnrelatedErrors() {
    let eacces = NSError(domain: NSPOSIXErrorDomain, code: 13)
    let eperm = NSError(domain: NSPOSIXErrorDomain, code: 1)
    let random = NSError(domain: "io.example", code: 999)
    #expect(!DiskFull.isOutOfSpace(eacces))
    #expect(!DiskFull.isOutOfSpace(eperm))
    #expect(!DiskFull.isOutOfSpace(random))
}

// MARK: - BlobEvictor.evictToWatermark

/// 用一组 LRU 候选 + mock availableBytes 验证水位驱逐路径
private func setupWatermarkScenario(
    blobCount: Int,
    blobSize: Int = 1_000
) throws -> (store: BlobStore, db: DuoPasteCore.Database, shas: [String]) {
    let dir = tempDir()
    let store = makeStore(at: dir)
    let db = try makeDB(at: dir)
    var shas: [String] = []
    for i in 0..<blobCount {
        let data = Data(repeating: UInt8(i & 0xFF), count: blobSize)
        let info = try store.put(data)
        shas.append(info.sha256)
        try insertItem(db, id: "row-\(i)", sha: info.sha256, capturedAtNs: Int64(1_000 + i))
    }
    return (store, db, shas)
}

@Test func watermarkNoOpWhenAboveLow() async throws {
    let (store, db, shas) = try setupWatermarkScenario(blobCount: 3)
    let evictor = BlobEvictor(database: db, blobs: store)
    let result = try evictor.evictToWatermark(
        lowBytes: 1_000,
        highBytes: 5_000,
        availableBytes: { 10_000 }  // 远高于 low
    )
    #expect(result.freed == 0)
    #expect(result.capHit == false)
    // 所有 blob 还在
    for sha in shas {
        #expect(store.exists(sha256: sha))
    }
}

@Test func watermarkNilAvailableSkipsEviction() async throws {
    let (store, db, shas) = try setupWatermarkScenario(blobCount: 3)
    let evictor = BlobEvictor(database: db, blobs: store)
    let result = try evictor.evictToWatermark(
        lowBytes: 1_000,
        highBytes: 5_000,
        availableBytes: { nil }  // 卷可用空间不可知
    )
    // nil 不该当 0 触发 aggressive GC
    #expect(result.freed == 0)
    for sha in shas {
        #expect(store.exists(sha256: sha))
    }
}

@Test func watermarkEvictsUntilHigh() async throws {
    let (store, db, shas) = try setupWatermarkScenario(blobCount: 20)
    let evictor = BlobEvictor(database: db, blobs: store)

    // mock 可用空间随 evict 数线性增长——每次读取后加 100 bytes
    var simulatedAvailable: Int64 = 500
    let result = try evictor.evictToWatermark(
        lowBytes: 1_000,
        highBytes: 2_000,
        availableBytes: {
            defer { simulatedAvailable += 100 }
            return simulatedAvailable
        }
    )
    // 调用序列：
    //   初始读: 返回 500, initial=500（< low=1000 → 进入 eviction），simAvail→600
    //   loop iter N: 读 = 500 + 100*N。N=15 时读 2000 ≥ high=2000，break。freed=14
    #expect(result.freed == 14)
    #expect(result.capHit == false)
    // 前 14 个（最老的）被驱逐
    for i in 0..<14 {
        #expect(!store.exists(sha256: shas[i]))
    }
    // 后 6 个还在
    for i in 14..<20 {
        #expect(store.exists(sha256: shas[i]))
    }
}

@Test func watermarkStopsWhenNothingEvictable() async throws {
    let (store, db, shas) = try setupWatermarkScenario(blobCount: 3)
    let evictor = BlobEvictor(database: db, blobs: store)
    let result = try evictor.evictToWatermark(
        lowBytes: 10_000,
        highBytes: 20_000,
        availableBytes: { 100 }  // 永远低于阈值
    )
    // 只有 3 个 blob 可驱逐——超过就 evictOneOldest=false 提前结束
    #expect(result.freed == 3)
    #expect(result.capHit == false)
    for sha in shas {
        #expect(!store.exists(sha256: sha))
    }
}

@Test func watermarkHonorsPerTickCap() async throws {
    let (store, db, _) = try setupWatermarkScenario(blobCount: 100)
    let evictor = BlobEvictor(database: db, blobs: store)
    let result = try evictor.evictToWatermark(
        lowBytes: 10_000,
        highBytes: 20_000,
        perTickCap: 5,
        availableBytes: { 100 }  // 永远低于
    )
    #expect(result.freed == 5)
    #expect(result.capHit == true)
}

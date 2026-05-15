import Testing
import Foundation
import CryptoKit
import GRDB
@testable import DuoPasteCore

/// `Admin.fetchMissingBlobs` 纯函数测试。注入 fetcher closure 模拟 peer GET /blob 响应，
/// 准备 DB 行 + BlobStore 状态，断言 report 字段 + 实际落盘字节。
/// CLI 包装层（runMeshFetchMissing）的 argv 解析不单独测。

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-fetch-missing-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeDB(at dir: URL) throws -> URL {
    let dbDir = dir.appendingPathComponent("db")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let p = dbDir.appendingPathComponent("main.sqlite")
    _ = try Database(path: p)
    return p
}

private func makeBlobs(at dir: URL) throws -> BlobStore {
    let root = dir.appendingPathComponent("blobs")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root)
}

private func sha256Hex(_ data: Data) -> String {
    let d = SHA256.hash(data: data)
    return d.map { String(format: "%02x", $0) }.joined()
}

/// 在 item 表插入一条 peer-origin image 行（默认 origin="peer-A"），不写 blob 字节
private func insertPeerImage(_ dbPath: URL, id: String, sha: String, origin: String = "peer-A", deleted: Int64? = nil) throws {
    let pool = try DatabasePool(path: dbPath.path)
    try pool.write { db in
        try db.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
               ocr_state, extracted_text, extracted_text_source)
            VALUES (?, ?, ?, ?, 'image',
                    NULL, NULL, NULL, NULL,
                    ?, 100, 'image/png', 0, ?,
                    NULL, NULL, NULL)
        """, arguments: [id, origin, 1_000, 1_000, sha, deleted])
    }
}

@Test func fetchMissingBlobsEmptyDBReturnsZero() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let r = try await Admin.fetchMissingBlobs(
        dbPath: dbPath,
        selfDeviceID: "self",
        blobs: blobs,
        fetcher: { _ in
            Issue.record("空 DB 不该调 fetcher")
            return .notFound
        }
    )
    #expect(r.totalMissing == 0)
    #expect(r.fetched == 0)
    #expect(r.failed == 0)
}

@Test func fetchMissingBlobsHappyPath() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let bytes1 = Data((0..<200).map { UInt8($0 & 0xFF) })
    let sha1 = sha256Hex(bytes1)
    let bytes2 = Data(repeating: 0x42, count: 64)
    let sha2 = sha256Hex(bytes2)
    try insertPeerImage(dbPath, id: "img-1", sha: sha1)
    try insertPeerImage(dbPath, id: "img-2", sha: sha2)

    let mapping: [String: Data] = [sha1: bytes1, sha2: bytes2]
    let r = try await Admin.fetchMissingBlobs(
        dbPath: dbPath,
        selfDeviceID: "self",
        blobs: blobs,
        fetcher: { sha in
            if let data = mapping[sha] { return .found(data) }
            return .notFound
        }
    )
    #expect(r.totalMissing == 2)
    #expect(r.fetched == 2)
    #expect(r.failed == 0)
    #expect(blobs.exists(sha256: sha1))
    #expect(blobs.exists(sha256: sha2))
}

@Test func fetchMissingBlobsSkipsOwnOrigin() async throws {
    // own-origin 缺 blob 不该被扫——本机 BlobStore 是源，peer 上拉也没意义
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let bytes = Data([0xAA])
    let sha = sha256Hex(bytes)
    try insertPeerImage(dbPath, id: "own-img", sha: sha, origin: "self")

    let r = try await Admin.fetchMissingBlobs(
        dbPath: dbPath,
        selfDeviceID: "self",
        blobs: blobs,
        fetcher: { _ in
            Issue.record("own-origin 不该触发 fetcher")
            return .notFound
        }
    )
    #expect(r.totalMissing == 0)
    #expect(r.fetched == 0)
}

@Test func fetchMissingBlobsSkipsTombstone() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let bytes = Data([0xBB])
    let sha = sha256Hex(bytes)
    try insertPeerImage(dbPath, id: "tombed", sha: sha, deleted: 500)

    let r = try await Admin.fetchMissingBlobs(
        dbPath: dbPath,
        selfDeviceID: "self",
        blobs: blobs,
        fetcher: { _ in
            Issue.record("tombstone 不该触发 fetcher")
            return .notFound
        }
    )
    #expect(r.totalMissing == 0)
}

@Test func fetchMissingBlobsSkipsAlreadyPresent() async throws {
    // 已落盘的 sha 在扫描层就排除——scanMissingPeerBlobs 走 BlobStore.exists 过滤
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let bytes = Data([0xCC])
    let sha = sha256Hex(bytes)
    _ = try blobs.put(bytes)
    try insertPeerImage(dbPath, id: "present", sha: sha)

    let r = try await Admin.fetchMissingBlobs(
        dbPath: dbPath,
        selfDeviceID: "self",
        blobs: blobs,
        fetcher: { _ in
            Issue.record("已落盘字节不该触发 fetcher")
            return .notFound
        }
    )
    #expect(r.totalMissing == 0)
}

@Test func fetchMissingBlobsDryRunDoesNotCallFetcher() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let bytes = Data([0xDD])
    let sha = sha256Hex(bytes)
    try insertPeerImage(dbPath, id: "img-dry", sha: sha)

    let r = try await Admin.fetchMissingBlobs(
        dbPath: dbPath,
        selfDeviceID: "self",
        blobs: blobs,
        fetcher: { _ in
            Issue.record("dryRun 不该调 fetcher")
            return .notFound
        },
        dryRun: true
    )
    #expect(r.dryRun == true)
    #expect(r.totalMissing == 1)
    #expect(r.skipped == 1)
    #expect(r.fetched == 0)
    #expect(!blobs.exists(sha256: sha))
}

@Test func fetchMissingBlobsHandlesNotFound() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let sha = sha256Hex(Data([0xEE]))
    try insertPeerImage(dbPath, id: "ghost", sha: sha)

    let r = try await Admin.fetchMissingBlobs(
        dbPath: dbPath,
        selfDeviceID: "self",
        blobs: blobs,
        fetcher: { _ in .notFound }
    )
    #expect(r.totalMissing == 1)
    #expect(r.fetched == 0)
    #expect(r.failed == 1)
    #expect(r.failures.count == 1)
    #expect(r.failures[0].reason.contains("404") || r.failures[0].reason.contains("404"))
}

@Test func fetchMissingBlobsRejectsCorruptBytes() async throws {
    // peer 返回的字节 sha 跟期望不一致 → putVerified 拒；不污染 BlobStore
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let realBytes = Data([0x01, 0x02])
    let sha = sha256Hex(realBytes)
    try insertPeerImage(dbPath, id: "tamper", sha: sha)

    // fetcher 返 .found 但字节内容是别的 sha——putVerified 应该捕获
    let wrongBytes = Data([0xFF, 0xFF, 0xFF])
    let r = try await Admin.fetchMissingBlobs(
        dbPath: dbPath,
        selfDeviceID: "self",
        blobs: blobs,
        fetcher: { _ in .found(wrongBytes) }
    )
    #expect(r.fetched == 0)
    #expect(r.failed == 1)
    #expect(!blobs.exists(sha256: sha))
}

@Test func fetchMissingBlobsConcurrencyCountsAllShas() async throws {
    // 多 sha 时所有都被处理（不漏不重）；concurrency=2 测滚动入队路径
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let n = 6
    var responses: [String: Data] = [:]
    for i in 0..<n {
        let bytes = Data([UInt8(i)])
        let sha = sha256Hex(bytes)
        try insertPeerImage(dbPath, id: "img-\(i)", sha: sha)
        responses[sha] = bytes
    }
    let finalResponses = responses
    let r = try await Admin.fetchMissingBlobs(
        dbPath: dbPath,
        selfDeviceID: "self",
        blobs: blobs,
        fetcher: { sha in
            if let data = finalResponses[sha] { return .found(data) }
            return .notFound
        },
        concurrency: 2
    )
    #expect(r.totalMissing == n)
    #expect(r.fetched == n)
}

import Testing
import Foundation
import GRDB
import CryptoKit
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

private func makeClientDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-blob-lazy-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func makeBlobs() -> BlobStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-blobs-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func mkImageItem(
    id: String, origin: String, ingestedAtNs: Int64,
    blobSha: String, deletedAtNs: Int64? = nil
) -> Item {
    Item(
        id: id, originDevice: origin,
        capturedAtNs: ingestedAtNs, ingestedAtNs: ingestedAtNs,
        kind: .image,
        sourceAppName: "Test",
        preview: "[image]",
        blobSha256: blobSha, blobSize: 1024, blobMime: "image/png",
        deletedAtNs: deletedAtNs
    )
}

private func mkTextItem(id: String, origin: String, ingestedAtNs: Int64) -> Item {
    Item(
        id: id, originDevice: origin,
        capturedAtNs: ingestedAtNs, ingestedAtNs: ingestedAtNs,
        kind: .text,
        preview: "txt", textFull: "txt"
    )
}

private func page(items: [Item], nextNs: Int64, nextID: String, hasMore: Bool) -> SincePageWire {
    SincePageWire(
        ok: true, count: items.count, items: items,
        nextCursor: SinceCursor(ingestedAtNs: nextNs, id: nextID),
        hasMore: hasMore
    )
}

private actor FakeSinceTransport: SinceTransport {
    private var pages: [SincePageWire]
    private let healthDeviceID: String
    init(pages: [SincePageWire], healthDeviceID: String) {
        self.pages = pages; self.healthDeviceID = healthDeviceID
    }
    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        await self._fetchSince()
    }
    private func _fetchSince() -> RemoteSinceResult {
        guard !pages.isEmpty else {
            return RemoteSinceResult(outcome: .unreachable(reason: "no more pages"))
        }
        return RemoteSinceResult(outcome: .ok(pages.removeFirst()))
    }
    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        PrimaryHealthResult(outcome: .ok(deviceID: healthDeviceID, nowMs: 1_000, ponteHost: nil))
    }
}

private actor FakeBlobFetcher: BlobFetcher {
    /// sha → outcome 脚本。未脚本化 → notFound
    var script: [String: GetBlobOutcome] = [:]
    /// sha → throw 脚本。优先级高于 script
    var throwScript: [String: any Error] = [:]
    private(set) var calls: [String] = []

    func set(_ sha: String, _ outcome: GetBlobOutcome) { script[sha] = outcome }
    func setThrow(_ sha: String, _ err: any Error) { throwScript[sha] = err }
    func callsCount(for sha: String) -> Int { calls.filter { $0 == sha }.count }
    func totalCalls() -> Int { calls.count }

    nonisolated func getBlob(sha256: String) async throws -> GetBlobOutcome {
        try await self._getBlob(sha256: sha256)
    }
    private func _getBlob(sha256: String) throws -> GetBlobOutcome {
        calls.append(sha256)
        if let err = throwScript[sha256] { throw err }
        return script[sha256] ?? .notFound
    }
}

/// 模拟一个不会立刻返回的大 blob。用于保护 metadata catch-up 不被 full mirror 的
/// 字节 hydration 串行堵住：cursor 应该能继续翻到下一页，blob 留在后台慢慢拉。
private actor BlockingBlobFetcher: BlobFetcher {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    nonisolated func getBlob(sha256: String) async throws -> GetBlobOutcome {
        await self.blockUntilReleased()
    }

    private func blockUntilReleased() async -> GetBlobOutcome {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return .notFound
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func runBriefly(_ worker: PullWorker, ms: Int = 300) async {
    await worker.start()
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    await worker.stop()
}

// MARK: - eager_blobs 主路径

@Test func eagerBlobsFetchesMissingBytes() async throws {
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let imgBytes = Data((0..<512).map { UInt8($0 & 0xFF) })
    let sha = sha256Hex(imgBytes)
    let items = [
        mkImageItem(id: "img-1", origin: "primary", ingestedAtNs: 100, blobSha: sha),
        mkTextItem(id: "txt-1", origin: "primary", ingestedAtNs: 200),
    ]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 200, nextID: "txt-1", hasMore: false)],
        healthDeviceID: "primary"
    )
    let fetcher = FakeBlobFetcher()
    await fetcher.set(sha, .found(imgBytes))

    let worker = PullWorker(
        database: db, transport: transport,
        selfDeviceID: "client", meshStatus: MeshStatus(),
        blobFetcher: fetcher, blobs: blobs,
        config: PullWorker.Config(intervalSec: 60, storageMode: .full)
    )
    await runBriefly(worker)

    // mirror 行写好
    let mirroredIDs = try await db.pool.read { conn in
        try Row.fetchAll(conn, sql: "SELECT id FROM item ORDER BY id").map { $0["id"] as String }
    }
    #expect(mirroredIDs == ["img-1", "txt-1"])
    // blob 字节写好
    #expect(blobs.exists(sha256: sha))
    let readBack = try blobs.read(sha256: sha)
    #expect(readBack == imgBytes)
    // text item 不该触发 blob fetch
    #expect(await fetcher.totalCalls() == 1)
    #expect(await fetcher.callsCount(for: sha) == 1)
}

@Test func slowBlobHydrationDoesNotBlockMetadataPagination() async throws {
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let sha = sha256Hex(Data([0xA1, 0xB2, 0xC3]))
    let transport = FakeSinceTransport(
        pages: [
            page(
                items: [mkImageItem(
                    id: "slow-image", origin: "primary", ingestedAtNs: 100, blobSha: sha
                )],
                nextNs: 100, nextID: "slow-image", hasMore: true
            ),
            page(
                items: [mkTextItem(id: "newer-text", origin: "primary", ingestedAtNs: 200)],
                nextNs: 200, nextID: "newer-text", hasMore: false
            ),
        ],
        healthDeviceID: "primary"
    )
    let fetcher = BlockingBlobFetcher()
    let worker = PullWorker(
        database: db, transport: transport,
        selfDeviceID: "client", meshStatus: MeshStatus(),
        blobFetcher: fetcher, blobs: blobs,
        config: PullWorker.Config(intervalSec: 60, storageMode: .full)
    )

    await worker.start()
    var cursorNs: Int64?
    for _ in 0..<60 {
        cursorNs = try await db.pool.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT cursor_ns FROM pull_cursor")
        }
        if cursorNs == 200 { break }
        try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(await fetcher.started)
    #expect(cursorNs == 200)

    await fetcher.release()
    await worker.stop()
}

@Test func eagerBlobsOffSkipsAllFetches() async throws {
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let sha = sha256Hex(Data([1, 2, 3]))
    let items = [mkImageItem(id: "img-1", origin: "primary", ingestedAtNs: 100, blobSha: sha)]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 100, nextID: "img-1", hasMore: false)],
        healthDeviceID: "primary"
    )
    let fetcher = FakeBlobFetcher()
    await fetcher.set(sha, .found(Data([1, 2, 3])))

    let worker = PullWorker(
        database: db, transport: transport,
        selfDeviceID: "client", meshStatus: MeshStatus(),
        blobFetcher: fetcher, blobs: blobs,
        config: PullWorker.Config(intervalSec: 60, storageMode: .optimized)
    )
    await runBriefly(worker)

    // mirror 行写了
    let count = try await db.pool.read { conn -> Int in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
    }
    #expect(count == 1)
    // 但 blob 没拉，fetcher 零调用
    #expect(await fetcher.totalCalls() == 0)
    #expect(!blobs.exists(sha256: sha))
}

@Test func eagerBlobsSkipsAlreadyPresent() async throws {
    // 本机 BlobStore 已有字节 → 不再 GET（避免重复网络 + 写盘）
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let data = Data([0xAA, 0xBB, 0xCC])
    let sha = sha256Hex(data)
    _ = try blobs.put(data)

    let items = [mkImageItem(id: "img-1", origin: "primary", ingestedAtNs: 100, blobSha: sha)]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 100, nextID: "img-1", hasMore: false)],
        healthDeviceID: "primary"
    )
    let fetcher = FakeBlobFetcher()
    await fetcher.set(sha, .found(data))

    let worker = PullWorker(
        database: db, transport: transport,
        selfDeviceID: "client", meshStatus: MeshStatus(),
        blobFetcher: fetcher, blobs: blobs,
        config: PullWorker.Config(intervalSec: 60, storageMode: .full)
    )
    await runBriefly(worker)
    #expect(await fetcher.totalCalls() == 0)
}

@Test func eagerBlobsSkipsTombstone() async throws {
    // 软删行不需要字节——primary 上已删，blob 一般已被清。不该拉
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let sha = sha256Hex(Data([1]))
    let items = [
        mkImageItem(id: "tombed", origin: "primary", ingestedAtNs: 100,
                    blobSha: sha, deletedAtNs: 50),
    ]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 100, nextID: "tombed", hasMore: false)],
        healthDeviceID: "primary"
    )
    let fetcher = FakeBlobFetcher()

    let worker = PullWorker(
        database: db, transport: transport,
        selfDeviceID: "client", meshStatus: MeshStatus(),
        blobFetcher: fetcher, blobs: blobs,
        config: PullWorker.Config(intervalSec: 60, storageMode: .full)
    )
    await runBriefly(worker)
    #expect(await fetcher.totalCalls() == 0)
}

@Test func eagerBlobsSkipsOwnOriginRows() async throws {
    // origin=self 行不入 mirror（PullWorker 现有契约），blob 也不该被拉
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let sha = sha256Hex(Data([0xFF]))
    let items = [mkImageItem(id: "own", origin: "client", ingestedAtNs: 100, blobSha: sha)]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 100, nextID: "own", hasMore: false)],
        healthDeviceID: "primary"
    )
    let fetcher = FakeBlobFetcher()

    let worker = PullWorker(
        database: db, transport: transport,
        selfDeviceID: "client", meshStatus: MeshStatus(),
        blobFetcher: fetcher, blobs: blobs,
        config: PullWorker.Config(intervalSec: 60, storageMode: .full)
    )
    await runBriefly(worker)
    #expect(await fetcher.totalCalls() == 0)
}

@Test func eagerBlobsFailureDoesNotRevertMirror() async throws {
    // fetcher 抛 transient → mirror 行 + cursor 已 commit，不被 eager 失败回滚
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let sha = sha256Hex(Data([0x99]))
    let items = [mkImageItem(id: "img-1", origin: "primary", ingestedAtNs: 100, blobSha: sha)]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 100, nextID: "img-1", hasMore: false)],
        healthDeviceID: "primary"
    )
    let fetcher = FakeBlobFetcher()
    await fetcher.setThrow(sha, GetBlobError.transient(reason: "503"))

    let worker = PullWorker(
        database: db, transport: transport,
        selfDeviceID: "client", meshStatus: MeshStatus(),
        blobFetcher: fetcher, blobs: blobs,
        config: PullWorker.Config(intervalSec: 60, storageMode: .full)
    )
    await runBriefly(worker)

    // mirror 行仍在
    let count = try await db.pool.read { conn -> Int in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
    }
    #expect(count == 1)
    // cursor 也已推进
    let cur = try await db.pool.read { conn -> Int64? in
        try Int64.fetchOne(conn, sql: "SELECT cursor_ns FROM pull_cursor")
    }
    #expect(cur == 100)
    // blob 没字节（fetcher 抛了）
    #expect(!blobs.exists(sha256: sha))
    // fetcher 仍被试过一次（不重试同 sha 在同 tick 内）
    #expect(await fetcher.callsCount(for: sha) == 1)
}

@Test func eagerBlobsNotFoundIsNotFatal() async throws {
    // primary 返回 .notFound（promote 缺 blob 场景）→ 仍不卡 cursor，下次 tick 也不会
    // 死循环（短路 + 失败计数器在 PullWorker 内不区分 found/notFound——下次 tick 再试，
    // 但本测试只跑一轮）
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let sha = sha256Hex(Data([0x42]))
    let items = [mkImageItem(id: "img-1", origin: "primary", ingestedAtNs: 100, blobSha: sha)]
    let transport = FakeSinceTransport(
        pages: [page(items: items, nextNs: 100, nextID: "img-1", hasMore: false)],
        healthDeviceID: "primary"
    )
    let fetcher = FakeBlobFetcher()
    await fetcher.set(sha, .notFound)

    let worker = PullWorker(
        database: db, transport: transport,
        selfDeviceID: "client", meshStatus: MeshStatus(),
        blobFetcher: fetcher, blobs: blobs,
        config: PullWorker.Config(intervalSec: 60, storageMode: .full)
    )
    await runBriefly(worker)

    let count = try await db.pool.read { conn -> Int in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
    }
    #expect(count == 1)
    #expect(!blobs.exists(sha256: sha))
}

// MARK: - HTTPPeerClient.getBlob 端到端（真起 server）

private func makeServerFixture() throws -> TestSyncServerFixture {
    try TestSyncServerFixture(prefix: "duo-blob-http")
}

@Test func httpGetBlobReturnsBytesOn200() async throws {
    let fixture = try makeServerFixture()
    let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
    let data = Data((0..<2048).map { UInt8($0 & 0xFF) })
    let sha = sha256Hex(data)
    _ = try blobs.put(data, ext: "bin")  // primary 上有字节

    let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                            host: "127.0.0.1", port: 0, auth: auth)
    let outcome = try await fixture.withServer(server) { base in
        try await HTTPPeerClient(baseURL: base, auth: auth).getBlob(sha256: sha)
    }
    switch outcome {
    case .found(let bytes):
        #expect(bytes == data)
    case .notFound:
        Issue.record("expected .found, got .notFound")
    }
}

@Test func httpGetBlobReturnsNotFoundWhenAbsent() async throws {
    let fixture = try makeServerFixture()
    let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
    // 不 put 任何 blob → server 端 BlobStore 是空的
    let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                            host: "127.0.0.1", port: 0, auth: auth)
    let fakeSha = String(repeating: "ab", count: 32)
    let outcome = try await fixture.withServer(server) { base in
        try await HTTPPeerClient(baseURL: base, auth: auth).getBlob(sha256: fakeSha)
    }
    switch outcome {
    case .notFound: break  // 期望
    case .found: Issue.record("expected .notFound")
    }
}

@Test func httpGetBlobRejectsBadSignature() async throws {
    let fixture = try makeServerFixture()
    let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
    let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                            host: "127.0.0.1", port: 0, auth: auth)

    // 错的 secret → server 401
    let badAuth = HMACAuth(secret: Data(repeating: 0xFF, count: 32))
    let fakeSha = String(repeating: "cd", count: 32)
    do {
        _ = try await fixture.withServer(server) { base in
            try await HTTPPeerClient(baseURL: base, auth: badAuth).getBlob(sha256: fakeSha)
        }
        Issue.record("expected throw")
    } catch let err as GetBlobError {
        switch err {
        case .rejected: break  // 期望
        default: Issue.record("expected .rejected, got \(err)")
        }
    }
}

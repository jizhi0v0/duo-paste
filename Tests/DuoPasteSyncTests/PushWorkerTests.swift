import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

private func makeClientDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-push-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB, role: .client)
}

private func makePendingItem(id: String = UUID().uuidString, origin: String) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: 1_700_000_000_000_000_000,
        kind: .text,
        sourceApp: "com.example",
        sourceAppName: "Example",
        preview: "p",
        textFull: "full text",
        pinned: false,
        pushState: .pending,
        pushAttempts: 0
    )
}

/// 可控的 fake transport：按 id 给定固定 outcome。
private actor FakeTransport: IngestTransport {
    var outcomes: [String: IngestResult.Outcome] = [:]
    var blobOutcomes: [String: IngestResult.Outcome] = [:]
    var calls: [(String, Date)] = []
    var blobCalls: [(String, Date)] = []
    var defaultOutcome: IngestResult.Outcome = .acked(ingestedAtNs: 999, wasNew: true)
    var defaultBlobOutcome: IngestResult.Outcome = .acked(ingestedAtNs: nil, wasNew: true)

    func set(_ id: String, _ outcome: IngestResult.Outcome) { outcomes[id] = outcome }
    func setDefault(_ outcome: IngestResult.Outcome) { defaultOutcome = outcome }
    func setBlob(_ sha: String, _ outcome: IngestResult.Outcome) { blobOutcomes[sha] = outcome }
    func setDefaultBlob(_ outcome: IngestResult.Outcome) { defaultBlobOutcome = outcome }
    func callsCount(for id: String) -> Int { calls.filter { $0.0 == id }.count }
    func blobCallsCount(for sha: String) -> Int { blobCalls.filter { $0.0 == sha }.count }
    func allCallsCount() -> Int { calls.count }

    nonisolated func ingest(_ req: IngestRequest) async throws -> IngestResult {
        await record(req.id)
        return IngestResult(outcome: await outcomeFor(req.id))
    }
    nonisolated func putBlob(sha256: String, data: Data) async throws -> IngestResult {
        await recordBlob(sha256)
        return IngestResult(outcome: await blobOutcomeFor(sha256))
    }
    private func record(_ id: String) { calls.append((id, Date())) }
    private func recordBlob(_ sha: String) { blobCalls.append((sha, Date())) }
    private func outcomeFor(_ id: String) -> IngestResult.Outcome {
        outcomes[id] ?? defaultOutcome
    }
    private func blobOutcomeFor(_ sha: String) -> IngestResult.Outcome {
        blobOutcomes[sha] ?? defaultBlobOutcome
    }
}

private func makeBlobs() -> BlobStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-blobs-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root)
}

@Test func pushUploadsBlobBeforeIngestForImageItems() async throws {
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let imageBytes = Data((0..<1024).map { UInt8($0 % 256) })
    let blobInfo = try blobs.put(imageBytes, ext: "png")
    let origin = "device-image"
    let item = Item(
        id: UUID().uuidString,
        originDevice: origin,
        capturedAtNs: 1_700_000_000_000_000_000,
        kind: .image,
        sourceAppName: "Example",
        preview: "[image]",
        blobSha256: blobInfo.sha256,
        blobSize: blobInfo.size,
        blobMime: "image/png",
        pinned: false,
        pushState: .pending
    )
    try await db.pool.write { try item.insert($0) }

    let transport = FakeTransport()
    let worker = PushWorker(
        database: db,
        blobs: blobs,
        transport: transport,
        originDevice: origin,
        config: .init(idleIntervalSec: 60)
    )
    await worker.start()
    await worker.wake()
    try await Task.sleep(nanoseconds: 200_000_000)
    await worker.stop()

    // 顺序契约：blob 先于 ingest（两者都应被调用，且 blob 至少一次）
    #expect(await transport.blobCallsCount(for: blobInfo.sha256) == 1)
    #expect(await transport.callsCount(for: item.id) == 1)
    let stored: Item? = try await db.pool.read { try Item.filter(Column("id") == item.id).fetchOne($0) }
    #expect(stored?.pushState == .acked)
}

@Test func pushFailsItemIfBlobRejected() async throws {
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let imageBytes = Data((0..<512).map { UInt8($0 % 256) })
    let blobInfo = try blobs.put(imageBytes, ext: "png")
    let origin = "device-image-bad"
    let item = Item(
        id: UUID().uuidString,
        originDevice: origin,
        capturedAtNs: 1_700_000_000_000_000_000,
        kind: .image,
        blobSha256: blobInfo.sha256,
        pinned: false,
        pushState: .pending
    )
    try await db.pool.write { try item.insert($0) }

    let transport = FakeTransport()
    // primary 拒收 blob（比如 quota / 格式错），item 不应再去 ingest
    await transport.setBlob(blobInfo.sha256, .rejected(reason: "quota exceeded"))
    let worker = PushWorker(
        database: db,
        blobs: blobs,
        transport: transport,
        originDevice: origin,
        config: .init(idleIntervalSec: 60)
    )
    await worker.start()
    await worker.wake()
    try await Task.sleep(nanoseconds: 200_000_000)
    await worker.stop()

    #expect(await transport.blobCallsCount(for: blobInfo.sha256) == 1)
    #expect(await transport.callsCount(for: item.id) == 0)  // ingest 不应被调用
    let stored: Item? = try await db.pool.read { try Item.filter(Column("id") == item.id).fetchOne($0) }
    #expect(stored?.pushState == .failed)
    #expect(stored?.lastPushError?.contains("blob rejected") == true)
}

@Test func pushFailsItemIfLocalBlobMissing() async throws {
    let db = try makeClientDB()
    let blobs = makeBlobs()
    let origin = "device-image-missing"
    let missingSha = String(repeating: "ab", count: 32)
    let item = Item(
        id: UUID().uuidString,
        originDevice: origin,
        capturedAtNs: 1_700_000_000_000_000_000,
        kind: .image,
        blobSha256: missingSha,
        pinned: false,
        pushState: .pending
    )
    try await db.pool.write { try item.insert($0) }

    let transport = FakeTransport()
    let worker = PushWorker(
        database: db,
        blobs: blobs,
        transport: transport,
        originDevice: origin,
        config: .init(idleIntervalSec: 60)
    )
    await worker.start()
    await worker.wake()
    try await Task.sleep(nanoseconds: 200_000_000)
    await worker.stop()

    #expect(await transport.blobCallsCount(for: missingSha) == 0)  // 没真上传：本地就读不到
    let stored: Item? = try await db.pool.read { try Item.filter(Column("id") == item.id).fetchOne($0) }
    #expect(stored?.pushState == .failed)
    #expect(stored?.lastPushError?.contains("local blob missing") == true)
}

@Test func pushAcksOnSuccess() async throws {
    let db = try makeClientDB()
    let origin = "device-A"
    let item = makePendingItem(origin: origin)
    try await db.pool.write { try item.insert($0) }

    let transport = FakeTransport()
    await transport.setDefault(.acked(ingestedAtNs: 12345, wasNew: true))
    let worker = PushWorker(
        database: db,
        blobs: makeBlobs(),
        transport: transport,
        originDevice: origin,
        config: .init(idleIntervalSec: 60)  // 长 idle 避免重复 tick
    )
    await worker.start()
    // wake 立刻跑一轮，跑完会去 sleep idleIntervalSec
    await worker.wake()
    // 给 actor 一点时间完成 tick + DB write
    try await Task.sleep(nanoseconds: 200_000_000)
    await worker.stop()

    let stored: Item? = try await db.pool.read { try Item.filter(Column("id") == item.id).fetchOne($0) }
    #expect(stored?.pushState == .acked)
    #expect(stored?.ingestedAtNs == 12345)
    #expect(stored?.pushAttempts == 1)
    #expect(stored?.lastPushError == nil)
    #expect(await transport.callsCount(for: item.id) == 1)
}

@Test func pushSkipsOtherOrigin() async throws {
    // 多归属：本机 origin 只推自己的，不碰别人的 pending（理论上 client 库不会有，
    // 但 mirror 模式 / 误操作的兜底应当稳）。
    let db = try makeClientDB()
    let mine = makePendingItem(origin: "me")
    let other = makePendingItem(origin: "someone-else")
    try await db.pool.write {
        try mine.insert($0)
        try other.insert($0)
    }
    let transport = FakeTransport()
    let worker = PushWorker(
        database: db,
        blobs: makeBlobs(),
        transport: transport,
        originDevice: "me",
        config: .init(idleIntervalSec: 60)
    )
    await worker.start()
    await worker.wake()
    try await Task.sleep(nanoseconds: 200_000_000)
    await worker.stop()

    #expect(await transport.callsCount(for: mine.id) == 1)
    #expect(await transport.callsCount(for: other.id) == 0)
    let otherStored: Item? = try await db.pool.read { try Item.filter(Column("id") == other.id).fetchOne($0) }
    #expect(otherStored?.pushState == .pending)
}

@Test func pushMarksFailedOn4xx() async throws {
    let db = try makeClientDB()
    let origin = "device-B"
    let item = makePendingItem(origin: origin)
    try await db.pool.write { try item.insert($0) }
    let transport = FakeTransport()
    await transport.setDefault(.rejected(reason: "字段非法: foo"))
    let worker = PushWorker(
        database: db,
        blobs: makeBlobs(),
        transport: transport,
        originDevice: origin,
        config: .init(idleIntervalSec: 60)
    )
    await worker.start()
    await worker.wake()
    try await Task.sleep(nanoseconds: 200_000_000)
    await worker.stop()

    let stored: Item? = try await db.pool.read { try Item.filter(Column("id") == item.id).fetchOne($0) }
    #expect(stored?.pushState == .failed)
    #expect(stored?.lastPushError?.contains("字段非法") == true)
    // 4xx 立即放弃，不应重试
    #expect(await transport.callsCount(for: item.id) == 1)
}

@Test func pushBumpsAttemptOnTransientThenGivesUp() async throws {
    let db = try makeClientDB()
    let origin = "device-C"
    let item = makePendingItem(origin: origin)
    try await db.pool.write { try item.insert($0) }
    let transport = FakeTransport()
    await transport.setDefault(.transient(reason: "connection refused"))
    let worker = PushWorker(
        database: db,
        blobs: makeBlobs(),
        transport: transport,
        originDevice: origin,
        // maxAttempts=3 + 极短 backoff 让测试快
        config: .init(
            idleIntervalSec: 0.05,
            initialBackoffSec: 0.05,
            maxBackoffSec: 0.05,
            maxAttempts: 3,
            batchSize: 10
        )
    )
    await worker.start()
    await worker.wake()
    // 3 次 transient 后应该被标 failed。0.05s × ~4 = 0.2s 足够
    try await Task.sleep(nanoseconds: 800_000_000)
    await worker.stop()

    let stored: Item? = try await db.pool.read { try Item.filter(Column("id") == item.id).fetchOne($0) }
    #expect(stored?.pushState == .failed)
    #expect((stored?.pushAttempts ?? 0) >= 3)
    #expect(stored?.lastPushError?.contains("max attempts") == true)
}

/// 端到端集成：真起一个 SyncServer（in-process，随机端口），真起 PushWorker，
/// 验证 item 从 client DB 流到 primary DB。
@Test func pushIntegrationEndToEnd() async throws {
    // 双 DB
    let clientDB = try makeClientDB()
    let primaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-primary-\(UUID().uuidString)", isDirectory: true)
    let primaryPaths = Paths(root: primaryRoot)
    primaryPaths.ensureExists()
    let primaryDB = try DuoDB(path: primaryPaths.mainDB, role: .primary)

    let secret = Data(repeating: 0xAB, count: 32)
    let auth = HMACAuth(secret: secret)
    // 跑 server on 随机端口
    let port = Int.random(in: 18000..<19000)
    let primaryBlobs = makeBlobs()
    let server = SyncServer(
        deviceID: "primary-device",
        database: primaryDB,
        blobs: primaryBlobs,
        host: "127.0.0.1",
        port: port,
        auth: auth
    )
    let serverTask = Task { try? await server.run() }
    // 等 server 起来：轮询 /health
    let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    let client = HTTPIngestClient(baseURL: baseURL, auth: auth)
    var serverUp = false
    for _ in 0..<50 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        // 用 ingest 的 transient 检测当 ping：连不上即 transient，连上即其他
        let probe = (try? await client.ingest(IngestRequest(
            id: "_probe", originDevice: "_probe", capturedAtNs: 1, kind: .text,
            sourceApp: nil, sourceAppName: nil, preview: nil, textFull: nil,
            blobSha256: nil, blobSize: nil, blobMime: nil, pinned: nil, deletedAtNs: nil
        )))?.outcome
        if case .acked = probe { serverUp = true; break }
        if case .rejected = probe { serverUp = true; break }
    }
    #expect(serverUp == true)
    // 清掉 probe item
    try await primaryDB.pool.write { try $0.execute(sql: "DELETE FROM item WHERE id = '_probe'") }

    // 在 client 库写一条 pending
    let origin = "client-device"
    let item = makePendingItem(origin: origin)
    try await clientDB.pool.write { try item.insert($0) }

    let worker = PushWorker(
        database: clientDB,
        blobs: makeBlobs(),
        transport: client,
        originDevice: origin,
        config: .init(idleIntervalSec: 60)
    )
    await worker.start()
    await worker.wake()
    // 给 push + ack 一点时间
    try await Task.sleep(nanoseconds: 500_000_000)
    await worker.stop()
    serverTask.cancel()

    // 客户端这边状态变 acked
    let clientStored: Item? = try await clientDB.pool.read {
        try Item.filter(Column("id") == item.id).fetchOne($0)
    }
    #expect(clientStored?.pushState == .acked)

    // primary 这边出现了同 id 的行
    let primaryStored: Item? = try await primaryDB.pool.read {
        try Item.filter(Column("id") == item.id).fetchOne($0)
    }
    #expect(primaryStored != nil)
    #expect(primaryStored?.originDevice == origin)
    #expect(primaryStored?.pushState == .acked)
    #expect(primaryStored?.textFull == "full text")
}

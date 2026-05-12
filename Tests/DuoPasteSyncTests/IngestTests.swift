import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

private func tempDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-ingest-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB, role: .primary)
}

private func sampleRequest(id: String = UUID().uuidString) -> IngestRequest {
    IngestRequest(
        id: id,
        originDevice: "remote-device-1",
        capturedAtNs: 1_700_000_000_000_000_000,
        kind: .text,
        sourceApp: "com.example.app",
        sourceAppName: "Example",
        preview: "hello world",
        textFull: "hello world",
        blobSha256: nil,
        blobSize: nil,
        blobMime: nil,
        pinned: false,
        deletedAtNs: nil
    )
}

@Test func ingestInsertsNewItem() async throws {
    let db = try tempDB()
    let ingester = RemoteIngester(database: db, now: { 1_700_000_000_999_999_999 })
    let req = sampleRequest()
    let result = try await ingester.ingest(req)
    #expect(result.wasNew == true)
    #expect(result.ingestedAtNs == 1_700_000_000_999_999_999)

    // 真的进了 item 表，且 ingested_at_ns / push_state 由 server 设置
    let stored = try await db.pool.read { conn in
        try Item.filter(Column("id") == req.id).fetchOne(conn)
    }
    #expect(stored != nil)
    #expect(stored?.ingestedAtNs == 1_700_000_000_999_999_999)
    #expect(stored?.pushState == .acked)
    #expect(stored?.originDevice == "remote-device-1")
    #expect(stored?.textFull == "hello world")
}

@Test func ingestIsIdempotentOnRetry() async throws {
    let db = try tempDB()
    let ingester = RemoteIngester(database: db, now: { 1000 })
    let req = sampleRequest(id: "fixed-id-1")
    let r1 = try await ingester.ingest(req)
    #expect(r1.wasNew == true)

    // 同 id 二次推 → wasNew=false，返回值跟库里一致：第一次的 ingested_at_ns，
    // 不被覆盖也不假冒 now()——client 日志看到的就是 primary 真存的那一刻
    let ingester2 = RemoteIngester(database: db, now: { 2000 })
    let r2 = try await ingester2.ingest(req)
    #expect(r2.wasNew == false)
    #expect(r2.ingestedAtNs == 1000)  // 跟下面 stored 一致

    let stored = try await db.pool.read { conn in
        try Item.filter(Column("id") == req.id).fetchOne(conn)
    }
    #expect(stored?.ingestedAtNs == 1000)  // 库里仍是首次的时刻
}

@Test func ingestEnablesFTS() async throws {
    // 推 item 进来，应当能立刻通过 item_fts 搜到（trigger 维护 FTS）
    let db = try tempDB()
    let ingester = RemoteIngester(database: db)
    var req = sampleRequest()
    req.textFull = "ingested via remote push pipeline"
    req.preview = "ingested via remote push pipeline"
    _ = try await ingester.ingest(req)

    let hit = try await db.pool.read { conn in
        try String.fetchOne(conn, sql: """
            SELECT id FROM item
            WHERE rowid IN (SELECT rowid FROM item_fts WHERE item_fts MATCH ?)
        """, arguments: ["pipeline"])
    }
    #expect(hit == req.id)
}

@Test func ingestRejectsEmptyID() async throws {
    let db = try tempDB()
    let ingester = RemoteIngester(database: db)
    var req = sampleRequest()
    req.id = ""
    await #expect(throws: IngestError.self) {
        _ = try await ingester.ingest(req)
    }
}

@Test func ingestRejectsBadBlobHash() async throws {
    let db = try tempDB()
    let ingester = RemoteIngester(database: db)
    var req = sampleRequest()
    req.blobSha256 = "tooshort"
    await #expect(throws: IngestError.self) {
        _ = try await ingester.ingest(req)
    }
}

@Test func ingestRejectsNegativeTimestamp() async throws {
    let db = try tempDB()
    let ingester = RemoteIngester(database: db)
    var req = sampleRequest()
    req.capturedAtNs = -1
    await #expect(throws: IngestError.self) {
        _ = try await ingester.ingest(req)
    }
}

// MARK: - 跨设备 Continuity dedup

/// 在 primary 本机插一条 origin=primary 的 own item，用于模拟「primary 自家也通过
/// macOS Universal Clipboard 同步 capture 了同一份内容」的状态。
private func insertOwnItem(
    _ db: DuoDB,
    primaryID: String,
    capturedAtNs: Int64,
    text: String = "hello world",
    blobSha256: String? = nil,
    kind: ItemKind = .text
) throws {
    let it = Item(
        id: "primary-local-" + UUID().uuidString,
        originDevice: primaryID,
        capturedAtNs: capturedAtNs,
        ingestedAtNs: capturedAtNs,
        kind: kind,
        sourceAppName: "Zed",
        preview: text,
        textFull: text,
        blobSha256: blobSha256,
        pushState: .acked
    )
    try db.pool.write { conn in try it.insert(conn) }
}

@Test func ingestRejectsCrossDeviceContinuityDuplicate() async throws {
    // 场景：mini = primary 通过 Universal Clipboard 在 capturedAt=T 时自家 capture 了一份；
    // mbp = client 紧接着把同内容 push 过来（capturedAt 偏移 +100ms，模拟 Continuity 同步延迟）。
    // dedup 应拒收：wasNew=false + dedupReason 非 nil，mbp 那条**不进** primary item 表。
    let db = try tempDB()
    let primaryID = "primary-mini"
    let baseline: Int64 = 1_700_000_000_000_000_000
    try insertOwnItem(db, primaryID: primaryID, capturedAtNs: baseline)

    let ingester = RemoteIngester(
        database: db,
        selfDeviceID: primaryID,
        crossDeviceWindowNs: 5_000_000_000,
        now: { baseline + 200_000_000 }
    )
    var req = sampleRequest(id: "mbp-1")
    req.originDevice = "mbp-client"
    req.capturedAtNs = baseline + 100_000_000   // +100ms
    req.textFull = "hello world"
    req.preview = "hello world"

    let result = try await ingester.ingest(req)
    #expect(result.wasNew == false)
    #expect(result.dedupReason != nil)

    let mbpStored = try await db.pool.read { conn in
        try Item.filter(Column("id") == "mbp-1").fetchOne(conn)
    }
    #expect(mbpStored == nil)
}

@Test func ingestAcceptsSameContentOutsideDedupWindow() async throws {
    // 窗口外（>5s）同内容 push 应正常入库——不是 Continuity 副本，是真正的"同内容再复制一次"。
    let db = try tempDB()
    let primaryID = "primary-mini"
    let baseline: Int64 = 1_700_000_000_000_000_000
    try insertOwnItem(db, primaryID: primaryID, capturedAtNs: baseline)

    let ingester = RemoteIngester(
        database: db,
        selfDeviceID: primaryID,
        crossDeviceWindowNs: 5_000_000_000,
        now: { baseline + 60_000_000_000 }
    )
    var req = sampleRequest(id: "mbp-late")
    req.originDevice = "mbp-client"
    req.capturedAtNs = baseline + 10_000_000_000  // +10s，远超 5s 窗口
    req.textFull = "hello world"

    let result = try await ingester.ingest(req)
    #expect(result.wasNew == true)
    #expect(result.dedupReason == nil)
}

@Test func ingestDedupSkippedWhenSelfDeviceIDEmpty() async throws {
    // 向后兼容：老调用方不传 selfDeviceID 时，dedup 层应完全 off，
    // 行为退化到原有 id-only 幂等逻辑。
    let db = try tempDB()
    let primaryID = "primary-mini"
    let baseline: Int64 = 1_700_000_000_000_000_000
    try insertOwnItem(db, primaryID: primaryID, capturedAtNs: baseline)

    let ingester = RemoteIngester(database: db)   // selfDeviceID=""
    var req = sampleRequest(id: "no-dedup-1")
    req.originDevice = "mbp-client"
    req.capturedAtNs = baseline + 100_000_000
    req.textFull = "hello world"

    let result = try await ingester.ingest(req)
    #expect(result.wasNew == true)
    #expect(result.dedupReason == nil)
}

@Test func ingestDedupSkippedWhenWindowZero() async throws {
    // crossDeviceWindowNs=0 显式关闭 dedup 层，即便 selfID 给了同内容也照样入库。
    let db = try tempDB()
    let primaryID = "primary-mini"
    let baseline: Int64 = 1_700_000_000_000_000_000
    try insertOwnItem(db, primaryID: primaryID, capturedAtNs: baseline)

    let ingester = RemoteIngester(
        database: db,
        selfDeviceID: primaryID,
        crossDeviceWindowNs: 0,
        now: { baseline + 200_000_000 }
    )
    var req = sampleRequest(id: "off-1")
    req.originDevice = "mbp-client"
    req.capturedAtNs = baseline + 100_000_000
    req.textFull = "hello world"

    let result = try await ingester.ingest(req)
    #expect(result.wasNew == true)
    #expect(result.dedupReason == nil)
}

@Test func ingestDedupHonorsBlobSha256() async throws {
    // 图片 / 文件 kind 走 blob_sha256 比对，不靠 text_full（textFull 此时存的是 filename）。
    let db = try tempDB()
    let primaryID = "primary-mini"
    let baseline: Int64 = 1_700_000_000_000_000_000
    let sha = String(repeating: "a", count: 64)
    try insertOwnItem(
        db, primaryID: primaryID, capturedAtNs: baseline,
        text: "screenshot.png", blobSha256: sha, kind: .image
    )

    let ingester = RemoteIngester(
        database: db,
        selfDeviceID: primaryID,
        crossDeviceWindowNs: 5_000_000_000,
        now: { baseline + 200_000_000 }
    )
    var req = sampleRequest(id: "mbp-blob")
    req.originDevice = "mbp-client"
    req.capturedAtNs = baseline + 100_000_000
    req.kind = .image
    req.textFull = "screenshot.png"   // 故意改 filename 不同——dedup 应**仍**按 sha256 命中
    req.preview = "different-name.png"
    req.blobSha256 = sha
    req.blobSize = 1024
    req.blobMime = "image/png"

    let result = try await ingester.ingest(req)
    #expect(result.wasNew == false)
    #expect(result.dedupReason != nil)
}

@Test func ingestRequestJSONRoundTrip() throws {
    // wire format 单测：确保 snake_case JSON 能精确 round-trip
    let req = sampleRequest(id: "rt-1")
    let data = try JSONEncoder().encode(req)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"origin_device\""))
    #expect(json.contains("\"captured_at_ns\""))
    #expect(!json.contains("push_state"))  // 内部字段不应在线上
    let decoded = try JSONDecoder().decode(IngestRequest.self, from: data)
    #expect(decoded.id == req.id)
    #expect(decoded.capturedAtNs == req.capturedAtNs)
    #expect(decoded.originDevice == req.originDevice)
}

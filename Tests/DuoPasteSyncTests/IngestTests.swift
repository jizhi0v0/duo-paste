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

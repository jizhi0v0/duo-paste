import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

private func makeServerFixture(items: [Item]) throws -> (DuoDB, BlobStore, HMACAuth, Int) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-since-http-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try DuoDB(path: paths.mainDB, role: .primary)
    try db.pool.write { conn in
        for it in items { try it.insert(conn) }
    }
    let blobs = BlobStore(root: paths.blobsDir)
    try FileManager.default.createDirectory(at: blobs.root, withIntermediateDirectories: true)
    let auth = HMACAuth(secret: Data(repeating: 0xAB, count: 32))
    let port = Int.random(in: 19000..<20000)
    return (db, blobs, auth, port)
}

private func item(
    id: String,
    ingestedAtNs: Int64?,
    capturedAtNs: Int64 = 1_700_000_000_000_000_000,
    text: String = "x",
    deletedAtNs: Int64? = nil
) -> Item {
    Item(
        id: id,
        originDevice: "test",
        capturedAtNs: capturedAtNs,
        ingestedAtNs: ingestedAtNs,
        kind: .text,
        preview: text,
        textFull: text,
        deletedAtNs: deletedAtNs,
        pushState: .acked
    )
}

private func waitReady(baseURL: URL, auth: HMACAuth) async -> Bool {
    // 等 server 起来：repeatedly 打 /health
    for _ in 0..<50 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let sig = auth.sign(timestampMs: ts, method: "GET", path: "/health",
                            bodyHashHex: HMACAuth.emptyBodyHashHex)
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            return true
        }
    }
    return false
}

/// 自己手搓的 /since GET：测试不依赖 client 库（暂未实现），直接打 wire。
/// query 顺序固定，签名 path 包含原样 query string。
private func getSince(
    baseURL: URL, auth: HMACAuth,
    cursorNs: Int64? = nil, cursorID: String? = nil, limit: Int? = nil
) async throws -> (Int, [String: Any]) {
    var qi: [URLQueryItem] = []
    if let cursorNs { qi.append(.init(name: "cursor_ns", value: String(cursorNs))) }
    if let cursorID { qi.append(.init(name: "cursor_id", value: cursorID)) }
    if let limit { qi.append(.init(name: "limit", value: String(limit))) }

    var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    comp.path = "/since"
    comp.queryItems = qi.isEmpty ? nil : qi

    let queryStr = comp.percentEncodedQuery.map { "?\($0)" } ?? ""
    let signedPath = "/since" + queryStr

    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let sig = auth.sign(timestampMs: ts, method: "GET", path: signedPath,
                        bodyHashHex: HMACAuth.emptyBodyHashHex)
    var req = URLRequest(url: comp.url!)
    req.httpMethod = "GET"
    req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
    req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
    req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as! HTTPURLResponse
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    return (http.statusCode, json)
}

@Test func sinceHTTPReturnsAllFromZeroCursor() async throws {
    let (db, blobs, auth, port) = try makeServerFixture(items: [
        item(id: "a", ingestedAtNs: 10),
        item(id: "b", ingestedAtNs: 20),
        item(id: "c", ingestedAtNs: 30),
    ])
    let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                            host: "127.0.0.1", port: port, auth: auth)
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    #expect(await waitReady(baseURL: base, auth: auth))

    let (status, body) = try await getSince(baseURL: base, auth: auth)
    #expect(status == 200)
    #expect(body["ok"] as? Bool == true)
    let items = body["items"] as? [[String: Any]] ?? []
    #expect(items.map { $0["id"] as? String } == ["a", "b", "c"])
    #expect(body["has_more"] as? Bool == false)
    let nc = body["next_cursor"] as? [String: Any] ?? [:]
    #expect(nc["ingested_at_ns"] as? Int64 == 30 || nc["ingested_at_ns"] as? Int == 30)
    #expect(nc["id"] as? String == "c")
}

@Test func sinceHTTPPagesWithCursor() async throws {
    let (db, blobs, auth, port) = try makeServerFixture(items: [
        item(id: "a", ingestedAtNs: 1),
        item(id: "b", ingestedAtNs: 2),
        item(id: "c", ingestedAtNs: 3),
        item(id: "d", ingestedAtNs: 4),
    ])
    let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                            host: "127.0.0.1", port: port, auth: auth)
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    #expect(await waitReady(baseURL: base, auth: auth))

    let (s1, b1) = try await getSince(baseURL: base, auth: auth, limit: 2)
    #expect(s1 == 200)
    let p1Items = b1["items"] as? [[String: Any]] ?? []
    #expect(p1Items.map { $0["id"] as? String } == ["a", "b"])
    #expect(b1["has_more"] as? Bool == true)
    let nc1 = b1["next_cursor"] as? [String: Any] ?? [:]
    let nextNs = (nc1["ingested_at_ns"] as? Int64) ?? Int64(nc1["ingested_at_ns"] as? Int ?? 0)
    let nextID = nc1["id"] as? String ?? ""

    let (s2, b2) = try await getSince(baseURL: base, auth: auth,
                                       cursorNs: nextNs, cursorID: nextID, limit: 2)
    #expect(s2 == 200)
    let p2Items = b2["items"] as? [[String: Any]] ?? []
    #expect(p2Items.map { $0["id"] as? String } == ["c", "d"])
    #expect(b2["has_more"] as? Bool == true)  // == limit
}

@Test func sinceHTTPRejectsBadSignature() async throws {
    let (db, blobs, auth, port) = try makeServerFixture(items: [
        item(id: "a", ingestedAtNs: 1),
    ])
    let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                            host: "127.0.0.1", port: port, auth: auth)
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    #expect(await waitReady(baseURL: base, auth: auth))

    // 用错的 secret 签名 → 期望 401
    let badAuth = HMACAuth(secret: Data(repeating: 0xFF, count: 32))
    let (status, _) = try await getSince(baseURL: base, auth: badAuth)
    #expect(status == 401)
}

@Test func sinceHTTPIncludesSoftDeleted() async throws {
    let (db, blobs, auth, port) = try makeServerFixture(items: [
        item(id: "alive", ingestedAtNs: 1),
        item(id: "dead", ingestedAtNs: 2, deletedAtNs: 999),
    ])
    let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                            host: "127.0.0.1", port: port, auth: auth)
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    #expect(await waitReady(baseURL: base, auth: auth))

    let (status, body) = try await getSince(baseURL: base, auth: auth)
    #expect(status == 200)
    let items = body["items"] as? [[String: Any]] ?? []
    let ids = items.compactMap { $0["id"] as? String }
    #expect(ids == ["alive", "dead"])
    // dead 应该带 deleted_at_ns
    let deadRow = items.first { $0["id"] as? String == "dead" }
    let delNs = (deadRow?["deleted_at_ns"] as? Int64) ?? Int64(deadRow?["deleted_at_ns"] as? Int ?? 0)
    #expect(delNs == 999)
}

/// 把 /since 响应字节直接喂进 JSONDecoder，验证 SincePageWire 能解 ——
/// 这是 PullWorker 将走的解码路径，比之前 JSONSerialization + Int/Int64 fallback 更可靠。
private func decodeSince(
    baseURL: URL, auth: HMACAuth,
    cursorNs: Int64? = nil, cursorID: String? = nil, limit: Int? = nil
) async throws -> SincePageWire {
    var qi: [URLQueryItem] = []
    if let cursorNs { qi.append(.init(name: "cursor_ns", value: String(cursorNs))) }
    if let cursorID { qi.append(.init(name: "cursor_id", value: cursorID)) }
    if let limit { qi.append(.init(name: "limit", value: String(limit))) }
    var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    comp.path = "/since"
    comp.queryItems = qi.isEmpty ? nil : qi
    let signedPath = "/since" + (comp.percentEncodedQuery.map { "?\($0)" } ?? "")
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let sig = auth.sign(timestampMs: ts, method: "GET", path: signedPath,
                        bodyHashHex: HMACAuth.emptyBodyHashHex)
    var req = URLRequest(url: comp.url!)
    req.httpMethod = "GET"
    req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
    req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
    req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSONDecoder().decode(SincePageWire.self, from: data)
}

@Test func sinceHTTPRoundTripsThroughCodable() async throws {
    // 走 JSONDecoder → SincePageWire 路径，而不是 JSONSerialization。
    // 这是 PullWorker 将依赖的契约——wire 形态稳定性的最低保证。
    let (db, blobs, auth, port) = try makeServerFixture(items: [
        item(id: "x1", ingestedAtNs: 100),
        item(id: "x2", ingestedAtNs: 200),
    ])
    let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                            host: "127.0.0.1", port: port, auth: auth)
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    #expect(await waitReady(baseURL: base, auth: auth))

    let page = try await decodeSince(baseURL: base, auth: auth)
    #expect(page.ok == true)
    #expect(page.count == 2)
    #expect(page.items.map(\.id) == ["x1", "x2"])
    #expect(page.hasMore == false)
    #expect(page.nextCursor.ingestedAtNs == 200)
    #expect(page.nextCursor.id == "x2")
    // 把 nextCursor 喂回去，验证 round-trip 收敛到空 + 同 cursor
    let next = try await decodeSince(baseURL: base, auth: auth,
                                     cursorNs: page.nextCursor.ingestedAtNs,
                                     cursorID: page.nextCursor.id)
    #expect(next.items.isEmpty)
    #expect(next.nextCursor == page.nextCursor)
}

@Test func sinceHTTPEmptyResultPreservesCursor() async throws {
    let (db, blobs, auth, port) = try makeServerFixture(items: [
        item(id: "a", ingestedAtNs: 5),
    ])
    let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                            host: "127.0.0.1", port: port, auth: auth)
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    #expect(await waitReady(baseURL: base, auth: auth))

    // cursor 已经超过所有数据 → 空结果，next_cursor 原样回来
    let (status, body) = try await getSince(baseURL: base, auth: auth,
                                            cursorNs: 1_000_000, cursorID: "zzz")
    #expect(status == 200)
    #expect((body["items"] as? [[String: Any]])?.isEmpty == true)
    #expect(body["has_more"] as? Bool == false)
    let nc = body["next_cursor"] as? [String: Any] ?? [:]
    let returnedNs = (nc["ingested_at_ns"] as? Int64) ?? Int64(nc["ingested_at_ns"] as? Int ?? 0)
    #expect(returnedNs == 1_000_000)
    #expect(nc["id"] as? String == "zzz")
}

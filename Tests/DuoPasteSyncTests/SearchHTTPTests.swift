import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// P0-2 GET /search?q=<text>:iOS client 用——本机 SearchAPI fold-aware 搜索 + count。
/// 验证:HMAC 通过 + fold-aware(跨 origin 同 text 折一条)+ snippet 标记 + 空 q 走列表。

private typealias DuoDB = DuoPasteCore.Database

private func makeSearchServerFixture(items: [Item]) throws -> (DuoDB, BlobStore, HMACAuth, Int) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-search-http-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try DuoDB(path: paths.mainDB)
    try db.pool.write { conn in
        for it in items { try it.insert(conn) }
    }
    let blobs = BlobStore(root: paths.blobsDir)
    try FileManager.default.createDirectory(at: blobs.root, withIntermediateDirectories: true)
    let auth = HMACAuth(secret: Data(repeating: 0xCD, count: 32))
    let port = Int.random(in: 19500..<20500)
    return (db, blobs, auth, port)
}

private func textItem(id: String, origin: String, text: String, capturedAtNs: Int64) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedAtNs,
        ingestedAtNs: capturedAtNs,
        kind: .text,
        preview: text,
        textFull: text
    )
}

private func waitReadySearch(baseURL: URL, auth: HMACAuth) async -> Bool {
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

private func getSearch(baseURL: URL, auth: HMACAuth, q: String?, limit: Int? = nil, tamperSig: Bool = false)
async throws -> (Int, [String: Any]) {
    var qi: [URLQueryItem] = []
    if let q { qi.append(URLQueryItem(name: "q", value: q)) }
    if let limit { qi.append(URLQueryItem(name: "limit", value: String(limit))) }
    var sigComp = URLComponents()
    sigComp.path = "/search"
    sigComp.queryItems = qi.isEmpty ? nil : qi
    let signedPath = HMACAuth.canonicalPath("/search", query: sigComp.percentEncodedQuery)

    var urlComp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    urlComp.path = "/search"
    urlComp.queryItems = qi.isEmpty ? nil : qi
    let url = urlComp.url!
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    var sig = auth.sign(timestampMs: ts, method: "GET", path: signedPath, bodyHashHex: HMACAuth.emptyBodyHashHex)
    if tamperSig { sig = String(sig.reversed()) }
    req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
    req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
    req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as! HTTPURLResponse
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    return (http.statusCode, json)
}

@Suite(.serialized)
struct SearchHTTPTests {
    @Test func searchReturnsHitsWithSnippet() async throws {
        let items = [
            textItem(id: "a", origin: "mac-1", text: "hello world",   capturedAtNs: 100),
            textItem(id: "b", origin: "mac-1", text: "goodbye world", capturedAtNs: 200),
            textItem(id: "c", origin: "mac-1", text: "another item",  capturedAtNs: 300),
        ]
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, body) = try await getSearch(baseURL: base, auth: auth, q: "world")
        #expect(status == 200)
        #expect(body["ok"] as? Bool == true)
        #expect(body["count"] as? Int == 2)
        let arr = body["items"] as? [[String: Any]] ?? []
        #expect(arr.count == 2)
        // 至少一条带 snippet(FTS5 命中)
        let snippets = arr.compactMap { $0["snippet"] as? String }
        #expect(!snippets.isEmpty)
        // snippet 含 STX/ETX 标记包围匹配词
        #expect(snippets.first?.contains("\u{02}") == true)
        #expect(snippets.first?.contains("\u{03}") == true)
    }

    @Test func searchFoldsCrossOriginSameText() async throws {
        // mesh dedup:同 text_full 跨 origin → fold 成一条。count 跟 list 都是 1 不是 2
        let items = [
            textItem(id: "own", origin: "mac-self",  text: "duplicate",  capturedAtNs: 100),
            textItem(id: "peer", origin: "mac-other", text: "duplicate", capturedAtNs: 200),
        ]
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, body) = try await getSearch(baseURL: base, auth: auth, q: "duplicate")
        #expect(status == 200)
        #expect(body["count"] as? Int == 1)
        let arr = body["items"] as? [[String: Any]] ?? []
        #expect(arr.count == 1)
    }

    @Test func searchEmptyQueryReturnsAllSortedByTime() async throws {
        let items = [
            textItem(id: "old", origin: "mac-1", text: "old",    capturedAtNs: 100),
            textItem(id: "mid", origin: "mac-1", text: "middle", capturedAtNs: 200),
            textItem(id: "new", origin: "mac-1", text: "newest", capturedAtNs: 300),
        ]
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, body) = try await getSearch(baseURL: base, auth: auth, q: nil)
        #expect(status == 200)
        #expect(body["count"] as? Int == 3)
        let arr = body["items"] as? [[String: Any]] ?? []
        #expect(arr.count == 3)
        // 时间倒序:newest first
        #expect(arr.first?["id"] as? String == "new")
        // 列表模式无 snippet
        #expect(arr.first?["snippet"] == nil)
    }

    @Test func searchExcludesTombstones() async throws {
        var dead = textItem(id: "dead", origin: "mac-1", text: "lost", capturedAtNs: 100)
        dead.deletedAtNs = 150
        let live = textItem(id: "live", origin: "mac-1", text: "lost", capturedAtNs: 200)
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: [dead, live])
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, body) = try await getSearch(baseURL: base, auth: auth, q: "lost")
        #expect(status == 200)
        // tombstone 不参与 fold,只命中 live 那条
        #expect(body["count"] as? Int == 1)
        let arr = body["items"] as? [[String: Any]] ?? []
        #expect(arr.first?["id"] as? String == "live")
    }

    @Test func searchRejectsBadSignature() async throws {
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: [
            textItem(id: "a", origin: "p", text: "x", capturedAtNs: 100)
        ])
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, _) = try await getSearch(baseURL: base, auth: auth, q: "x", tamperSig: true)
        #expect(status == 401)
    }

    @Test func searchClampsLimitToReasonableMax() async throws {
        // limit=99999 → server clamp 到 500;不应该崩 / 不应该返回 99999 条
        let items = (1...10).map { i in
            textItem(id: "row-\(i)", origin: "p", text: "text-\(i)", capturedAtNs: Int64(i))
        }
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, body) = try await getSearch(baseURL: base, auth: auth, q: nil, limit: 99999)
        #expect(status == 200)
        // 实际只有 10 条,limit clamp 没影响结果
        #expect(body["count"] as? Int == 10)
    }
}

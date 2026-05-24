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

private func getSearch(
    baseURL: URL,
    auth: HMACAuth,
    q: String?,
    limit: Int? = nil,
    kinds: String? = nil,
    fileSubKinds: String? = nil,
    textSuffixes: String? = nil,
    tamperSig: Bool = false
)
async throws -> (Int, [String: Any]) {
    var qi: [URLQueryItem] = []
    if let q { qi.append(URLQueryItem(name: "q", value: q)) }
    if let limit { qi.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let kinds { qi.append(URLQueryItem(name: "kinds", value: kinds)) }
    if let fileSubKinds { qi.append(URLQueryItem(name: "file_sub_kinds", value: fileSubKinds)) }
    if let textSuffixes { qi.append(URLQueryItem(name: "text_suffixes", value: textSuffixes)) }
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

/// 通用 file item 工厂——给 qualifier filter 测试用。textFull 走 LIKE 后缀路径,
/// blobMime 走 SearchAPI subKindSQL 走 mime 路径
private func fileItem(
    id: String,
    origin: String = "mac-1",
    textFull: String,
    blobMime: String? = nil,
    capturedAtNs: Int64
) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedAtNs,
        ingestedAtNs: capturedAtNs,
        kind: .file,
        preview: textFull,
        textFull: textFull,
        blobSha256: "f".repeated(64),
        blobMime: blobMime
    )
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
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

    // MARK: - Issue #41 qualifier 透传

    @Test func searchPassesKindsQualifierThroughToSearchAPI() async throws {
        // 混合 kind 库:5 text + 5 url。带 `kinds=url` 应只返 url 那 5 条
        var items: [Item] = []
        for i in 0..<5 {
            items.append(textItem(id: "t-\(i)", origin: "mac-1", text: "text item \(i)", capturedAtNs: Int64(100 + i)))
        }
        for i in 0..<5 {
            var url = textItem(id: "u-\(i)", origin: "mac-1", text: "https://example.com/\(i)", capturedAtNs: Int64(200 + i))
            url.kind = .url
            items.append(url)
        }
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        // 空 query + kinds=url → 只返 url
        let (status, body) = try await getSearch(baseURL: base, auth: auth, q: nil, kinds: "url")
        #expect(status == 200)
        #expect(body["count"] as? Int == 5)
        let arr = body["items"] as? [[String: Any]] ?? []
        #expect(arr.count == 5)
        for it in arr {
            #expect(it["kind"] as? String == "url", "expected only url items")
        }
    }

    @Test func searchPassesFileSubKindThroughToSearchAPI() async throws {
        // file sub-kind 测试:3 个 file 项,其中 1 个 PDF。`file_sub_kinds=pdf` 应只返 PDF
        var items: [Item] = []
        items.append(fileItem(id: "pdf-1", textFull: "/Users/bob/doc.pdf", blobMime: "application/pdf", capturedAtNs: 100))
        items.append(fileItem(id: "mp4-1", textFull: "/Users/bob/clip.mp4", blobMime: "video/mp4", capturedAtNs: 200))
        items.append(fileItem(id: "mp3-1", textFull: "/Users/bob/song.mp3", blobMime: "audio/mpeg", capturedAtNs: 300))
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, body) = try await getSearch(baseURL: base, auth: auth, q: nil, fileSubKinds: "pdf")
        #expect(status == 200)
        #expect(body["count"] as? Int == 1)
        let arr = body["items"] as? [[String: Any]] ?? []
        #expect(arr.first?["id"] as? String == "pdf-1")
    }

    @Test func searchMixedKindAndSubKindOR() async throws {
        // OR 关系:`kinds=url` + `file_sub_kinds=pdf` 命中 url OR pdf-file
        var items: [Item] = []
        items.append(textItem(id: "txt-1", origin: "mac-1", text: "plain text", capturedAtNs: 100))
        var url = textItem(id: "url-1", origin: "mac-1", text: "https://example.com", capturedAtNs: 200)
        url.kind = .url
        items.append(url)
        items.append(fileItem(id: "pdf-1", textFull: "/path/doc.pdf", blobMime: "application/pdf", capturedAtNs: 300))
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, body) = try await getSearch(
            baseURL: base, auth: auth, q: nil,
            kinds: "url", fileSubKinds: "pdf"
        )
        #expect(status == 200)
        // url + pdf = 2(不含 plain text)
        #expect(body["count"] as? Int == 2)
        let arr = body["items"] as? [[String: Any]] ?? []
        #expect(arr.count == 2)
        let ids = Set(arr.compactMap { $0["id"] as? String })
        #expect(ids == ["url-1", "pdf-1"])
    }

    @Test func searchTextSuffixesFiltersByExtension() async throws {
        // textSuffix 路径:textFull 末尾 LIKE。3 file 项分别 .java / .py / .swift,
        // text_suffixes=.java,.py 只返前两条
        var items: [Item] = []
        items.append(fileItem(id: "java-1", textFull: "/Users/bob/Main.java", capturedAtNs: 100))
        items.append(fileItem(id: "py-1", textFull: "/Users/bob/script.py", capturedAtNs: 200))
        items.append(fileItem(id: "swift-1", textFull: "/Users/bob/App.swift", capturedAtNs: 300))
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, body) = try await getSearch(
            baseURL: base, auth: auth, q: nil,
            textSuffixes: ".java,.py"
        )
        #expect(status == 200)
        #expect(body["count"] as? Int == 2)
        let arr = body["items"] as? [[String: Any]] ?? []
        let ids = Set(arr.compactMap { $0["id"] as? String })
        #expect(ids == ["java-1", "py-1"])
    }

    @Test func searchTextSuffixesAutoPrependsDot() async throws {
        // 老 client / 手填 URL 可能不带 `.`——server 端自动补 `.`,语义跟带 `.` 等价
        var items: [Item] = []
        items.append(fileItem(id: "java-1", textFull: "/Users/bob/Main.java", capturedAtNs: 100))
        items.append(fileItem(id: "py-1", textFull: "/Users/bob/x.py", capturedAtNs: 200))
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        let (status, body) = try await getSearch(
            baseURL: base, auth: auth, q: nil,
            textSuffixes: "java"  // 没 dot
        )
        #expect(status == 200)
        #expect(body["count"] as? Int == 1)
        #expect((body["items"] as? [[String: Any]])?.first?["id"] as? String == "java-1")
    }

    @Test func searchUnknownKindIsSilentlyIgnored() async throws {
        // 不识别 kind token → 静默丢,跟"无 kinds 过滤"等价(不报错,不挂 500)。
        // 让老 client 发出未来 server 没有的 kind 时 graceful degrade
        var items: [Item] = []
        items.append(textItem(id: "t-1", origin: "mac-1", text: "hello", capturedAtNs: 100))
        items.append(textItem(id: "t-2", origin: "mac-1", text: "world", capturedAtNs: 200))
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        // bogus kind → kinds 解析后为空数组 → 不 filter,跟没 kinds 等价
        let (status, body) = try await getSearch(
            baseURL: base, auth: auth, q: nil, kinds: "bogus_kind"
        )
        #expect(status == 200)
        #expect(body["count"] as? Int == 2)
    }

    @Test func searchOldClientWithoutQualifiersUnchanged() async throws {
        // 老 client 不发 kinds / file_sub_kinds / text_suffixes —— 行为完全等价于 PR 之前
        // (zero regression)。回归测试已经在 searchReturnsHitsWithSnippet 等,这里再独立钉一次
        let items = [
            textItem(id: "a", origin: "mac-1", text: "hello world", capturedAtNs: 100),
            textItem(id: "b", origin: "mac-1", text: "another", capturedAtNs: 200),
        ]
        let (db, blobs, auth, port) = try makeSearchServerFixture(items: items)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadySearch(baseURL: base, auth: auth))

        // 仅 q,不发任何 qualifier query param
        let (status, body) = try await getSearch(baseURL: base, auth: auth, q: "hello")
        #expect(status == 200)
        #expect(body["count"] as? Int == 1)
        #expect((body["items"] as? [[String: Any]])?.first?["id"] as? String == "a")
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

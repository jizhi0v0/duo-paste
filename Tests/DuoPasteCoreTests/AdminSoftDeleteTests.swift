import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

// plan hashed-allen §F:Admin.softDelete 走 HTTP localhost 优先 + daemon offline 降级直 DB。
// 两条路径单测:HTTP path 用注入 mock httpSender;direct DB path 用 forceDirect=true 真接 SQLite。

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-admin-softdel-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func seedTextItem(
    db: DuoPasteCore.Database,
    id: String,
    origin: String,
    text: String,
    capturedAtNs: Int64 = 100,
    ingestedAtNs: Int64 = 100
) async throws {
    let row = Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedAtNs,
        ingestedAtNs: ingestedAtNs,
        kind: .text,
        preview: text,
        textFull: text
    )
    try await db.pool.write { try row.insert($0) }
}

@Test func adminSoftDeleteHTTPPathSucceeds() async throws {
    // HTTP path:mock URLSession 返 200 + valid payload → 解出 deletedCount + maxIngest
    let dir = tempDir()
    let dbPath = dir.appendingPathComponent("main.sqlite")
    // tmp DB 必须存在(虽 HTTP path 不读),Database(path:) 在 Admin.softDelete 入口构造时也只在
    // 降级路径才创建,所以这里不需要预热 DB

    let secret = Data(count: 32)
    let baseURL = URL(string: "http://127.0.0.1:8443")!

    // 验证 HMAC header 被设上 + DELETE method + 正确 path
    let sender: Admin.AdminHTTPSender = { req in
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.path == "/item/abc123")
        #expect(req.value(forHTTPHeaderField: HMACAuth.timestampHeader) != nil)
        #expect(req.value(forHTTPHeaderField: HMACAuth.bodyHashHeader) == HMACAuth.emptyBodyHashHex)
        #expect(req.value(forHTTPHeaderField: HMACAuth.signatureHeader) != nil)
        let payload: [String: Any] = ["ok": true, "ingested_at_ns": 12345, "deleted_count": 3]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, resp)
    }

    let result = try await Admin.softDelete(
        id: "abc123",
        sharedSecret: secret,
        baseURL: baseURL,
        dbPath: dbPath,
        httpSender: sender
    )
    switch result {
    case .viaHTTP(let r):
        #expect(r.deletedCount == 3)
        #expect(r.maxIngestedNs == 12345)
    case .directDB:
        Issue.record("expected HTTP path")
    }
}

@Test func adminSoftDeleteHTTP404ThrowsNotFound() async throws {
    let sender: Admin.AdminHTTPSender = { req in
        let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data("not found".utf8), resp)
    }
    let dbPath = tempDir().appendingPathComponent("main.sqlite")
    await #expect(throws: Admin.AdminSoftDeleteError.notFound) {
        _ = try await Admin.softDelete(
            id: "ghost",
            sharedSecret: Data(count: 32),
            baseURL: URL(string: "http://127.0.0.1:8443")!,
            dbPath: dbPath,
            httpSender: sender
        )
    }
}

@Test func adminSoftDeleteHTTP410ThrowsAlreadyDeleted() async throws {
    let sender: Admin.AdminHTTPSender = { req in
        let resp = HTTPURLResponse(url: req.url!, statusCode: 410, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data("gone".utf8), resp)
    }
    let dbPath = tempDir().appendingPathComponent("main.sqlite")
    await #expect(throws: Admin.AdminSoftDeleteError.alreadyDeleted) {
        _ = try await Admin.softDelete(
            id: "dead",
            sharedSecret: Data(count: 32),
            baseURL: URL(string: "http://127.0.0.1:8443")!,
            dbPath: dbPath,
            httpSender: sender
        )
    }
}

@Test func adminSoftDeleteHTTPDaemonOfflineFallsBackToDirectDB() async throws {
    // mock URLError.cannotConnectToHost → 降级直 DB
    let dir = tempDir()
    let dbPath = dir.appendingPathComponent("main.sqlite")
    let db = try DuoPasteCore.Database(path: dbPath)
    try await seedTextItem(db: db, id: "x", origin: "self", text: "hello")
    try await seedTextItem(db: db, id: "y", origin: "peer", text: "hello")

    let sender: Admin.AdminHTTPSender = { _ in
        throw URLError(.cannotConnectToHost)
    }
    let result = try await Admin.softDelete(
        id: "x",
        sharedSecret: Data(count: 32),
        baseURL: URL(string: "http://127.0.0.1:8443")!,
        dbPath: dbPath,
        httpSender: sender
    )
    switch result {
    case .viaHTTP:
        Issue.record("expected direct DB fallback")
    case .directDB(let r, let warn):
        // cascade 删了 x + y (同 text_full "hello",跨 origin)
        #expect(Set(r.ids) == ["x", "y"])
        #expect(r.maxIngestedNs > 100)
        #expect(warn.contains("PullWorker tick"))
    }

    // 验证 DB 里两条行都 tombstone
    let alive = try await db.pool.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM item WHERE deleted_at_ns IS NULL") ?? 0
    }
    #expect(alive == 0)
}

@Test func adminSoftDeleteForceDirectSkipsHTTP() async throws {
    // forceDirect=true → 不调 httpSender,直接走 DB path
    let dir = tempDir()
    let dbPath = dir.appendingPathComponent("main.sqlite")
    let db = try DuoPasteCore.Database(path: dbPath)
    try await seedTextItem(db: db, id: "x", origin: "self", text: "hi")

    let senderCalled = SenderCounter()
    let sender: Admin.AdminHTTPSender = { _ in
        await senderCalled.mark()
        throw URLError(.badURL)  // 不应该被调到
    }

    let result = try await Admin.softDelete(
        id: "x",
        sharedSecret: Data(count: 32),
        baseURL: URL(string: "http://127.0.0.1:8443")!,
        dbPath: dbPath,
        forceDirect: true,
        httpSender: sender
    )
    #expect(await senderCalled.value == false, "forceDirect=true 不该调 httpSender")
    switch result {
    case .viaHTTP:
        Issue.record("expected direct DB")
    case .directDB(let r, _):
        #expect(r.ids == ["x"])
    }
}

@Test func adminSoftDeleteDirectDBNotFoundThrowsError() async throws {
    let dir = tempDir()
    let dbPath = dir.appendingPathComponent("main.sqlite")
    _ = try DuoPasteCore.Database(path: dbPath)  // 建空 DB

    await #expect(throws: Admin.AdminSoftDeleteError.notFound) {
        _ = try await Admin.softDelete(
            id: "ghost",
            sharedSecret: Data(count: 32),
            baseURL: URL(string: "http://127.0.0.1:8443")!,
            dbPath: dbPath,
            forceDirect: true
        )
    }
}

// PR review:HMAC canonical path 必须跟 wire path 字节一致——id 含特殊字符时
// (URL path 不允许的 `/` `%` `#` 等),client 必须显式 percent-encode + 用 encoded
// 形式签名,否则跟 server 的 request.uri.path(raw bytes)对不上 → 静默 401。
// 生产 id 是 UUID 不会触发,但 future 校验防回归
@Test func adminSoftDeleteHMACCanonicalMatchesWirePath() async throws {
    // id 含 `%` 触发 percent-encoding(`%` → `%25`);wire path 必须用 encoded 形式,
    // 签名的 canonical 必须用同 encoded 形式
    let weirdID = "id-with-%-sign"
    let secret = Data(repeating: 0xAB, count: 32)
    let baseURL = URL(string: "http://127.0.0.1:8443")!

    // sender 拿到 request 后:从 URL 取 encoded path,自己用同 secret 重算签名,
    // 跟 header 里的签名比对——一致则说明 client 签的 canonical 跟 wire 的 path 对齐
    let sender: Admin.AdminHTTPSender = { req in
        let auth = HMACAuth(secret: secret)
        // 从 URL 取**实际发出去的** encoded path
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let wirePath = comps.percentEncodedPath
        // server middleware 视角:用 wirePath 当 canonical 算签名
        let canonical = HMACAuth.canonicalPath(wirePath)
        let ts = Int64(req.value(forHTTPHeaderField: HMACAuth.timestampHeader)!)!
        let recomputed = auth.sign(
            timestampMs: ts,
            method: "DELETE",
            path: canonical,
            bodyHashHex: HMACAuth.emptyBodyHashHex
        )
        let headerSig = req.value(forHTTPHeaderField: HMACAuth.signatureHeader)!
        #expect(recomputed == headerSig,
            "client canonical 跟 wire path 应对齐:wire=\(wirePath) header_sig=\(headerSig) recomputed=\(recomputed)")
        // wire path 必须包含 encoded `%25`,**不**含 raw `%`(后者会让 URL 解析二义)
        #expect(wirePath.contains("%25"), "wire path 应已 percent-encode `%` → `%25`,实际 wire=\(wirePath)")
        let payload: [String: Any] = ["ok": true, "ingested_at_ns": 1, "deleted_count": 1]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, resp)
    }

    let result = try await Admin.softDelete(
        id: weirdID,
        sharedSecret: secret,
        baseURL: baseURL,
        dbPath: tempDir().appendingPathComponent("x.sqlite"),
        httpSender: sender
    )
    if case .directDB = result {
        Issue.record("expected HTTP path")
    }
}

// 帮助 actor:验证 sender 是否被调
private actor SenderCounter {
    var value: Bool = false
    func mark() { value = true }
}

import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private func makeServerFixture(items: [Item]) throws -> TestSyncServerFixture {
    try TestSyncServerFixture(prefix: "duo-since-http", items: items)
}

private func withSinceServer<Value>(
    items: [Item],
    ponteHostProvider: @escaping @Sendable () -> String? = { nil },
    operation: (URL, HMACAuth) async throws -> Value
) async throws -> Value {
    let fixture = try makeServerFixture(items: items)
    let server = SyncServer(
        deviceID: "p",
        database: fixture.database,
        blobs: fixture.blobs,
        host: "127.0.0.1",
        port: 0,
        auth: fixture.auth,
        ponteHostProvider: ponteHostProvider
    )
    return try await fixture.withServer(server) { baseURL in
        try await operation(baseURL, fixture.auth)
    }
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
        deletedAtNs: deletedAtNs
    )
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
    let (status, body) = try await withSinceServer(items: [
        item(id: "a", ingestedAtNs: 10),
        item(id: "b", ingestedAtNs: 20),
        item(id: "c", ingestedAtNs: 30),
    ]) { base, auth in
        try await getSince(baseURL: base, auth: auth)
    }
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
    let ((s1, b1), (s2, b2)) = try await withSinceServer(items: [
        item(id: "a", ingestedAtNs: 1),
        item(id: "b", ingestedAtNs: 2),
        item(id: "c", ingestedAtNs: 3),
        item(id: "d", ingestedAtNs: 4),
    ]) { base, auth in
        let first = try await getSince(baseURL: base, auth: auth, limit: 2)
        let nc = first.1["next_cursor"] as? [String: Any] ?? [:]
        let nextNs = (nc["ingested_at_ns"] as? Int64) ?? Int64(nc["ingested_at_ns"] as? Int ?? 0)
        let nextID = nc["id"] as? String ?? ""
        let second = try await getSince(
            baseURL: base, auth: auth,
            cursorNs: nextNs, cursorID: nextID, limit: 2
        )
        return (first, second)
    }
    #expect(s1 == 200)
    let p1Items = b1["items"] as? [[String: Any]] ?? []
    #expect(p1Items.map { $0["id"] as? String } == ["a", "b"])
    #expect(b1["has_more"] as? Bool == true)
    #expect(s2 == 200)
    let p2Items = b2["items"] as? [[String: Any]] ?? []
    #expect(p2Items.map { $0["id"] as? String } == ["c", "d"])
    #expect(b2["has_more"] as? Bool == true)  // == limit
}

@Test func sinceHTTPRejectsBadSignature() async throws {
    let (status, _) = try await withSinceServer(items: [
        item(id: "a", ingestedAtNs: 1),
    ]) { base, _ in
        // 用错的 secret 签名 → 期望 401
        let badAuth = HMACAuth(secret: Data(repeating: 0xFF, count: 32))
        return try await getSince(baseURL: base, auth: badAuth)
    }
    #expect(status == 401)
}

@Test func sinceHTTPIncludesSoftDeleted() async throws {
    let (status, body) = try await withSinceServer(items: [
        item(id: "alive", ingestedAtNs: 1),
        item(id: "dead", ingestedAtNs: 2, deletedAtNs: 999),
    ]) { base, auth in
        try await getSince(baseURL: base, auth: auth)
    }
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
    let (page, next) = try await withSinceServer(items: [
        item(id: "x1", ingestedAtNs: 100),
        item(id: "x2", ingestedAtNs: 200),
    ]) { base, auth in
        let page = try await decodeSince(baseURL: base, auth: auth)
        let next = try await decodeSince(
            baseURL: base,
            auth: auth,
            cursorNs: page.nextCursor.ingestedAtNs,
            cursorID: page.nextCursor.id
        )
        return (page, next)
    }
    #expect(page.ok == true)
    #expect(page.count == 2)
    #expect(page.items.map(\.id) == ["x1", "x2"])
    #expect(page.hasMore == false)
    #expect(page.totalCount == 2)
    #expect(page.sourceDeviceID == "p")
    #expect(page.nextCursor.ingestedAtNs == 200)
    #expect(page.nextCursor.id == "x2")
    // 把 nextCursor 喂回去，验证 round-trip 收敛到空 + 同 cursor
    #expect(next.items.isEmpty)
    #expect(next.nextCursor == page.nextCursor)
    #expect(next.totalCount == 2)
    #expect(next.sourceDeviceID == "p")
}

@Test func healthSurfacesPonteHostFromProvider() async throws {
    // ponteHostProvider 注入固定值 → /health 返回 ponte_host=test.sgponte
    // → HTTPPeerClient.fetchPrimaryHealth decode 出来在 outcome.ok 第三参数
    // 测的是 wire 端到端：server JSON 编 + client decode 一条龙
    let result = try await withSinceServer(items: [], ponteHostProvider: { "test.sgponte" }) {
        base, auth in
        try await HTTPPeerClient(baseURL: base, auth: auth, session: .shared)
            .fetchPrimaryHealth()
    }
    guard case .ok(let deviceID, _, let ponteHost) = result.outcome else {
        Issue.record("health 非 ok：\(result.outcome)")
        return
    }
    #expect(deviceID == "p")
    #expect(ponteHost == "test.sgponte")
}

@Test func healthPonteHostNilWhenProviderReturnsNil() async throws {
    // ponteHostProvider 返回 nil（没装 Surge / 没配 Ponte）→ wire JSON 不写 ponte_host 键
    // → client decodeIfPresent 给 nil。老 daemon 不返回该键的兼容路径也走这条
    let result = try await withSinceServer(items: []) { base, auth in
        try await HTTPPeerClient(baseURL: base, auth: auth, session: .shared)
            .fetchPrimaryHealth()
    }
    guard case .ok(_, _, let ponteHost) = result.outcome else {
        Issue.record("health 非 ok：\(result.outcome)")
        return
    }
    #expect(ponteHost == nil)
}

@Test func sinceHTTPEmptyResultPreservesCursor() async throws {
    let (status, body) = try await withSinceServer(items: [
        item(id: "a", ingestedAtNs: 5),
    ]) { base, auth in
        // cursor 已经超过所有数据 → 空结果，next_cursor 原样回来
        try await getSince(
            baseURL: base,
            auth: auth,
            cursorNs: 1_000_000,
            cursorID: "zzz"
        )
    }
    #expect(status == 200)
    #expect((body["items"] as? [[String: Any]])?.isEmpty == true)
    #expect(body["has_more"] as? Bool == false)
    let nc = body["next_cursor"] as? [String: Any] ?? [:]
    let returnedNs = (nc["ingested_at_ns"] as? Int64) ?? Int64(nc["ingested_at_ns"] as? Int ?? 0)
    #expect(returnedNs == 1_000_000)
    #expect(nc["id"] as? String == "zzz")
}

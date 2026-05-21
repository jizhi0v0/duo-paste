import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// `POST /pin/<id>?pinned=0|1`:跨 origin 切 pin 的 HTTP 路径(给 iOS contextMenu 用)。
/// 跟 /bump /item DELETE 同 pattern 验:HMAC + body-sha 校 + DB 落库 + broadcaster fan-out。
/// noop 路径(已是目标状态)200 但**不**调 onItemMutated 也**不** fan-out——cursor 没动,
/// fan-out 等于让 peer pull 空页浪费 RTT。

private typealias DuoDB = DuoPasteCore.Database

private func makePinServerFixture(items: [Item]) throws -> (DuoDB, BlobStore, HMACAuth, Int) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-pin-http-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try DuoDB(path: paths.mainDB)
    try db.pool.write { conn in
        for it in items { try it.insert(conn) }
    }
    let blobs = BlobStore(root: paths.blobsDir)
    try FileManager.default.createDirectory(at: blobs.root, withIntermediateDirectories: true)
    let auth = HMACAuth(secret: Data(repeating: 0xCD, count: 32))
    let port = Int.random(in: 20500..<21500)
    return (db, blobs, auth, port)
}

private func pinItemFixture(id: String, pinned: Bool = false, originDevice: String = "mac-self", deletedAtNs: Int64? = nil) -> Item {
    var it = Item(
        id: id,
        originDevice: originDevice,
        capturedAtNs: 100,
        ingestedAtNs: 100,
        kind: .text,
        preview: "x",
        textFull: "x",
        pinned: pinned
    )
    it.deletedAtNs = deletedAtNs
    return it
}

private final class PinCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String, Int64)] = []

    func append(id: String, ingestedAtNs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        events.append((id, ingestedAtNs))
    }

    func snapshot() -> [(String, Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private func waitReadyPin(baseURL: URL, auth: HMACAuth) async -> Bool {
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

private func postPin(baseURL: URL, auth: HMACAuth, id: String, pinnedQ: String, tamperSig: Bool = false)
async throws -> (Int, [String: Any]) {
    var sigComp = URLComponents()
    sigComp.path = "/pin/\(id)"
    sigComp.queryItems = [URLQueryItem(name: "pinned", value: pinnedQ)]
    let signedPath = HMACAuth.canonicalPath("/pin/\(id)", query: sigComp.percentEncodedQuery)

    var urlComp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    urlComp.path = "/pin/\(id)"
    urlComp.queryItems = [URLQueryItem(name: "pinned", value: pinnedQ)]
    let url = urlComp.url!

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.httpBody = Data()
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let bodyHash = HMACAuth.emptyBodyHashHex
    var sig = auth.sign(timestampMs: ts, method: "POST", path: signedPath, bodyHashHex: bodyHash)
    if tamperSig { sig = String(sig.reversed()) }
    req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
    req.setValue(bodyHash, forHTTPHeaderField: HMACAuth.bodyHashHeader)
    req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as! HTTPURLResponse
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    return (http.statusCode, json)
}

@Suite(.serialized)
struct PinHTTPTests {
    /// own-origin 行 0→1 切换:DB 落 pinned=1 + bump ingested_at_ns + onItemMutated 收到事件
    @Test func pinHTTPFlipsRowFromZeroToOne() async throws {
        let (db, blobs, auth, port) = try makePinServerFixture(items: [pinItemFixture(id: "row-1")])
        let broadcaster = WSBroadcaster(rotationIntervalSec: 0)
        let callback = PinCallbackBox()
        let server = SyncServer(deviceID: "mac-self", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth, broadcaster: broadcaster,
                                onItemMutated: { id, ingestedAtNs in
                                    callback.append(id: id, ingestedAtNs: ingestedAtNs)
                                })
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPin(baseURL: base, auth: auth))

        let (status, body) = try await postPin(baseURL: base, auth: auth, id: "row-1", pinnedQ: "1")
        #expect(status == 200)
        #expect(body["ok"] as? Bool == true)
        #expect(body["pinned"] as? Bool == true)
        #expect(body["noop"] == nil)
        let newIngest = (body["ingested_at_ns"] as? Int64) ?? Int64(body["ingested_at_ns"] as? Int ?? 0)
        #expect(newIngest > 100)

        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "row-1").fetchOne(conn)!
        }
        #expect(after.pinned == true)
        #expect(after.ingestedAtNs == newIngest)
        #expect(after.capturedAtNs == 100)  // **不**改 captured_at_ns —— pin 是元数据非顺序
        #expect(callback.snapshot().count == 1)
        #expect(callback.snapshot().first?.0 == "row-1")
        #expect(callback.snapshot().first?.1 == newIngest)
    }

    /// 已 pinned=1 → 1 noop:200 + noop=true,**不** onItemMutated 也**不** bump ingested_at_ns
    @Test func pinHTTPNoOpWhenAlreadyAtTargetState() async throws {
        let (db, blobs, auth, port) = try makePinServerFixture(items: [pinItemFixture(id: "row-1", pinned: true)])
        let callback = PinCallbackBox()
        let server = SyncServer(deviceID: "mac-self", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth,
                                onItemMutated: { id, ingestedAtNs in
                                    callback.append(id: id, ingestedAtNs: ingestedAtNs)
                                })
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPin(baseURL: base, auth: auth))

        let (status, body) = try await postPin(baseURL: base, auth: auth, id: "row-1", pinnedQ: "1")
        #expect(status == 200)
        #expect(body["noop"] as? Bool == true)
        #expect(body["pinned"] as? Bool == true)
        #expect(body["ingested_at_ns"] == nil)

        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "row-1").fetchOne(conn)!
        }
        #expect(after.ingestedAtNs == 100)  // 未 bump
        #expect(callback.snapshot().isEmpty)  // noop 不调 onItemMutated
    }

    /// mirror 行(origin != self)也能 pin —— setPinnedAny 不带 own-origin guard
    @Test func pinHTTPAcceptsMirrorOriginRow() async throws {
        let (db, blobs, auth, port) = try makePinServerFixture(items: [
            pinItemFixture(id: "mirror-1", originDevice: "other-device")
        ])
        let server = SyncServer(deviceID: "mac-self", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPin(baseURL: base, auth: auth))

        let (status, body) = try await postPin(baseURL: base, auth: auth, id: "mirror-1", pinnedQ: "1")
        #expect(status == 200)
        #expect(body["pinned"] as? Bool == true)
        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "mirror-1").fetchOne(conn)!
        }
        #expect(after.pinned == true)
        #expect(after.originDevice == "other-device")  // origin 不动
    }

    /// 错误 query: pinned 缺失 / 非 0/1 → 400
    @Test func pinHTTPReturns400ForInvalidPinnedQuery() async throws {
        let (db, blobs, auth, port) = try makePinServerFixture(items: [pinItemFixture(id: "row-1")])
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPin(baseURL: base, auth: auth))

        // pinned=2 → 400(只接受 0/1)
        let (status, _) = try await postPin(baseURL: base, auth: auth, id: "row-1", pinnedQ: "2")
        #expect(status == 400)
    }

    /// bad signature → 401
    @Test func pinHTTPRejectsBadSignature() async throws {
        let (db, blobs, auth, port) = try makePinServerFixture(items: [pinItemFixture(id: "row-1")])
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPin(baseURL: base, auth: auth))

        let (status, _) = try await postPin(baseURL: base, auth: auth, id: "row-1", pinnedQ: "1", tamperSig: true)
        #expect(status == 401)

        // DB 状态没变
        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "row-1").fetchOne(conn)!
        }
        #expect(after.pinned == false)
    }

    /// 不存在的 id → 404
    @Test func pinHTTPReturns404ForUnknownID() async throws {
        let (db, blobs, auth, port) = try makePinServerFixture(items: [])
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPin(baseURL: base, auth: auth))

        let (status, _) = try await postPin(baseURL: base, auth: auth, id: "ghost", pinnedQ: "1")
        #expect(status == 404)
    }

    /// tombstone → 410(client 当幂等"已删除"swallow)
    @Test func pinHTTPReturns410ForTombstone() async throws {
        let dead = pinItemFixture(id: "dead-1", deletedAtNs: 200)
        let (db, blobs, auth, port) = try makePinServerFixture(items: [dead])
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: port, auth: auth)
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPin(baseURL: base, auth: auth))

        let (status, _) = try await postPin(baseURL: base, auth: auth, id: "dead-1", pinnedQ: "1")
        #expect(status == 410)
    }
}

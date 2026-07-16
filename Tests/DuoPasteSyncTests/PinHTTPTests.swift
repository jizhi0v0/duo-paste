import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// `POST /pin/<id>?pinned=0|1`:跨 origin 切 pin 的 HTTP 路径(给 iOS contextMenu 用)。
/// 跟 /bump /item DELETE 同 pattern 验:HMAC + body-sha 校 + DB 落库 + broadcaster fan-out。
/// noop 路径(已是目标状态)200 但**不**调 onItemMutated 也**不** fan-out——cursor 没动,
/// fan-out 等于让 peer pull 空页浪费 RTT。

private func makePinServerFixture(items: [Item]) throws -> TestSyncServerFixture {
    try TestSyncServerFixture(prefix: "duo-pin-http", items: items, secretByte: 0xCD)
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

private func postPin(
    baseURL: URL,
    auth: HMACAuth,
    id: String,
    pinnedQ: String,
    operationID: String? = nil,
    tamperSig: Bool = false
)
async throws -> (Int, [String: Any]) {
    var queryItems = [URLQueryItem(name: "pinned", value: pinnedQ)]
    if let operationID { queryItems.append(URLQueryItem(name: "operation_id", value: operationID)) }
    var sigComp = URLComponents()
    sigComp.path = "/pin/\(id)"
    sigComp.queryItems = queryItems
    let signedPath = HMACAuth.canonicalPath("/pin/\(id)", query: sigComp.percentEncodedQuery)

    var urlComp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    urlComp.path = "/pin/\(id)"
    urlComp.queryItems = queryItems
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
        let fixture = try makePinServerFixture(items: [pinItemFixture(id: "row-1")])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let broadcaster = WSBroadcaster(rotationIntervalSec: 0)
        let callback = PinCallbackBox()
        let server = SyncServer(deviceID: "mac-self", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth, broadcaster: broadcaster,
                                onItemMutated: { id, ingestedAtNs in
                                    callback.append(id: id, ingestedAtNs: ingestedAtNs)
                                })
        let (status, body) = try await fixture.withServer(server) { base in
            try await postPin(baseURL: base, auth: auth, id: "row-1", pinnedQ: "1")
        }
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

    /// 首次绝对值 command 即使已是目标也 bump 一次，确保 requester cursor 能观察 replay。
    @Test func pinHTTPAtTargetStillCreatesCanonicalReplay() async throws {
        let fixture = try makePinServerFixture(items: [pinItemFixture(id: "row-1", pinned: true)])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let callback = PinCallbackBox()
        let server = SyncServer(deviceID: "mac-self", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth,
                                onItemMutated: { id, ingestedAtNs in
                                    callback.append(id: id, ingestedAtNs: ingestedAtNs)
                                })
        let (status, body) = try await fixture.withServer(server) { base in
            try await postPin(baseURL: base, auth: auth, id: "row-1", pinnedQ: "1")
        }
        #expect(status == 200)
        #expect(body["state"] as? String == "applied")
        #expect(body["pinned"] as? Bool == true)
        #expect(body["ingested_at_ns"] != nil)

        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "row-1").fetchOne(conn)!
        }
        #expect((after.ingestedAtNs ?? 0) > 100)
        #expect(callback.snapshot().count == 1)
    }

    /// mirror 行只乐观更新 + 持久化 command，不能 bump 本机 cursor 冒充 owner。
    @Test func pinHTTPQueuesMirrorOriginRowForOwner() async throws {
        let fixture = try makePinServerFixture(items: [
            pinItemFixture(id: "mirror-1", originDevice: "other-device")
        ])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "mac-self", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, body) = try await fixture.withServer(server) { base in
            try await postPin(baseURL: base, auth: auth, id: "mirror-1", pinnedQ: "1")
        }
        #expect(status == 202)
        #expect(body["state"] as? String == "pending")
        #expect(body["pinned"] as? Bool == true)
        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "mirror-1").fetchOne(conn)!
        }
        #expect(after.pinned == true)
        #expect(after.originDevice == "other-device")  // origin 不动
        #expect(after.ingestedAtNs == 100)
        #expect(try await db.pendingPinItemIDs() == Set(["mirror-1"]))
    }

    @Test func pinHTTPDuplicateOperationIDReturnsSameReceiptWithoutSecondBump() async throws {
        let fixture = try makePinServerFixture(items: [pinItemFixture(id: "row-1")])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let callback = PinCallbackBox()
        let server = SyncServer(
            deviceID: "mac-self", database: db, blobs: blobs,
            host: "127.0.0.1", port: 0, auth: auth,
            onItemMutated: { callback.append(id: $0, ingestedAtNs: $1) }
        )
        let (first, second) = try await fixture.withServer(server) { base in
            let first = try await postPin(
                baseURL: base, auth: auth, id: "row-1", pinnedQ: "1", operationID: "stable-op"
            )
            let second = try await postPin(
                baseURL: base, auth: auth, id: "row-1", pinnedQ: "1", operationID: "stable-op"
            )
            return (first, second)
        }
        #expect(first.0 == 200)
        #expect(second.0 == 200)
        #expect(second.1["duplicate"] as? Bool == true)
        #expect(first.1["ingested_at_ns"] as? Int == second.1["ingested_at_ns"] as? Int)
        #expect(callback.snapshot().count == 1)
    }

    /// 错误 query: pinned 缺失 / 非 0/1 → 400
    @Test func pinHTTPReturns400ForInvalidPinnedQuery() async throws {
        let fixture = try makePinServerFixture(items: [pinItemFixture(id: "row-1")])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)

        // pinned=2 → 400(只接受 0/1)
        let (status, _) = try await fixture.withServer(server) { base in
            try await postPin(baseURL: base, auth: auth, id: "row-1", pinnedQ: "2")
        }
        #expect(status == 400)
    }

    /// bad signature → 401
    @Test func pinHTTPRejectsBadSignature() async throws {
        let fixture = try makePinServerFixture(items: [pinItemFixture(id: "row-1")])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, _) = try await fixture.withServer(server) { base in
            try await postPin(
                baseURL: base,
                auth: auth,
                id: "row-1",
                pinnedQ: "1",
                tamperSig: true
            )
        }
        #expect(status == 401)

        // DB 状态没变
        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "row-1").fetchOne(conn)!
        }
        #expect(after.pinned == false)
    }

    /// 不存在的 id → 404
    @Test func pinHTTPReturns404ForUnknownID() async throws {
        let fixture = try makePinServerFixture(items: [])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, _) = try await fixture.withServer(server) { base in
            try await postPin(baseURL: base, auth: auth, id: "ghost", pinnedQ: "1")
        }
        #expect(status == 404)
    }

    /// tombstone → 410(client 当幂等"已删除"swallow)
    @Test func pinHTTPReturns410ForTombstone() async throws {
        let dead = pinItemFixture(id: "dead-1", deletedAtNs: 200)
        let fixture = try makePinServerFixture(items: [dead])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, _) = try await fixture.withServer(server) { base in
            try await postPin(baseURL: base, auth: auth, id: "dead-1", pinnedQ: "1")
        }
        #expect(status == 410)
    }
}

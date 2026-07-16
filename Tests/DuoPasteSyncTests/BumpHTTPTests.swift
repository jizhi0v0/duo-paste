import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// Plan #2 POST /bump/<id>:跨设备一致"复制即顶"的 HTTP 路径。
/// 验证:HMAC 通过 → bump 落库 → broadcaster fan-out cursor_advanced。
/// 失败路径:tombstone → 410, unknown id → 404, bad sig → 401。

private func makeBumpServerFixture(items: [Item]) throws -> TestSyncServerFixture {
    try TestSyncServerFixture(prefix: "duo-bump-http", items: items, secretByte: 0xCD)
}

private func bumpItem(id: String) -> Item {
    Item(
        id: id,
        originDevice: "mac-self",
        capturedAtNs: 100,
        ingestedAtNs: 100,
        kind: .text,
        preview: "x",
        textFull: "x"
    )
}

private final class BumpCallbackBox: @unchecked Sendable {
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

private func postBump(baseURL: URL, auth: HMACAuth, id: String, tamperSig: Bool = false)
async throws -> (Int, [String: Any]) {
    let path = "/bump/\(id)"
    let url = baseURL.appendingPathComponent(path)
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.httpBody = Data()
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let bodyHash = HMACAuth.emptyBodyHashHex
    var sig = auth.sign(timestampMs: ts, method: "POST", path: path, bodyHashHex: bodyHash)
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
struct BumpHTTPTests {
    @Test func bumpHTTPSucceedsAndBumpsDB() async throws {
        let fixture = try makeBumpServerFixture(items: [bumpItem(id: "row-1")])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let broadcaster = WSBroadcaster(rotationIntervalSec: 0)
        let callback = BumpCallbackBox()
        let server = SyncServer(deviceID: "mac-self", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth, broadcaster: broadcaster,
                                onItemMutated: { id, ingestedAtNs in
                                    callback.append(id: id, ingestedAtNs: ingestedAtNs)
                                })
        let beforeIngested = try await db.pool.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT ingested_at_ns FROM item WHERE id='row-1'")
        }
        #expect(beforeIngested == 100)

        let (status, body) = try await fixture.withServer(server) { base in
            try await postBump(baseURL: base, auth: auth, id: "row-1")
        }
        #expect(status == 200)
        #expect(body["ok"] as? Bool == true)
        let newIngest = (body["ingested_at_ns"] as? Int64) ?? Int64(body["ingested_at_ns"] as? Int ?? 0)
        #expect(newIngest > 100)

        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "row-1").fetchOne(conn)!
        }
        #expect(after.ingestedAtNs == newIngest)
        #expect(after.capturedAtNs > 100)                  // 也被顶
        #expect(after.originDevice == "mac-self")          // origin 不动
        #expect(callback.snapshot().count == 1)
        #expect(callback.snapshot().first?.0 == "row-1")
        #expect(callback.snapshot().first?.1 == newIngest)
    }

    @Test func bumpHTTPRejectsBadSignature() async throws {
        let fixture = try makeBumpServerFixture(items: [bumpItem(id: "row-1")])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, _) = try await fixture.withServer(server) { base in
            try await postBump(baseURL: base, auth: auth, id: "row-1", tamperSig: true)
        }
        #expect(status == 401)

        // DB 状态没变
        let unchanged = try await db.pool.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT ingested_at_ns FROM item WHERE id='row-1'")
        }
        #expect(unchanged == 100)
    }

    @Test func bumpHTTPReturns404ForUnknownID() async throws {
        let fixture = try makeBumpServerFixture(items: [])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, _) = try await fixture.withServer(server) { base in
            try await postBump(baseURL: base, auth: auth, id: "ghost")
        }
        #expect(status == 404)
    }

    @Test func bumpHTTPReturns410ForTombstone() async throws {
        var dead = bumpItem(id: "dead-1")
        dead.deletedAtNs = 200
        let fixture = try makeBumpServerFixture(items: [dead])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, _) = try await fixture.withServer(server) { base in
            try await postBump(baseURL: base, auth: auth, id: "dead-1")
        }
        #expect(status == 410)
    }
}

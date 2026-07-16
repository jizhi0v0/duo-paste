import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// P0-1 DELETE /item/<id>:iOS 长按"删除"路径。
/// 验证:HMAC 通过 → softDelete 落库 → broadcaster fan-out cursor_advanced。
/// 失败路径:已 tombstoned → 410, unknown id → 404, bad sig → 401。

private func makeDeleteServerFixture(items: [Item]) throws -> TestSyncServerFixture {
    try TestSyncServerFixture(prefix: "duo-del-http", items: items, secretByte: 0xCD)
}

private func delItem(id: String) -> Item {
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

private final class DeleteCallbackBox: @unchecked Sendable {
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

private func deleteItem(baseURL: URL, auth: HMACAuth, id: String, tamperSig: Bool = false)
async throws -> (Int, [String: Any]) {
    let path = "/item/\(id)"
    let url = baseURL.appendingPathComponent(path)
    var req = URLRequest(url: url)
    req.httpMethod = "DELETE"
    req.httpBody = Data()
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let bodyHash = HMACAuth.emptyBodyHashHex
    var sig = auth.sign(timestampMs: ts, method: "DELETE", path: path, bodyHashHex: bodyHash)
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
struct DeleteItemHTTPTests {
    @Test func deleteHTTPSucceedsAndTombstones() async throws {
        let fixture = try makeDeleteServerFixture(items: [delItem(id: "row-1")])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let broadcaster = WSBroadcaster(rotationIntervalSec: 0)
        let callback = DeleteCallbackBox()
        let server = SyncServer(deviceID: "mac-self", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth, broadcaster: broadcaster,
                                onItemMutated: { id, ingestedAtNs in
                                    callback.append(id: id, ingestedAtNs: ingestedAtNs)
                                })
        let (status, body) = try await fixture.withServer(server) { base in
            try await deleteItem(baseURL: base, auth: auth, id: "row-1")
        }
        #expect(status == 200)
        #expect(body["ok"] as? Bool == true)
        let newIngest = (body["ingested_at_ns"] as? Int64) ?? Int64(body["ingested_at_ns"] as? Int ?? 0)
        #expect(newIngest > 100)

        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "row-1").fetchOne(conn)!
        }
        #expect(after.deletedAtNs != nil)
        #expect(after.ingestedAtNs == newIngest)
        #expect(after.capturedAtNs == 100)             // 不动
        #expect(after.originDevice == "mac-self")
        #expect(callback.snapshot().count == 1)
        #expect(callback.snapshot().first?.0 == "row-1")
    }

    @Test func deleteHTTPReturns410ForAlreadyTombstoned() async throws {
        var dead = delItem(id: "dead-1")
        dead.deletedAtNs = 200
        let fixture = try makeDeleteServerFixture(items: [dead])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, _) = try await fixture.withServer(server) { base in
            try await deleteItem(baseURL: base, auth: auth, id: "dead-1")
        }
        #expect(status == 410)
    }

    @Test func deleteHTTPReturns404ForUnknownID() async throws {
        let fixture = try makeDeleteServerFixture(items: [])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, _) = try await fixture.withServer(server) { base in
            try await deleteItem(baseURL: base, auth: auth, id: "ghost")
        }
        #expect(status == 404)
    }

    @Test func deleteHTTPRejectsBadSignature() async throws {
        let fixture = try makeDeleteServerFixture(items: [delItem(id: "row-1")])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)
        let (status, _) = try await fixture.withServer(server) { base in
            try await deleteItem(baseURL: base, auth: auth, id: "row-1", tamperSig: true)
        }
        #expect(status == 401)

        // DB 状态没变
        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "row-1").fetchOne(conn)!
        }
        #expect(after.deletedAtNs == nil)
    }

    // PR review:DELETE handler 必须像 /bump 一样 read body + 校验 sha 跟 header 一致
    // (middleware 不读 body 防 MB 级 payload 占内存,handler 自己负责)。即使签名正确,
    // body sha header 跟实际 body sha 对不上也得 401
    @Test func deleteHTTPRejectsBodySHAMismatch() async throws {
        let fixture = try makeDeleteServerFixture(items: [delItem(id: "row-sha")])
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(deviceID: "p", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth)

        // body 是空(空 hash);header 故意填非空字符串的 hash,签名仍跟 header 一致——
        // middleware 校签通过 → handler 内部 body-sha check 应 reject
        let id = "row-sha"
        let path = "/item/\(id)"
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        // 故意用非空字符串的 hash 作 header,跟实际 body(空) 的 hash 对不上
        let fakeHash = HMACAuth.sha256Hex(Data("fake".utf8))
        let sig = auth.sign(timestampMs: ts, method: "DELETE", path: path, bodyHashHex: fakeHash)
        let (_, resp) = try await fixture.withServer(server) { base in
            var req = URLRequest(url: base.appendingPathComponent(path))
            req.httpMethod = "DELETE"
            req.httpBody = Data()  // empty body
            req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
            req.setValue(fakeHash, forHTTPHeaderField: HMACAuth.bodyHashHeader)
            req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
            return try await URLSession.shared.data(for: req)
        }
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 401, "body sha mismatch 应 reject 即使签名匹配 header")

        // DB 不动
        let after = try await db.pool.read { conn in
            try Item.filter(Column("id") == "row-sha").fetchOne(conn)!
        }
        #expect(after.deletedAtNs == nil)
    }

    // PR review:cascade 删 N 行 fold group 时,onItemMutated 应当合并 fire 一次(target
    // id + max ingested),避免 UI N 次 refresh 风暴。跟 pin/bump 单 fire 心智一致
    @Test func deleteHTTPCallbackCoalescesAcrossCascadeSiblings() async throws {
        let text = "shared-text"
        func textRow(_ id: String, origin: String, captured: Int64) -> Item {
            Item(id: id, originDevice: origin,
                 capturedAtNs: captured, ingestedAtNs: captured,
                 kind: .text, preview: text, textFull: text)
        }
        let items = [
            textRow("target", origin: "mbp", captured: 100),
            textRow("sib-1", origin: "mini", captured: 200),
            textRow("sib-2", origin: "ios", captured: 300),
        ]
        let fixture = try makeDeleteServerFixture(items: items)
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let broadcaster = WSBroadcaster(rotationIntervalSec: 0)
        let callback = DeleteCallbackBox()
        let server = SyncServer(deviceID: "mac-self", database: db, blobs: blobs,
                                host: "127.0.0.1", port: 0, auth: auth, broadcaster: broadcaster,
                                onItemMutated: { id, ingestedAtNs in
                                    callback.append(id: id, ingestedAtNs: ingestedAtNs)
                                })
        let (status, body) = try await fixture.withServer(server) { base in
            try await deleteItem(baseURL: base, auth: auth, id: "target")
        }
        #expect(status == 200)
        #expect(body["deleted_count"] as? Int == 3, "cascade 应删 3 行")

        // DB 状态:三条都 tombstone
        let allDead = try await db.pool.read { conn -> Bool in
            let dead = try Int.fetchOne(conn,
                sql: "SELECT COUNT(*) FROM item WHERE deleted_at_ns IS NOT NULL") ?? 0
            return dead == 3
        }
        #expect(allDead)

        // 关键不变量:回调只 fire 一次(target id),不是 cascade 行数次
        let events = callback.snapshot()
        #expect(events.count == 1, "onItemMutated 应合并一次 fire,实际 \(events.count) 次")
        #expect(events.first?.0 == "target", "fire 的 id 应为 target,实际 \(events.first?.0 ?? "nil")")
        // max ingested 应该是三条里最大那个
        let maxIngest = (body["ingested_at_ns"] as? Int64) ?? Int64(body["ingested_at_ns"] as? Int ?? 0)
        #expect(events.first?.1 == maxIngest)
    }
}

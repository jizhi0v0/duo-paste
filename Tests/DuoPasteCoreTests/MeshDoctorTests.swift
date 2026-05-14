import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

/// `Admin.meshDoctor` 纯函数测试：注入 healthProbe closure + 准备 DB / blob 状态，
/// 断言报告字段。CLI 包装层（runMeshDoctor）只做 argv + 打印，不单独测。

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-mesh-doctor-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeDB(at dir: URL) throws -> URL {
    let dbDir = dir.appendingPathComponent("db")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let p = dbDir.appendingPathComponent("main.sqlite")
    _ = try Database(path: p)
    return p
}

private func makeBlobs(at dir: URL) throws -> BlobStore {
    let root = dir.appendingPathComponent("blobs")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root)
}

@Test func meshDoctorEmptyPeersReturnsEmptyReport() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let r = try await Admin.meshDoctor(
        selfDeviceID: "self",
        peers: [],
        dbPath: dbPath,
        blobs: blobs,
        healthProbe: { _ in
            Issue.record("没 peer 不该调 healthProbe")
            return .unreachable(reason: "should not be called")
        }
    )
    #expect(r.peers.isEmpty)
    #expect(r.missingBlobsTotal == 0)
}

@Test func meshDoctorReportsHealthOK() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let peerURL = URL(string: "https://x.ts.net:8443")!
    let r = try await Admin.meshDoctor(
        selfDeviceID: "self",
        peers: [Config.PeerConfig(url: peerURL, deviceID: "expected-id")],
        dbPath: dbPath,
        blobs: blobs,
        healthProbe: { url in
            #expect(url == peerURL)
            return .ok(deviceID: "expected-id", nowMs: 1_000)
        },
        nowNs: { 1_500_000_000 }   // local now = 1500ms
    )
    #expect(r.peers.count == 1)
    let p = r.peers[0]
    if case .ok(let did, let nowMs, let skewMs) = p.health {
        #expect(did == "expected-id")
        #expect(nowMs == 1_000)
        #expect(skewMs == 1_000 - 1_500)   // peer - local = -500ms
    } else {
        Issue.record("expected .ok health, got \(p.health)")
    }
    #expect(p.deviceIDMatches == true)
}

@Test func meshDoctorReportsHealthUnreachable() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let r = try await Admin.meshDoctor(
        selfDeviceID: "self",
        peers: [Config.PeerConfig(url: URL(string: "https://offline.ts.net:8443")!)],
        dbPath: dbPath,
        blobs: blobs,
        healthProbe: { _ in .unreachable(reason: "connection refused") }
    )
    #expect(r.peers.count == 1)
    if case .unreachable(let reason) = r.peers[0].health {
        #expect(reason == "connection refused")
    } else {
        Issue.record("expected unreachable")
    }
    #expect(r.peers[0].deviceIDMatches == nil)
}

@Test func meshDoctorReportsDeviceIDMismatch() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let r = try await Admin.meshDoctor(
        selfDeviceID: "self",
        peers: [Config.PeerConfig(
            url: URL(string: "https://x.ts.net:8443")!,
            deviceID: "expected-A"
        )],
        dbPath: dbPath,
        blobs: blobs,
        healthProbe: { _ in .ok(deviceID: "actual-B", nowMs: 1_000) }
    )
    #expect(r.peers[0].deviceIDMatches == false, "device_id 跟 expected 不一致应当报 false")
}

@Test func meshDoctorIncludesPullCursorRow() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let db = try Database(path: dbPath)
    // 预置一行 pull_cursor
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO pull_cursor (peer_device_id, cursor_ns, cursor_id, updated_at_ns)
            VALUES ('peer-A', 5000, 'last-id', 9999)
        """)
    }
    let blobs = try makeBlobs(at: dir)
    let r = try await Admin.meshDoctor(
        selfDeviceID: "self",
        peers: [Config.PeerConfig(
            url: URL(string: "https://a.ts.net:8443")!,
            deviceID: "peer-A"
        )],
        dbPath: dbPath,
        blobs: blobs,
        healthProbe: { _ in .ok(deviceID: "peer-A", nowMs: 1_000) }
    )
    #expect(r.peers[0].pullCursor?.peerDeviceID == "peer-A")
    #expect(r.peers[0].pullCursor?.cursorNs == 5000)
    #expect(r.peers[0].pullCursor?.cursorID == "last-id")
}

@Test func meshDoctorLearnModePullCursorByHealthDeviceID() async throws {
    // 学习模式（peer.deviceID == nil）：用 health 报的 device_id 找 cursor 行
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let db = try Database(path: dbPath)
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO pull_cursor (peer_device_id, cursor_ns, cursor_id, updated_at_ns)
            VALUES ('learned-id', 100, '', 100)
        """)
    }
    let blobs = try makeBlobs(at: dir)
    let r = try await Admin.meshDoctor(
        selfDeviceID: "self",
        peers: [Config.PeerConfig(url: URL(string: "https://a.ts.net:8443")!)],
        // deviceID nil
        dbPath: dbPath,
        blobs: blobs,
        healthProbe: { _ in .ok(deviceID: "learned-id", nowMs: 1_000) }
    )
    #expect(r.peers[0].pullCursor?.peerDeviceID == "learned-id")
}

@Test func meshDoctorReportsMissingBlobs() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let db = try Database(path: dbPath)
    // 插一行 image item，blob_sha256 指向不在 BlobStore 里的 sha
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, kind,
                              blob_sha256, pinned)
            VALUES ('img-no-bytes', 'self', 100, 'image',
                    '\(String(repeating: "a", count: 64))', 0)
        """)
    }
    let blobs = try makeBlobs(at: dir)
    let r = try await Admin.meshDoctor(
        selfDeviceID: "self",
        peers: [],
        dbPath: dbPath,
        blobs: blobs,
        healthProbe: { _ in .unreachable(reason: "n/a") }
    )
    #expect(r.missingBlobsTotal == 1)
    #expect(r.missingBlobsSamples.count == 1)
}

@Test func meshDoctorIncludesSelfMaxIngestedNs() async throws {
    let dir = tempDir()
    let dbPath = try makeDB(at: dir)
    let db = try Database(path: dbPath)
    // 插几行 item 测 max(ingested_at_ns)
    try await db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, ingested_at_ns, kind, pinned)
            VALUES
              ('a', 'self', 100, 100, 'text', 0),
              ('b', 'self', 200, 200, 'text', 0),
              ('c', 'self', 300, 9999, 'text', 0)
        """)
    }
    let blobs = try makeBlobs(at: dir)
    let r = try await Admin.meshDoctor(
        selfDeviceID: "self",
        peers: [],
        dbPath: dbPath,
        blobs: blobs,
        healthProbe: { _ in .unreachable(reason: "n/a") }
    )
    #expect(r.selfMaxIngestedNs == 9999)
}

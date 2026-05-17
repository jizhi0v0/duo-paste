import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// /endpoints 路由的端到端 HTTP 测试:
/// - 不带 meshEndpointsProvider 时,meshPeers 字段缺失(老 daemon 兼容)
/// - 带 provider 时返聚合 list
/// - device_id 字段返本机
/// - 老 client 不解 meshPeers 也能 decode(向前兼容)

private typealias DuoDB = DuoPasteCore.Database

private func makeFixture() throws -> (DuoDB, BlobStore, HMACAuth, Int) {
    let secret = Data(repeating: 0xEE, count: 32)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-endpoints-route-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try DuoDB(path: paths.mainDB)
    let blobs = BlobStore(root: paths.blobsDir)
    try FileManager.default.createDirectory(at: blobs.root, withIntermediateDirectories: true)
    let auth = HMACAuth(secret: secret)
    let port = Int.random(in: 19500..<19800)
    return (db, blobs, auth, port)
}

private func waitReady(baseURL: URL, auth: HMACAuth) async -> Bool {
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

private func getEndpoints(baseURL: URL, auth: HMACAuth) async throws -> (Int, Data) {
    var req = URLRequest(url: baseURL.appendingPathComponent("endpoints"))
    req.httpMethod = "GET"
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let sig = auth.sign(timestampMs: ts, method: "GET", path: "/endpoints",
                        bodyHashHex: HMACAuth.emptyBodyHashHex)
    req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
    req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
    req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
    let (data, resp) = try await URLSession.shared.data(for: req)
    return ((resp as! HTTPURLResponse).statusCode, data)
}

@Suite(.serialized)
struct EndpointsRouteAggregationTests {
    @Test func endpointsReturnsSelfDeviceIDAndNoMeshByDefault() async throws {
        let (db, blobs, auth, port) = try makeFixture()
        let server = SyncServer(
            deviceID: "self-mac",
            database: db, blobs: blobs,
            host: "127.0.0.1", port: port,
            auth: auth,
            endpointsProvider: {
                [PeerEndpoint(url: "https://self.example:8443", kind: .tailscale, preferred: true)]
            }
        )
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReady(baseURL: base, auth: auth))

        let (status, data) = try await getEndpoints(baseURL: base, auth: auth)
        #expect(status == 200)
        let page = try JSONDecoder().decode(PeerEndpointsPage.self, from: data)
        #expect(page.deviceID == "self-mac")
        #expect(page.endpoints.count == 1)
        #expect(page.meshPeers == nil)
    }

    @Test func endpointsAggregatesMeshPeersWhenProviderReturnsList() async throws {
        let (db, blobs, auth, port) = try makeFixture()
        let meshList = [
            MeshPeerEntry(
                peerDeviceID: "peer-Z",
                endpoints: [PeerEndpoint(url: "https://z.example:8443", kind: .tailscale)],
                learnedAtUnix: 100,
                healthy: true
            )
        ]
        let server = SyncServer(
            deviceID: "self-mac",
            database: db, blobs: blobs,
            host: "127.0.0.1", port: port,
            auth: auth,
            endpointsProvider: {
                [PeerEndpoint(url: "https://self.example:8443", kind: .tailscale, preferred: true)]
            },
            meshEndpointsProvider: { meshList }
        )
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReady(baseURL: base, auth: auth))

        let (status, data) = try await getEndpoints(baseURL: base, auth: auth)
        #expect(status == 200)
        let page = try JSONDecoder().decode(PeerEndpointsPage.self, from: data)
        #expect(page.deviceID == "self-mac")
        #expect(page.endpoints.count == 1)
        #expect(page.meshPeers?.count == 1)
        #expect(page.meshPeers?[0].peerDeviceID == "peer-Z")
        #expect(page.meshPeers?[0].healthy == true)
    }

    @Test func endpointsWireForwardCompatibleWithMissingMeshPeers() async throws {
        // Decode JSON 不含 mesh_peers 字段(模拟老 daemon)→ PeerEndpointsPage 能成功 decode
        // 且 meshPeers = nil。这是给 iOS 老客户端 / Mac 老 daemon 互操作性
        let json = """
        {
          "device_id": "old-mac",
          "endpoints": [
            {"url": "https://old.example:8443", "kind": "tailscale", "preferred": true}
          ],
          "updated_at_unix": 12345
        }
        """
        let data = Data(json.utf8)
        let page = try JSONDecoder().decode(PeerEndpointsPage.self, from: data)
        #expect(page.deviceID == "old-mac")
        #expect(page.endpoints.count == 1)
        #expect(page.meshPeers == nil)
    }
}

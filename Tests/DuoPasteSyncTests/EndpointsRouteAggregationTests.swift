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

private func makeFixture() throws -> TestSyncServerFixture {
    try TestSyncServerFixture(prefix: "duo-endpoints-route", secretByte: 0xEE)
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
        let fixture = try makeFixture()
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
        let server = SyncServer(
            deviceID: "self-mac",
            database: db, blobs: blobs,
            host: "127.0.0.1", port: 0,
            auth: auth,
            endpointsProvider: {
                [PeerEndpoint(url: "https://self.example:8443", kind: .tailscale, preferred: true)]
            }
        )
        let (status, data) = try await fixture.withServer(server) { base in
            try await getEndpoints(baseURL: base, auth: auth)
        }
        #expect(status == 200)
        let page = try JSONDecoder().decode(PeerEndpointsPage.self, from: data)
        #expect(page.deviceID == "self-mac")
        #expect(page.endpoints.count == 1)
        #expect(page.meshPeers == nil)
    }

    @Test func endpointsAggregatesMeshPeersWhenProviderReturnsList() async throws {
        let fixture = try makeFixture()
        let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
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
            host: "127.0.0.1", port: 0,
            auth: auth,
            endpointsProvider: {
                [PeerEndpoint(url: "https://self.example:8443", kind: .tailscale, preferred: true)]
            },
            meshEndpointsProvider: { meshList }
        )
        let (status, data) = try await fixture.withServer(server) { base in
            try await getEndpoints(baseURL: base, auth: auth)
        }
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

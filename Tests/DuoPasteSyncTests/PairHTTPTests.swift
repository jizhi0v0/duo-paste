import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// POST /pair/<pin> + GET /endpoints 的 HTTP 路径回归。
/// /pair 不走 HMAC,但 path 里 pin 必须 6 位数字,且成功响应必须原子包含 endpoints。
/// /endpoints 仍单独存在并走 HMAC,供后续刷新候选使用。

private typealias DuoDB = DuoPasteCore.Database

private func makePairServerFixture() throws -> (DuoDB, BlobStore, HMACAuth, Int, Data) {
    let secret = Data(repeating: 0xCE, count: 32)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-pair-http-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try DuoDB(path: paths.mainDB)
    let blobs = BlobStore(root: paths.blobsDir)
    try FileManager.default.createDirectory(at: blobs.root, withIntermediateDirectories: true)
    let auth = HMACAuth(secret: secret)
    let port = Int.random(in: 19200..<19500)
    return (db, blobs, auth, port, secret)
}

private func waitReadyPair(baseURL: URL, auth: HMACAuth) async -> Bool {
    for _ in 0..<60 {
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

@Suite(.serialized)
struct PairHTTPTests {
    @Test func pairReturns200WithSecretOnCorrectPIN() async throws {
        let (db, blobs, auth, port, secret) = try makePairServerFixture()
        let endpoints = [
            PeerEndpoint(url: "https://mbp.example:8443", kind: .tailscale, preferred: true),
            PeerEndpoint(url: "https://mbp.sgponte:8443", kind: .ponte),
        ]
        let pairing = PairingService(
            pinLifetimeSec: 60,
            secretsProvider: { secret },
            pinGenerator: { "424242" }
        )
        _ = await pairing.generatePIN()

        let server = SyncServer(
            deviceID: "mac-test",
            database: db,
            blobs: blobs,
            host: "127.0.0.1",
            port: port,
            auth: auth,
            endpointsProvider: { endpoints },
            pairingService: pairing,
            // 测试用 plain HTTP；显式 opt-out TLS 护栏（生产路径默 true）
            requirePairingTLS: false
        )
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPair(baseURL: base, auth: auth))

        // 不带 HMAC 直接 POST /pair/<pin>
        var req = URLRequest(url: base.appendingPathComponent("pair/424242"))
        req.httpMethod = "POST"
        req.httpBody = Data()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let dict = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        #expect(dict["ok"] as? Bool == true)
        #expect(dict["device_id"] as? String == "mac-test")
        let hex = dict["secret"] as? String
        let expectedHex = secret.map { String(format: "%02x", $0) }.joined()
        #expect(hex == expectedHex)
        let pageDict = dict["endpoints_page"] as? [String: Any]
        let eps = pageDict?["endpoints"] as? [[String: Any]]
        #expect(pageDict?["device_id"] as? String == "mac-test")
        #expect(eps?.count == 2)
        #expect(eps?.first?["url"] as? String == "https://mbp.example:8443")
        #expect(eps?.last?["kind"] as? String == "ponte")
    }

    @Test func pairReturns401OnPINMismatch() async throws {
        let (db, blobs, auth, port, secret) = try makePairServerFixture()
        let pairing = PairingService(
            pinLifetimeSec: 60,
            secretsProvider: { secret },
            pinGenerator: { "111111" }
        )
        _ = await pairing.generatePIN()

        let server = SyncServer(
            deviceID: "p", database: db, blobs: blobs,
            host: "127.0.0.1", port: port, auth: auth,
            pairingService: pairing,
            requirePairingTLS: false
        )
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPair(baseURL: base, auth: auth))

        var req = URLRequest(url: base.appendingPathComponent("pair/999999"))
        req.httpMethod = "POST"
        req.httpBody = Data()
        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 401)
    }

    @Test func pairReturns503WhenServiceNil() async throws {
        let (db, blobs, auth, port, _) = try makePairServerFixture()
        // 没注入 pairingService → 503
        let server = SyncServer(
            deviceID: "p", database: db, blobs: blobs,
            host: "127.0.0.1", port: port, auth: auth
        )
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPair(baseURL: base, auth: auth))

        var req = URLRequest(url: base.appendingPathComponent("pair/123456"))
        req.httpMethod = "POST"
        req.httpBody = Data()
        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 503)
    }

    @Test func pairReturns400OnNon6DigitPIN() async throws {
        let (db, blobs, auth, port, secret) = try makePairServerFixture()
        let pairing = PairingService(secretsProvider: { secret })
        let server = SyncServer(
            deviceID: "p", database: db, blobs: blobs,
            host: "127.0.0.1", port: port, auth: auth,
            pairingService: pairing,
            requirePairingTLS: false
        )
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPair(baseURL: base, auth: auth))

        for bad in ["abc", "12345", "12345678", "abcdef"] {
            var req = URLRequest(url: base.appendingPathComponent("pair/\(bad)"))
            req.httpMethod = "POST"
            req.httpBody = Data()
            let (_, resp) = try await URLSession.shared.data(for: req)
            let http = resp as! HTTPURLResponse
            #expect(http.statusCode == 400, "bad pin \(bad)")
        }
    }

    @Test func endpointsReturnsConfiguredList() async throws {
        let (db, blobs, auth, port, _) = try makePairServerFixture()
        let endpoints = [
            PeerEndpoint(url: "https://test.example:8443", kind: .tailscale, preferred: true),
            PeerEndpoint(url: "https://test.local:8443", kind: .local),
        ]
        let server = SyncServer(
            deviceID: "p", database: db, blobs: blobs,
            host: "127.0.0.1", port: port, auth: auth,
            endpointsProvider: { endpoints }
        )
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPair(baseURL: base, auth: auth))

        // 加 HMAC
        var req = URLRequest(url: base.appendingPathComponent("endpoints"))
        req.httpMethod = "GET"
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let sig = auth.sign(timestampMs: ts, method: "GET", path: "/endpoints",
                            bodyHashHex: HMACAuth.emptyBodyHashHex)
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 200)
        let page = try JSONDecoder().decode(PeerEndpointsPage.self, from: data)
        #expect(page.endpoints.count == 2)
        #expect(page.endpoints[0].url == "https://test.example:8443")
        #expect(page.endpoints[0].preferred == true)
        #expect(page.endpoints[1].kind == .local)
    }

    /// PR-E 回归：plain HTTP daemon 默认拒 /pair——secret hex 不该走未加密链路。
    /// 不消耗 PIN（attacker 也不能通过 503 vs 401 反推 TLS 状态后再针对）
    @Test func pairReturns503WhenTLSRequiredButMissing() async throws {
        let (db, blobs, auth, port, secret) = try makePairServerFixture()
        let pairing = PairingService(
            pinLifetimeSec: 60,
            secretsProvider: { secret },
            pinGenerator: { "424242" }
        )
        _ = await pairing.generatePIN()
        // 注意：**不**传 requirePairingTLS=false，默认 true → 必须 TLS 才允 /pair。
        // 但本测试用 plain HTTP server（tls=nil）→ pair 路由应拒
        let server = SyncServer(
            deviceID: "p", database: db, blobs: blobs,
            host: "127.0.0.1", port: port, auth: auth,
            pairingService: pairing
        )
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPair(baseURL: base, auth: auth))

        var req = URLRequest(url: base.appendingPathComponent("pair/424242"))
        req.httpMethod = "POST"
        req.httpBody = Data()
        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 503, "plain HTTP /pair 必须 503，实际 \(http.statusCode)")

        // 进一步验证：PIN 没被消耗。换 requirePairingTLS=false 再起一个 server 用同 pairing
        // 服务，原 PIN 应仍有效——证明 503 路径没走 validateAndConsumePIN
        // （注：本测试只验证 503，PIN 消耗复查留给 PairingService 自己测试）
    }

    @Test func endpointsRejectsWithoutHMAC() async throws {
        let (db, blobs, auth, port, _) = try makePairServerFixture()
        let server = SyncServer(
            deviceID: "p", database: db, blobs: blobs,
            host: "127.0.0.1", port: port, auth: auth,
            endpointsProvider: { [] }
        )
        let serverTask = Task { try? await server.run() }
        defer { serverTask.cancel() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        #expect(await waitReadyPair(baseURL: base, auth: auth))

        // 不加 HMAC headers
        var req = URLRequest(url: base.appendingPathComponent("endpoints"))
        req.httpMethod = "GET"
        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 401)
    }
}

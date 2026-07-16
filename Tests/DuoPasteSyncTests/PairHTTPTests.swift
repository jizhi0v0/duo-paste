import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// POST /pair/<pin> + GET /endpoints 的 HTTP 路径回归。
/// /pair 不走 HMAC,但 path 里 pin 必须 6 位数字,且成功响应必须原子包含 endpoints。
/// /endpoints 仍单独存在并走 HMAC,供后续刷新候选使用。

private func makePairServerFixture() throws -> (TestSyncServerFixture, Data) {
    let secret = Data(repeating: 0xCE, count: 32)
    let fixture = try TestSyncServerFixture(prefix: "duo-pair-http", secretByte: 0xCE)
    return (fixture, secret)
}

private func withPairServer<Value>(
    fixture: TestSyncServerFixture,
    deviceID: String = "p",
    endpoints: [PeerEndpoint] = [],
    pairingService: PairingService? = nil,
    credentialAuthenticator: DeviceCredentialAuthenticator? = nil,
    requirePairingTLS: Bool = true,
    operation: (URL) async throws -> Value
) async throws -> Value {
    let server = SyncServer(
        deviceID: deviceID,
        database: fixture.database,
        blobs: fixture.blobs,
        host: "127.0.0.1",
        port: 0,
        auth: fixture.auth,
        credentialAuthenticator: credentialAuthenticator,
        endpointsProvider: { endpoints },
        pairingService: pairingService,
        requirePairingTLS: requirePairingTLS
    )
    return try await fixture.withServer(server, operation: operation)
}

@Suite(.serialized)
struct PairHTTPTests {
    @Test func newPairingReturnsIndependentCredentialWithoutRootSecret() async throws {
        let (fixture, rootSecret) = try makePairServerFixture()
        let pairing = PairingService(
            secretsProvider: { rootSecret },
            pinGenerator: { "515151" }
        )
        _ = await pairing.generatePIN()
        let authenticator = DeviceCredentialAuthenticator(
            database: fixture.database,
            rootSecret: rootSecret
        )

        let (data, response) = try await withPairServer(
            fixture: fixture,
            deviceID: "mac-new",
            pairingService: pairing,
            credentialAuthenticator: authenticator,
            requirePairingTLS: false
        ) { base in
            var request = URLRequest(url: base.appendingPathComponent("pair/515151"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_device_id": "ios-a",
                "client_name": "iPhone A",
                "platform": "ios",
            ])
            return try await URLSession.shared.data(for: request)
        }

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["secret"] == nil, "new pairing must never return mesh root secret")
        let credential = try #require(json["credential"] as? [String: Any])
        let secretHex = try #require(credential["secret"] as? String)
        let token = try #require(credential["token"] as? String)
        #expect(secretHex.count == 64)
        #expect(token.hasPrefix("dpc1."))
        #expect(secretHex != rootSecret.map { String(format: "%02x", $0) }.joined())
        #expect((credential["id"] as? String)?.isEmpty == false)
    }

    @Test func pairReturns200WithSecretOnCorrectPIN() async throws {
        let (fixture, secret) = try makePairServerFixture()
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
        let authenticator = DeviceCredentialAuthenticator(
            database: fixture.database,
            rootSecret: secret
        )

        let (data, resp) = try await withPairServer(
            fixture: fixture,
            deviceID: "mac-test",
            endpoints: endpoints,
            pairingService: pairing,
            credentialAuthenticator: authenticator,
            // 测试用 plain HTTP；显式 opt-out TLS 护栏（生产路径默 true）
            requirePairingTLS: false
        ) { base in
            // 不带 HMAC 直接 POST /pair/<pin>
            var req = URLRequest(url: base.appendingPathComponent("pair/424242"))
            req.httpMethod = "POST"
            req.httpBody = Data()
            return try await URLSession.shared.data(for: req)
        }
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
        let (fixture, secret) = try makePairServerFixture()
        let pairing = PairingService(
            pinLifetimeSec: 60,
            secretsProvider: { secret },
            pinGenerator: { "111111" }
        )
        _ = await pairing.generatePIN()

        let (_, resp) = try await withPairServer(
            fixture: fixture,
            pairingService: pairing,
            requirePairingTLS: false
        ) { base in
            var req = URLRequest(url: base.appendingPathComponent("pair/999999"))
            req.httpMethod = "POST"
            req.httpBody = Data()
            return try await URLSession.shared.data(for: req)
        }
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 401)
    }

    @Test func pairReturns503WhenServiceNil() async throws {
        let (fixture, _) = try makePairServerFixture()
        // 没注入 pairingService → 503
        let (_, resp) = try await withPairServer(fixture: fixture) { base in
            var req = URLRequest(url: base.appendingPathComponent("pair/123456"))
            req.httpMethod = "POST"
            req.httpBody = Data()
            return try await URLSession.shared.data(for: req)
        }
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 503)
    }

    @Test func pairReturns400OnNon6DigitPIN() async throws {
        let (fixture, secret) = try makePairServerFixture()
        let pairing = PairingService(secretsProvider: { secret })
        try await withPairServer(
            fixture: fixture,
            pairingService: pairing,
            requirePairingTLS: false
        ) { base in
            for bad in ["abc", "12345", "12345678", "abcdef"] {
                var req = URLRequest(url: base.appendingPathComponent("pair/\(bad)"))
                req.httpMethod = "POST"
                req.httpBody = Data()
                let (_, resp) = try await URLSession.shared.data(for: req)
                let http = resp as! HTTPURLResponse
                #expect(http.statusCode == 400, "bad pin \(bad)")
            }
        }
    }

    @Test func endpointsReturnsConfiguredList() async throws {
        let (fixture, _) = try makePairServerFixture()
        let endpoints = [
            PeerEndpoint(url: "https://test.example:8443", kind: .tailscale, preferred: true),
            PeerEndpoint(url: "https://test.local:8443", kind: .local),
        ]
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let sig = fixture.auth.sign(timestampMs: ts, method: "GET", path: "/endpoints",
                            bodyHashHex: HMACAuth.emptyBodyHashHex)
        let (data, resp) = try await withPairServer(
            fixture: fixture,
            endpoints: endpoints
        ) { base in
            // 加 HMAC
            var req = URLRequest(url: base.appendingPathComponent("endpoints"))
            req.httpMethod = "GET"
            req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
            req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
            req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
            return try await URLSession.shared.data(for: req)
        }
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
        let (fixture, secret) = try makePairServerFixture()
        let pairing = PairingService(
            pinLifetimeSec: 60,
            secretsProvider: { secret },
            pinGenerator: { "424242" }
        )
        _ = await pairing.generatePIN()
        // 注意：**不**传 requirePairingTLS=false，默认 true → 必须 TLS 才允 /pair。
        // 但本测试用 plain HTTP server（tls=nil）→ pair 路由应拒
        let (_, resp) = try await withPairServer(
            fixture: fixture,
            pairingService: pairing
        ) { base in
            var req = URLRequest(url: base.appendingPathComponent("pair/424242"))
            req.httpMethod = "POST"
            req.httpBody = Data()
            return try await URLSession.shared.data(for: req)
        }
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 503, "plain HTTP /pair 必须 503，实际 \(http.statusCode)")

        // 进一步验证：PIN 没被消耗。换 requirePairingTLS=false 再起一个 server 用同 pairing
        // 服务，原 PIN 应仍有效——证明 503 路径没走 validateAndConsumePIN
        // （注：本测试只验证 503，PIN 消耗复查留给 PairingService 自己测试）
    }

    @Test func endpointsRejectsWithoutHMAC() async throws {
        let (fixture, _) = try makePairServerFixture()
        let (_, resp) = try await withPairServer(fixture: fixture) { base in
            // 不加 HMAC headers
            var req = URLRequest(url: base.appendingPathComponent("endpoints"))
            req.httpMethod = "GET"
            return try await URLSession.shared.data(for: req)
        }
        let http = resp as! HTTPURLResponse
        #expect(http.statusCode == 401)
    }
}

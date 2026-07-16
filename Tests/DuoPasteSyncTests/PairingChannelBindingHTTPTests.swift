import Foundation
import Testing
import DuoPasteCore
@testable import DuoPasteSync

private let genuinePairingCertificate = """
-----BEGIN CERTIFICATE-----
MIIBnDCCAUOgAwIBAgIUbVxNARHNGcpQpkxOYo9/rf6PR/owCgYIKoZIzj0EAwIw
FjEUMBIGA1UEAwwLZHVvLWdlbnVpbmUwHhcNMjYwNzE2MDkyMDEwWhcNMzYwNzEz
MDkyMDEwWjAWMRQwEgYDVQQDDAtkdW8tZ2VudWluZTBZMBMGByqGSM49AgEGCCqG
SM49AwEHA0IABH7Y3dd9i7cExjjGTEJUch3+on8YbdVsOAxMTw8tw2nOpqvXew78
sxSfWu007on6VVYIuHv71FeEe0zILe1xHWijbzBtMB0GA1UdDgQWBBRu1b7rVc/d
p6ez+mZjtNMun6HyijAfBgNVHSMEGDAWgBRu1b7rVc/dp6ez+mZjtNMun6HyijAP
BgNVHRMBAf8EBTADAQH/MBoGA1UdEQQTMBGCCWxvY2FsaG9zdIcEfwAAATAKBggq
hkjOPQQDAgNHADBEAiAYwq2QH/n5yyCtxEhXbsQk7zfBKlYHTYKDJbpo/0/nYgIg
GskJgD3+eRqQrEsSwXos1P1s82SC5NO5chHyfk5uXNY=
-----END CERTIFICATE-----
"""

private let genuinePairingPrivateKey = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg86pbq0mqdEPR7WYt
RIFn7NO+MaFj1x4e5TKArbv0V/GhRANCAAR+2N3XfYu3BMY4xkxCVHId/qJ/GG3V
bDgMTE8PLcNpzqar13sO/LMUn1rtNO6J+lVWCLh7+9RXhHtMyC3tcR1o
-----END PRIVATE KEY-----
"""

private let attackerPairingCertificate = """
-----BEGIN CERTIFICATE-----
MIIBnjCCAUWgAwIBAgIUS0EN+lYPcrKdAQQ6RNuShM9gmL8wCgYIKoZIzj0EAwIw
FzEVMBMGA1UEAwwMZHVvLWF0dGFja2VyMB4XDTI2MDcxNjA5MjAxMFoXDTM2MDcx
MzA5MjAxMFowFzEVMBMGA1UEAwwMZHVvLWF0dGFja2VyMFkwEwYHKoZIzj0CAQYI
KoZIzj0DAQcDQgAEDX58+B8rgsnjYr4htNmzKbs46y6ttB4/f60C8zr1lfO9hzkr
5OSoU18eQ4NZL6nvmpPOJyieFAgbBi/uIHxkpKNvMG0wHQYDVR0OBBYEFMwbpVnz
a8oWTulclFrSexFy8nkWMB8GA1UdIwQYMBaAFMwbpVnza8oWTulclFrSexFy8nkW
MA8GA1UdEwEB/wQFMAMBAf8wGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAoG
CCqGSM49BAMCA0cAMEQCIFUj/2p2NBwOUfdkO6q2hhfNhhuXAkTUeuvxoFlDT4O5
AiA4gHSzl2vbfKpGWX+M//ihzjWAOCvxvLK/UmPBbVSgjg==
-----END CERTIFICATE-----
"""

private let attackerPairingPrivateKey = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgwhlzjjCXrNUb4MbB
tFQ+DllnkYnXektM2noWSsDlOSKhRANCAAQNfnz4HyuCyeNiviG02bMpuzjrLq20
Hj9/rQLzOvWV872HOSvk5KhTXx5Dg1kvqe+ak84nKJ4UCBsGL+4gfGSk
-----END PRIVATE KEY-----
"""

private func writePairingTLSFiles(
    root: URL,
    name: String,
    certificate: String,
    privateKey: String
) throws -> SyncServer.TLSPaths {
    let certURL = root.appendingPathComponent("\(name).crt")
    let keyURL = root.appendingPathComponent("\(name).key")
    try Data(certificate.utf8).write(to: certURL, options: .atomic)
    try Data(privateKey.utf8).write(to: keyURL, options: .atomic)
    return SyncServer.TLSPaths(certPath: certURL.path, keyPath: keyURL.path)
}

private func makePairingRequest(baseURL: URL, pin: String) throws -> URLRequest {
    var request = URLRequest(url: baseURL.appendingPathComponent("pair/\(pin)"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "client_device_id": "ios-channel-binding-test",
        "client_name": "Relay Test iPhone",
        "platform": "ios",
    ])
    return request
}

@Suite(.serialized)
struct PairingChannelBindingHTTPTests {
    @Test func attackerTLSRelayCannotConsumePINOrReceiveCredential() async throws {
        let fixture = try TestSyncServerFixture(prefix: "duo-pair-channel-binding")
        let rootSecret = Data(repeating: 0xD4, count: 32)
        let pairing = PairingService(
            secretsProvider: { rootSecret },
            pinGenerator: { "424242" }
        )
        _ = await pairing.generatePIN()
        let authenticator = DeviceCredentialAuthenticator(
            database: fixture.database,
            rootSecret: rootSecret
        )
        let genuineTLS = try writePairingTLSFiles(
            root: fixture.root,
            name: "genuine",
            certificate: genuinePairingCertificate,
            privateKey: genuinePairingPrivateKey
        )
        let attackerTLS = try writePairingTLSFiles(
            root: fixture.root,
            name: "attacker",
            certificate: attackerPairingCertificate,
            privateKey: attackerPairingPrivateKey
        )
        let genuineDER = try PairingCertificatePin.certificateDER(
            from: Data(genuinePairingCertificate.utf8)
        )
        let genuinePin = PairingCertificatePin.sha256Hex(certificateDER: genuineDER)

        let attackerServer = SyncServer(
            deviceID: "mac-genuine",
            database: fixture.database,
            blobs: fixture.blobs,
            host: "127.0.0.1",
            port: 0,
            auth: fixture.auth,
            credentialAuthenticator: authenticator,
            tls: attackerTLS,
            pairingService: pairing
        )
        let attackerDelegate = try #require(PinnedCertificateDelegate(expectedSHA256: genuinePin))
        let attackerSession = URLSession(
            configuration: .ephemeral,
            delegate: attackerDelegate,
            delegateQueue: nil
        )
        defer { attackerSession.invalidateAndCancel() }

        do {
            _ = try await fixture.withServer(attackerServer) { baseURL in
                let request = try makePairingRequest(baseURL: baseURL, pin: "424242")
                return try await attackerSession.data(for: request, delegate: attackerDelegate)
            }
            Issue.record("attacker leaf unexpectedly passed the genuine QR pin")
        } catch {
            #expect(attackerDelegate.rejectedCertificate)
        }
        #expect(await pairing.currentStatus()?.pin == "424242",
                "TLS rejection must happen before the PIN request reaches the relay")

        let genuineServer = SyncServer(
            deviceID: "mac-genuine",
            database: fixture.database,
            blobs: fixture.blobs,
            host: "127.0.0.1",
            port: 0,
            auth: fixture.auth,
            credentialAuthenticator: authenticator,
            tls: genuineTLS,
            pairingService: pairing
        )
        let genuineDelegate = try #require(PinnedCertificateDelegate(expectedSHA256: genuinePin))
        let genuineSession = URLSession(
            configuration: .ephemeral,
            delegate: genuineDelegate,
            delegateQueue: nil
        )
        defer { genuineSession.invalidateAndCancel() }
        let (data, response) = try await fixture.withServer(genuineServer) { baseURL in
            let request = try makePairingRequest(baseURL: baseURL, pin: "424242")
            return try await genuineSession.data(for: request, delegate: genuineDelegate)
        }
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let credential = try #require(json["credential"] as? [String: Any])
        #expect((credential["token"] as? String)?.hasPrefix("dpc1.") == true)
        #expect(await pairing.currentStatus() == nil)
    }
}

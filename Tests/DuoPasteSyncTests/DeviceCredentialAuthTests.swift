import Foundation
import Testing
import DuoPasteCore
@testable import DuoPasteSync

private func signedHealthRequest(
    base: URL,
    secret: Data,
    token: String? = nil
) -> URLRequest {
    let auth = HMACAuth(secret: secret)
    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    let hash = HMACAuth.emptyBodyHashHex
    let signature = auth.sign(
        timestampMs: timestamp,
        method: "GET",
        path: "/health",
        bodyHashHex: hash
    )
    var request = URLRequest(url: base.appendingPathComponent("health"))
    request.httpMethod = "GET"
    request.setValue(String(timestamp), forHTTPHeaderField: HMACAuth.timestampHeader)
    request.setValue(hash, forHTTPHeaderField: HMACAuth.bodyHashHeader)
    request.setValue(signature, forHTTPHeaderField: HMACAuth.signatureHeader)
    if let token {
        request.setValue(token, forHTTPHeaderField: HMACAuth.credentialTokenHeader)
    }
    return request
}

private actor CredentialWSState {
    private var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
    func wasConnected() -> Bool { values.contains(true) }
    func isConnected() -> Bool { values.last == true }
}

private func credentialWSHeaders(_ grant: IssuedDeviceCredential) -> [(name: String, value: String)] {
    let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
    let hash = HMACAuth.emptyBodyHashHex
    let signature = HMACAuth(secret: grant.requestSecret).sign(
        timestampMs: timestamp,
        method: "GET",
        path: "/sync/ws",
        bodyHashHex: hash
    )
    return [
        (HMACAuth.timestampHeader, String(timestamp)),
        (HMACAuth.bodyHashHeader, hash),
        (HMACAuth.signatureHeader, signature),
        (HMACAuth.credentialTokenHeader, grant.token),
    ]
}

private func waitForCredentialWS(
    timeoutMs: Int = 2_000,
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
    while Date() < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@Suite(.serialized)
struct DeviceCredentialAuthTests {
    @Test func revokedCredentialCannotReconnectWebSocketWhileOtherDeviceCan() async throws {
        let fixture = try TestSyncServerFixture(prefix: "duo-device-ws", secretByte: 0xD3)
        let rootSecret = Data(repeating: 0xD3, count: 32)
        let authenticator = DeviceCredentialAuthenticator(
            database: fixture.database,
            rootSecret: rootSecret
        )
        let a = try await authenticator.issue(
            client: .init(deviceID: "ios-a", displayName: "iPhone A", platform: "ios"),
            issuerDeviceID: "mac"
        )
        let b = try await authenticator.issue(
            client: .init(deviceID: "ios-b", displayName: "iPhone B", platform: "ios"),
            issuerDeviceID: "mac"
        )
        let broadcaster = WSBroadcaster(rotationIntervalSec: 0, log: { _ in })
        let server = SyncServer(
            deviceID: "mac",
            database: fixture.database,
            blobs: fixture.blobs,
            host: "127.0.0.1",
            port: 0,
            auth: fixture.auth,
            credentialAuthenticator: authenticator,
            broadcaster: broadcaster
        )

        try await fixture.withServer(server) { base in
            let wsURL = "ws://127.0.0.1:\(base.port!)/sync/ws"
            let initialA = CredentialWSState()
            let initialTask = Task {
                try? await NIOWebSocketTransport().runOnce(
                    wsURL: wsURL,
                    headers: credentialWSHeaders(a),
                    maxInboundMessageBytes: 64 * 1024,
                    heartbeatSec: 30,
                    onConnected: { value in Task { await initialA.record(value) } },
                    onText: { _ in }
                )
            }
            await waitForCredentialWS {
                let connected = await initialA.isConnected()
                let count = await broadcaster.connectionCount
                return connected && count == 1
            }
            #expect(await initialA.wasConnected())

            _ = try await authenticator.revoke(
                credentialID: a.credentialID,
                revokedByDeviceID: "mac"
            )
            await broadcaster.rotateAllConnections()
            await waitForCredentialWS { await broadcaster.connectionCount == 0 }
            initialTask.cancel()

            let rejectedA = CredentialWSState()
            let rejectedTask = Task {
                try? await NIOWebSocketTransport().runOnce(
                    wsURL: wsURL,
                    headers: credentialWSHeaders(a),
                    maxInboundMessageBytes: 64 * 1024,
                    heartbeatSec: 30,
                    onConnected: { value in Task { await rejectedA.record(value) } },
                    onText: { _ in }
                )
            }
            try? await Task.sleep(for: .milliseconds(250))
            #expect(!(await rejectedA.wasConnected()))
            let rejectedCount = await broadcaster.connectionCount
            #expect(rejectedCount == 0)
            rejectedTask.cancel()

            let allowedB = CredentialWSState()
            let allowedTask = Task {
                try? await NIOWebSocketTransport().runOnce(
                    wsURL: wsURL,
                    headers: credentialWSHeaders(b),
                    maxInboundMessageBytes: 64 * 1024,
                    heartbeatSec: 30,
                    onConnected: { value in Task { await allowedB.record(value) } },
                    onText: { _ in }
                )
            }
            await waitForCredentialWS {
                let connected = await allowedB.isConnected()
                let count = await broadcaster.connectionCount
                return connected && count == 1
            }
            #expect(await allowedB.wasConnected())
            allowedTask.cancel()
            await broadcaster.rotateAllConnections()
        }
    }

    @Test func revokingDeviceARejectsOnlyAWhileBAndLegacyRemainValid() async throws {
        let fixture = try TestSyncServerFixture(prefix: "duo-device-auth", secretByte: 0xD1)
        let rootSecret = Data(repeating: 0xD1, count: 32)
        let authenticator = DeviceCredentialAuthenticator(
            database: fixture.database,
            rootSecret: rootSecret
        )
        let a = try await authenticator.issue(
            client: .init(deviceID: "ios-a", displayName: "iPhone A", platform: "ios"),
            issuerDeviceID: "mac"
        )
        let b = try await authenticator.issue(
            client: .init(deviceID: "ios-b", displayName: "iPhone B", platform: "ios"),
            issuerDeviceID: "mac"
        )
        let server = SyncServer(
            deviceID: "mac",
            database: fixture.database,
            blobs: fixture.blobs,
            host: "127.0.0.1",
            port: 0,
            auth: fixture.auth,
            credentialAuthenticator: authenticator
        )

        try await fixture.withServer(server) { base in
            for grant in [a, b] {
                let (_, response) = try await URLSession.shared.data(
                    for: signedHealthRequest(
                        base: base,
                        secret: grant.requestSecret,
                        token: grant.token
                    )
                )
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
            }
            let (_, legacyResponse) = try await URLSession.shared.data(
                for: signedHealthRequest(base: base, secret: rootSecret)
            )
            #expect((legacyResponse as? HTTPURLResponse)?.statusCode == 200)
            let (_, downgradeAttempt) = try await URLSession.shared.data(
                for: signedHealthRequest(
                    base: base,
                    secret: rootSecret,
                    token: "dpc1.invalid-token"
                )
            )
            #expect((downgradeAttempt as? HTTPURLResponse)?.statusCode == 401)

            _ = try await authenticator.revoke(
                credentialID: a.credentialID,
                revokedByDeviceID: "mac"
            )

            let (_, rejected) = try await URLSession.shared.data(
                for: signedHealthRequest(base: base, secret: a.requestSecret, token: a.token)
            )
            #expect((rejected as? HTTPURLResponse)?.statusCode == 401)
            let (_, stillB) = try await URLSession.shared.data(
                for: signedHealthRequest(base: base, secret: b.requestSecret, token: b.token)
            )
            #expect((stillB as? HTTPURLResponse)?.statusCode == 200)
            let (_, stillLegacy) = try await URLSession.shared.data(
                for: signedHealthRequest(base: base, secret: rootSecret)
            )
            #expect((stillLegacy as? HTTPURLResponse)?.statusCode == 200)
        }

        let rows = try await fixture.database.listDeviceCredentials()
        let rowA = try #require(rows.first(where: { $0.claims.credentialID == a.credentialID }))
        #expect(rowA.lastActiveAtMs != nil)
        #expect(rowA.revokedAtMs != nil)
    }

    @Test func revocationGossipMakesSecondDatabaseRejectSameCredential() async throws {
        let aFixture = try TestSyncServerFixture(prefix: "duo-revoke-a", secretByte: 0xD2)
        let bFixture = try TestSyncServerFixture(prefix: "duo-revoke-b", secretByte: 0xD2)
        let rootSecret = Data(repeating: 0xD2, count: 32)
        let authA = DeviceCredentialAuthenticator(database: aFixture.database, rootSecret: rootSecret)
        let authB = DeviceCredentialAuthenticator(database: bFixture.database, rootSecret: rootSecret)
        let grant = try await authA.issue(
            client: .init(deviceID: "ios-a", displayName: "iPhone A", platform: "ios"),
            issuerDeviceID: "mac-a"
        )
        #expect(await authB.verify(
            token: grant.token,
            timestampMs: 1_000,
            method: "GET",
            path: "/health",
            bodyHashHex: HMACAuth.emptyBodyHashHex,
            signatureHex: HMACAuth(secret: grant.requestSecret).sign(
                timestampMs: 1_000,
                method: "GET",
                path: "/health",
                bodyHashHex: HMACAuth.emptyBodyHashHex
            ),
            nowMs: 1_000
        ))
        _ = try await authA.revoke(credentialID: grant.credentialID, revokedByDeviceID: "mac-a")
        let sourceServer = SyncServer(
            deviceID: "mac-a",
            database: aFixture.database,
            blobs: aFixture.blobs,
            host: "127.0.0.1",
            port: 0,
            auth: aFixture.auth
        )
        try await aFixture.withServer(sourceServer) { base in
            let client = HTTPPeerClient(baseURL: base, auth: HMACAuth(secret: rootSecret))
            let worker = PullWorker(
                database: bFixture.database,
                transport: client,
                revocationTransport: client,
                selfDeviceID: "mac-b",
                meshStatus: MeshStatus()
            )
            #expect(await worker.syncCredentialRevocations() == 1)
        }
        #expect(!(await authB.verify(
            token: grant.token,
            timestampMs: 1_000,
            method: "GET",
            path: "/health",
            bodyHashHex: HMACAuth.emptyBodyHashHex,
            signatureHex: HMACAuth(secret: grant.requestSecret).sign(
                timestampMs: 1_000,
                method: "GET",
                path: "/health",
                bodyHashHex: HMACAuth.emptyBodyHashHex
            ),
            nowMs: 1_000
        )))
    }
}

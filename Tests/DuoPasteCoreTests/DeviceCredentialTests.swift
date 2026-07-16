import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

@Test func deviceCredentialTokenRoundTripsAndRejectsTamperingOrWrongRoot() throws {
    let root = Data(repeating: 0xA1, count: 32)
    let requestSecret = Data(repeating: 0xB2, count: 32)
    let claims = DeviceCredentialClaims(
        credentialID: "cred-a",
        deviceID: "ios-a",
        displayName: "Bobby’s iPhone",
        platform: "ios",
        issuerDeviceID: "mac-a",
        issuedAtMs: 1_800_000_000_000
    )
    let token = try DeviceCredentialToken.seal(
        claims: claims,
        requestSecret: requestSecret,
        rootSecret: root
    )
    let opened = try DeviceCredentialToken.open(token, rootSecret: root)
    #expect(opened.claims == claims)
    #expect(opened.requestSecret == requestSecret)

    var tampered = Array(token.utf8)
    tampered[tampered.count / 2] = tampered[tampered.count / 2] == 65 ? 66 : 65
    #expect(throws: DeviceCredentialToken.Error.self) {
        _ = try DeviceCredentialToken.open(String(decoding: tampered, as: UTF8.self), rootSecret: root)
    }
    #expect(throws: DeviceCredentialToken.Error.self) {
        _ = try DeviceCredentialToken.open(token, rootSecret: Data(repeating: 0xCC, count: 32))
    }
}

@Test func deviceCredentialMetadataNeverStoresRequestSecretAndRevocationMergeIsMonotonic() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-device-credential-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(root: root)
    paths.ensureExists()
    let database = try Database(path: paths.mainDB)
    let claims = DeviceCredentialClaims(
        credentialID: "cred-a",
        deviceID: "ios-a",
        displayName: "iPhone A",
        platform: "ios",
        issuerDeviceID: "mac-a",
        issuedAtMs: 100
    )

    try await database.recordDeviceCredentialActivity(claims: claims, atMs: 200)
    try await database.recordDeviceCredentialActivity(claims: claims, atMs: 150)
    let listed = try await database.listDeviceCredentials()
    #expect(listed.count == 1)
    #expect(listed[0].claims == claims)
    #expect(listed[0].lastActiveAtMs == 200)

    let columns = try await database.pool.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('device_credential')")
    }
    #expect(!columns.contains("secret"))
    #expect(!columns.contains("token"))

    _ = try await database.revokeDeviceCredential(
        credentialID: "cred-a",
        revokedAtMs: 500,
        revokedByDeviceID: "mac-a"
    )
    let older = DeviceCredentialRevocation(
        credentialID: "cred-a",
        revokedAtMs: 400,
        revokedByDeviceID: "mac-b"
    )
    _ = try await database.mergeDeviceCredentialRevocations([older])
    let revocations = try await database.listDeviceCredentialRevocations()
    #expect(revocations == [DeviceCredentialRevocation(
        credentialID: "cred-a",
        revokedAtMs: 500,
        revokedByDeviceID: "mac-a"
    )])
    #expect(try await database.isDeviceCredentialRevoked("cred-a"))
}

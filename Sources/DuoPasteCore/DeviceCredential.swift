import CryptoKit
import Foundation
import GRDB

/// AES-GCM token 内的公开 identity claims。request secret 跟 claims 一起被 mesh 根密钥
/// 密封，但只有 claims 会落服务端 DB，便于 Settings 展示与审计。
public struct DeviceCredentialClaims: Codable, Equatable, Sendable {
    public let credentialID: String
    public let deviceID: String
    public let displayName: String
    public let platform: String
    public let issuerDeviceID: String
    public let issuedAtMs: Int64

    public init(
        credentialID: String,
        deviceID: String,
        displayName: String,
        platform: String,
        issuerDeviceID: String,
        issuedAtMs: Int64
    ) {
        self.credentialID = credentialID
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.issuerDeviceID = issuerDeviceID
        self.issuedAtMs = issuedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case deviceID = "device_id"
        case displayName = "display_name"
        case platform
        case issuerDeviceID = "issuer_device_id"
        case issuedAtMs = "issued_at_ms"
    }
}

public struct DeviceCredentialPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let claims: DeviceCredentialClaims
    public let requestSecret: Data

    public init(version: Int = 1, claims: DeviceCredentialClaims, requestSecret: Data) {
        self.version = version
        self.claims = claims
        self.requestSecret = requestSecret
    }

    enum CodingKeys: String, CodingKey {
        case version
        case claims
        case requestSecret = "request_secret"
    }
}

/// 客户端实际保存的三件套。`requestSecret` + `token` 必须放 Keychain；服务端只把
/// `claims` 写 metadata 表。
public struct IssuedDeviceCredential: Equatable, Sendable {
    public let claims: DeviceCredentialClaims
    public let requestSecret: Data
    public let token: String

    public init(claims: DeviceCredentialClaims, requestSecret: Data, token: String) {
        self.claims = claims
        self.requestSecret = requestSecret
        self.token = token
    }

    public var credentialID: String { claims.credentialID }
}

public enum DeviceCredentialToken {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidRootSecret
        case invalidRequestSecret
        case invalidClaims
        case invalidToken
        case unsupportedVersion(Int)
    }

    private static let prefix = "dpc1."
    private static let maxTokenBytes = 8 * 1024

    public static func seal(
        claims: DeviceCredentialClaims,
        requestSecret: Data,
        rootSecret: Data
    ) throws -> String {
        guard rootSecret.count == 32 else { throw Error.invalidRootSecret }
        guard requestSecret.count == 32 else { throw Error.invalidRequestSecret }
        guard valid(claims) else { throw Error.invalidClaims }
        let payload = DeviceCredentialPayload(claims: claims, requestSecret: requestSecret)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cleartext = try encoder.encode(payload)
        let sealed = try AES.GCM.seal(cleartext, using: SymmetricKey(data: rootSecret))
        guard let combined = sealed.combined else { throw Error.invalidToken }
        return prefix + base64URL(combined)
    }

    public static func open(_ token: String, rootSecret: Data) throws -> DeviceCredentialPayload {
        guard rootSecret.count == 32 else { throw Error.invalidRootSecret }
        guard token.utf8.count <= maxTokenBytes, token.hasPrefix(prefix) else {
            throw Error.invalidToken
        }
        let encoded = String(token.dropFirst(prefix.count))
        guard let combined = dataFromBase64URL(encoded),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let cleartext = try? AES.GCM.open(box, using: SymmetricKey(data: rootSecret)),
              let payload = try? JSONDecoder().decode(DeviceCredentialPayload.self, from: cleartext)
        else { throw Error.invalidToken }
        guard payload.version == 1 else { throw Error.unsupportedVersion(payload.version) }
        guard payload.requestSecret.count == 32, valid(payload.claims) else {
            throw Error.invalidToken
        }
        return payload
    }

    private static func valid(_ claims: DeviceCredentialClaims) -> Bool {
        !claims.credentialID.isEmpty && claims.credentialID.utf8.count <= 128
            && !claims.deviceID.isEmpty && claims.deviceID.utf8.count <= 256
            && !claims.displayName.isEmpty && claims.displayName.utf8.count <= 256
            && !claims.platform.isEmpty && claims.platform.utf8.count <= 64
            && !claims.issuerDeviceID.isEmpty && claims.issuerDeviceID.utf8.count <= 256
            && claims.issuedAtMs > 0
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataFromBase64URL(_ raw: String) -> Data? {
        var base64 = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

public struct DeviceCredentialRecord: Codable, Equatable, Sendable, Identifiable {
    public let claims: DeviceCredentialClaims
    public let firstSeenAtMs: Int64
    public let lastActiveAtMs: Int64?
    public let revokedAtMs: Int64?
    public let revokedByDeviceID: String?

    public var id: String { claims.credentialID }
    public var isRevoked: Bool { revokedAtMs != nil }
}

public struct DeviceCredentialRevocation: Codable, Equatable, Sendable {
    public let credentialID: String
    public let revokedAtMs: Int64
    public let revokedByDeviceID: String

    public init(credentialID: String, revokedAtMs: Int64, revokedByDeviceID: String) {
        self.credentialID = credentialID
        self.revokedAtMs = revokedAtMs
        self.revokedByDeviceID = revokedByDeviceID
    }

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case revokedAtMs = "revoked_at_ms"
        case revokedByDeviceID = "revoked_by_device_id"
    }
}

public extension Database {
    func recordDeviceCredentialIssued(
        claims: DeviceCredentialClaims,
        atMs: Int64
    ) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO device_credential (
                    credential_id, device_id, display_name, platform, issuer_device_id,
                    issued_at_ms, first_seen_at_ms, last_active_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(credential_id) DO NOTHING
            """, arguments: [
                claims.credentialID,
                claims.deviceID,
                claims.displayName,
                claims.platform,
                claims.issuerDeviceID,
                claims.issuedAtMs,
                atMs,
            ])
        }
    }

    func recordDeviceCredentialActivity(
        claims: DeviceCredentialClaims,
        atMs: Int64
    ) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO device_credential (
                    credential_id, device_id, display_name, platform, issuer_device_id,
                    issued_at_ms, first_seen_at_ms, last_active_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(credential_id) DO UPDATE SET
                    last_active_at_ms = MAX(
                        COALESCE(device_credential.last_active_at_ms, 0),
                        excluded.last_active_at_ms
                    )
            """, arguments: [
                claims.credentialID,
                claims.deviceID,
                claims.displayName,
                claims.platform,
                claims.issuerDeviceID,
                claims.issuedAtMs,
                atMs,
                atMs,
            ])
        }
    }

    func listDeviceCredentials() async throws -> [DeviceCredentialRecord] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.credential_id, c.device_id, c.display_name, c.platform,
                       c.issuer_device_id, c.issued_at_ms, c.first_seen_at_ms,
                       c.last_active_at_ms, r.revoked_at_ms, r.revoked_by_device_id
                FROM device_credential c
                LEFT JOIN device_credential_revocation r USING (credential_id)
                ORDER BY COALESCE(c.last_active_at_ms, c.issued_at_ms) DESC,
                         c.credential_id ASC
            """)
            return rows.map { row in
                DeviceCredentialRecord(
                    claims: DeviceCredentialClaims(
                        credentialID: row["credential_id"],
                        deviceID: row["device_id"],
                        displayName: row["display_name"],
                        platform: row["platform"],
                        issuerDeviceID: row["issuer_device_id"],
                        issuedAtMs: row["issued_at_ms"]
                    ),
                    firstSeenAtMs: row["first_seen_at_ms"],
                    lastActiveAtMs: row["last_active_at_ms"],
                    revokedAtMs: row["revoked_at_ms"],
                    revokedByDeviceID: row["revoked_by_device_id"]
                )
            }
        }
    }

    @discardableResult
    func revokeDeviceCredential(
        credentialID: String,
        revokedAtMs: Int64,
        revokedByDeviceID: String
    ) async throws -> Bool {
        try await pool.write { db in
            try Self.mergeRevocation(
                DeviceCredentialRevocation(
                    credentialID: credentialID,
                    revokedAtMs: revokedAtMs,
                    revokedByDeviceID: revokedByDeviceID
                ),
                in: db
            )
        }
    }

    func isDeviceCredentialRevoked(_ credentialID: String) async throws -> Bool {
        try await pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM device_credential_revocation WHERE credential_id = ?)",
                arguments: [credentialID]
            ) ?? false
        }
    }

    func listDeviceCredentialRevocations() async throws -> [DeviceCredentialRevocation] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT credential_id, revoked_at_ms, revoked_by_device_id
                FROM device_credential_revocation
                ORDER BY revoked_at_ms ASC, credential_id ASC
            """)
            return rows.map { row in
                DeviceCredentialRevocation(
                    credentialID: row["credential_id"],
                    revokedAtMs: row["revoked_at_ms"],
                    revokedByDeviceID: row["revoked_by_device_id"]
                )
            }
        }
    }

    @discardableResult
    func mergeDeviceCredentialRevocations(
        _ revocations: [DeviceCredentialRevocation]
    ) async throws -> Int {
        try await pool.write { db in
            var changed = 0
            for revocation in revocations {
                if try Self.mergeRevocation(revocation, in: db) { changed += 1 }
            }
            return changed
        }
    }

    private static func mergeRevocation(
        _ revocation: DeviceCredentialRevocation,
        in db: GRDB.Database
    ) throws -> Bool {
        guard !revocation.credentialID.isEmpty,
              !revocation.revokedByDeviceID.isEmpty,
              revocation.revokedAtMs > 0
        else { return false }
        try db.execute(sql: """
            INSERT INTO device_credential_revocation (
                credential_id, revoked_at_ms, revoked_by_device_id
            ) VALUES (?, ?, ?)
            ON CONFLICT(credential_id) DO UPDATE SET
                revoked_at_ms = excluded.revoked_at_ms,
                revoked_by_device_id = excluded.revoked_by_device_id
            WHERE excluded.revoked_at_ms > device_credential_revocation.revoked_at_ms
        """, arguments: [
            revocation.credentialID,
            revocation.revokedAtMs,
            revocation.revokedByDeviceID,
        ])
        return db.changesCount > 0
    }
}

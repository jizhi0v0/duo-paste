import Foundation
import DuoPasteCore

/// PIN 配对时由客户端提交的可展示 identity。这里只进入 token claims / metadata，
/// 不参与权限提升；真正的认证能力来自随机 request secret + mesh-root 密封 token。
public struct PairingClientInfo: Codable, Equatable, Sendable {
    public let deviceID: String
    public let displayName: String
    public let platform: String

    public init(deviceID: String, displayName: String, platform: String) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "client_device_id"
        case displayName = "client_name"
        case platform
    }
}

/// 独立设备 credential 的签发、验签、审计与撤销入口。
///
/// token 本身由 mesh shared-secret 加密认证，因此升级后的任一 Mac 都能验签；服务端
/// DB 只落 claims / last-active / revocation，永不保存 request secret 或 token。
public actor DeviceCredentialAuthenticator {
    private let database: DuoPasteCore.Database
    private let rootSecret: Data
    private let now: @Sendable () -> Int64
    private let activityWriteIntervalMs: Int64
    private var lastActivityWrite: [String: Int64] = [:]

    public init(
        database: DuoPasteCore.Database,
        rootSecret: Data,
        now: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        activityWriteIntervalMs: Int64 = 60_000
    ) {
        self.database = database
        self.rootSecret = rootSecret
        self.now = now
        self.activityWriteIntervalMs = max(0, activityWriteIntervalMs)
    }

    public func issue(
        client: PairingClientInfo,
        issuerDeviceID: String
    ) async throws -> IssuedDeviceCredential {
        let issuedAt = now()
        let claims = DeviceCredentialClaims(
            credentialID: UUID().uuidString.lowercased(),
            deviceID: client.deviceID,
            displayName: client.displayName,
            platform: client.platform,
            issuerDeviceID: issuerDeviceID,
            issuedAtMs: issuedAt
        )
        var generator = SystemRandomNumberGenerator()
        let requestSecret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let token = try DeviceCredentialToken.seal(
            claims: claims,
            requestSecret: requestSecret,
            rootSecret: rootSecret
        )
        try await database.recordDeviceCredentialIssued(claims: claims, atMs: issuedAt)
        return IssuedDeviceCredential(claims: claims, requestSecret: requestSecret, token: token)
    }

    public func verify(
        token: String,
        timestampMs: Int64,
        method: String,
        path: String,
        bodyHashHex: String,
        signatureHex: String,
        nowMs: Int64
    ) async -> Bool {
        guard let payload = try? DeviceCredentialToken.open(token, rootSecret: rootSecret),
              (try? await database.isDeviceCredentialRevoked(payload.claims.credentialID)) == false
        else { return false }
        let valid = HMACAuth(secret: payload.requestSecret).verify(
            timestampMs: timestampMs,
            method: method,
            path: path,
            bodyHashHex: bodyHashHex,
            signatureHex: signatureHex,
            nowMs: nowMs
        )
        guard valid else { return false }

        let previous = lastActivityWrite[payload.claims.credentialID]
        if previous == nil || nowMs - (previous ?? 0) >= activityWriteIntervalMs {
            do {
                try await database.recordDeviceCredentialActivity(claims: payload.claims, atMs: nowMs)
                lastActivityWrite[payload.claims.credentialID] = nowMs
            } catch {
                FileHandle.standardError.write(Data("credential activity write failed: \(error)\n".utf8))
            }
        }
        return true
    }

    @discardableResult
    public func revoke(
        credentialID: String,
        revokedByDeviceID: String
    ) async throws -> Bool {
        try await database.revokeDeviceCredential(
            credentialID: credentialID,
            revokedAtMs: now(),
            revokedByDeviceID: revokedByDeviceID
        )
    }

    @discardableResult
    public func mergeRevocations(_ revocations: [DeviceCredentialRevocation]) async throws -> Int {
        try await database.mergeDeviceCredentialRevocations(revocations)
    }

    public func listDevices() async throws -> [DeviceCredentialRecord] {
        try await database.listDeviceCredentials()
    }
}

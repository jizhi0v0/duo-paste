import Foundation
import Security
import DuoPasteCore

struct PeerConfig: Sendable, Equatable {
    let baseURL: URL
    /// legacy shared-secret 或独立 device request secret（均为 32 字节）。
    let sharedSecret: Data
    /// 非 nil 时服务端只走 device credential 验证，不允许降级 legacy。
    let credentialToken: String?

    nonisolated init(baseURL: URL, sharedSecret: Data, credentialToken: String? = nil) {
        self.baseURL = baseURL
        self.sharedSecret = sharedSecret
        self.credentialToken = credentialToken
    }
}

struct ClientCredential: Codable, Equatable, Sendable {
    let credentialID: String?
    let requestSecret: Data
    let token: String?
}

/// request secret + token 的唯一持久化位置。AfterFirstUnlock 让 BGAppRefresh 在设备
/// 解锁过一次后仍可拉取，同时 ThisDeviceOnly 防止凭据随备份迁移到另一台 iPhone。
enum ClientCredentialKeychain {
    private static let service = "io.duopaste.ios.credentials"
    private static let credentialAccount = "active-device-credential"
    private static let deviceIDAccount = "stable-device-id"

    static func load() throws -> ClientCredential? {
        guard let data = try read(account: credentialAccount) else { return nil }
        return try JSONDecoder().decode(ClientCredential.self, from: data)
    }

    static func save(_ credential: ClientCredential) throws {
        guard credential.requestSecret.count == 32 else { throw KeychainError.invalidCredential }
        try write(try JSONEncoder().encode(credential), account: credentialAccount)
    }

    static func delete() throws {
        try remove(account: credentialAccount)
    }

    static func stableDeviceID() throws -> String {
        if let data = try read(account: deviceIDAccount),
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString.lowercased()
        try write(Data(value.utf8), account: deviceIDAccount)
        return value
    }

    private static func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.status(status)
        }
        return data
    }

    private static func write(_ data: Data, account: String) throws {
        try remove(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private static func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    enum KeychainError: LocalizedError {
        case invalidCredential
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidCredential: "设备凭据格式非法"
            case .status(let status): "Keychain 错误 \(status)"
            }
        }
    }
}

/// 启动时 AppStorage 配对数据校验结果——`reason` 非 nil 时 SettingsView 红色横幅展示,
/// 让用户知道为什么没自动连上(否则 try? 静默吞掉,体验"app 启动后什么都不响应")
enum PairingDataStatus: Equatable, Sendable {
    /// 完全没配过(全新装,空 AppStorage)→ 走配对流程
    case empty
    /// PIN 配对路径:endpoints + secret 全 valid → coordinator.reconfigureFromPairing
    case validPaired(secret: Data, endpoints: [PeerEndpoint])
    /// Advanced 手填 URL 路径:peerURL + secretHex valid + 没 endpointsJSON
    case validAdvanced(config: PeerConfig)
    /// 任一字段非法——secretHex 不是 64 hex / endpointsJSON 解不开 / URL 协议错。
    /// reason 是 i18n 友好的中文错误描述,Settings 直接展示
    case invalid(reason: String)
}

enum PairingDataValidator {
    /// 启动时校验 AppStorage。优先级:有 endpointsJSON → PIN 配对路径;否则降级 advanced
    /// URL 路径;两者都没/空 → empty。中间任何字段坏 → invalid + 中文 reason
    static func validate(
        endpointsJSON: String,
        secretHex: String,
        peerURL: String
    ) -> PairingDataStatus {
        let endpointsTrim = endpointsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretTrim = secretHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlTrim = peerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // 全空 → 全新装
        if endpointsTrim.isEmpty && secretTrim.isEmpty && urlTrim.isEmpty {
            return .empty
        }
        // 有 endpointsJSON → 必须 secret + endpoints 都 valid
        if !endpointsTrim.isEmpty {
            guard let data = endpointsTrim.data(using: .utf8),
                  let endpoints = try? JSONDecoder().decode([PeerEndpoint].self, from: data) else {
                return .invalid(reason: "配对的 endpoints 数据损坏(JSON 解码失败),请取消配对后重新走 PIN 配对")
            }
            guard !endpoints.isEmpty else {
                return .invalid(reason: "配对的 endpoints 列表为空,请取消配对后重新走 PIN 配对")
            }
            guard !secretTrim.isEmpty else {
                return .invalid(reason: "配对的 secret 缺失,请取消配对后重新走 PIN 配对")
            }
            guard secretTrim.count == 64, let bytes = Data(hexString: secretTrim), bytes.count == 32 else {
                return .invalid(reason: "配对的 secret 格式非法(应为 64 字符 hex),请取消配对后重新走 PIN 配对")
            }
            return .validPaired(secret: bytes, endpoints: endpoints)
        }
        // 没 endpointsJSON 但有 URL/secret → advanced 路径
        if !urlTrim.isEmpty || !secretTrim.isEmpty {
            do {
                let cfg = try PeerConfig.parse(urlString: urlTrim, secretHex: secretTrim)
                return .validAdvanced(config: cfg)
            } catch let err as PeerConfigError {
                return .invalid(reason: err.errorDescription ?? "advanced URL 配置非法")
            } catch {
                return .invalid(reason: "advanced URL 配置非法: \(error.localizedDescription)")
            }
        }
        return .empty
    }
}

enum PeerConfigError: LocalizedError {
    case missingURL
    case malformedURL
    case missingSecret
    case malformedSecretHex

    var errorDescription: String? {
        switch self {
        case .missingURL:        "未配置 peer URL"
        case .malformedURL:      "peer URL 非法（需要 http:// 或 https://）"
        case .missingSecret:     "未配置 shared secret"
        case .malformedSecretHex:"shared secret 必须是 64 字符 hex"
        }
    }
}

extension PeerConfig {
    static func parse(urlString: String, secretHex: String) throws -> PeerConfig {
        let urlTrim = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlTrim.isEmpty else { throw PeerConfigError.missingURL }
        guard let url = URL(string: urlTrim),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw PeerConfigError.malformedURL
        }
        let secTrim = secretHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secTrim.isEmpty else { throw PeerConfigError.missingSecret }
        guard secTrim.count == 64,
              let bytes = Data(hexString: secTrim),
              bytes.count == 32 else {
            throw PeerConfigError.malformedSecretHex
        }
        return PeerConfig(baseURL: url, sharedSecret: bytes, credentialToken: nil)
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = chars[i].hexDigitValue,
                  let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi * 16 + lo))
        }
        self = Data(out)
    }
}

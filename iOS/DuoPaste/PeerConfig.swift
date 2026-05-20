import Foundation
import DuoPasteCore

struct PeerConfig: Sendable, Equatable {
    let baseURL: URL
    /// 32 字节 HMAC secret（已 hex-decode）。
    let sharedSecret: Data
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
        return PeerConfig(baseURL: url, sharedSecret: bytes)
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

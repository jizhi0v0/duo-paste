import Foundation

struct PeerConfig: Sendable, Equatable {
    let baseURL: URL
    /// 32 字节 HMAC secret（已 hex-decode）。
    let sharedSecret: Data
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

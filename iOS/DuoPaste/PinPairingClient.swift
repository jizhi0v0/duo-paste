import Foundation
import Network
import DuoPasteCore

/// PIN 配对 HTTP client。无 HMAC(还没拿到 secret),走"用户 physical 看到 PIN + Mac
/// 端 60s 失效 + 5 次错锁"做 trust anchor。
///
/// **TLS 处理**:Bonjour 发现的 Mac 通常是 `<host>.local`,跟 Tailscale TLS cert CN
/// (`<host>.tail-xxx.ts.net`)不匹配 → 默认信任会拒。这里用 `acceptAnyTrust` 路径——
/// /pair 的 trust anchor 是 PIN+rate-limit,不是 TLS;PIN 验证成功后拿到 secret,
/// 后续走 HMAC 不再依赖 TLS。LAN 内 MitM 攻击者拿不到 PIN 也过不了 server 端校验
@MainActor
enum PinPairingClient {
    struct Response: Sendable {
        let secret: Data
        let deviceID: String
    }

    enum Error: LocalizedError {
        case badURL
        case nonHTTP
        case pinMismatch
        case pinExpired
        case rateLimited
        case noSession
        case serverError(status: Int, body: String)
        case malformedResponse
        case secretNotHex

        var errorDescription: String? {
            switch self {
            case .badURL: return "URL 格式非法"
            case .nonHTTP: return "非 HTTP 响应"
            case .pinMismatch: return "PIN 错误"
            case .pinExpired: return "PIN 已过期(60s),让 Mac 重新生成"
            case .rateLimited: return "试错次数太多,让 Mac 重新生成 PIN"
            case .noSession: return "Mac 端没有活跃 PIN session,先点「显示配对码」"
            case .serverError(let s, _): return "服务端错误 HTTP \(s)"
            case .malformedResponse: return "服务端返回格式错误"
            case .secretNotHex: return "服务端返回 secret 非 hex"
            }
        }
    }

    /// 拿 NWEndpoint(从 Bonjour 发现的 Mac)+ PIN → 配对完成返 secret + deviceID
    static func pair(endpoint: NWEndpoint, port: Int, tls: Bool, pin: String) async throws -> Response {
        let host: String
        switch endpoint {
        case .service(let name, _, _, _):
            // Bonjour service name 不是 hostname。需要 resolve 到 hostname。
            // NWBrowser 默认 result 的 endpoint 是 .service 形式;.hostPort 是 resolved 形式
            host = "\(name).local"
        case .hostPort(let h, _):
            host = "\(h)"
        default:
            throw Error.badURL
        }
        return try await pair(host: host, port: port, tls: tls, pin: pin)
    }

    /// 直接 host:port + tls → 配对。给"已知 Mac URL"路径用
    static func pair(host: String, port: Int, tls: Bool, pin: String) async throws -> Response {
        let scheme = tls ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host):\(port)/pair/\(pin)") else {
            throw Error.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data()
        req.timeoutInterval = 10

        let delegate = TrustAnyDelegate()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Error.nonHTTP }
        switch http.statusCode {
        case 200: break
        case 401: throw Error.pinMismatch
        case 410: throw Error.pinExpired
        case 429: throw Error.rateLimited
        case 404: throw Error.noSession
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.serverError(status: http.statusCode, body: body)
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secretHex = dict["secret"] as? String,
              let deviceID = dict["device_id"] as? String else {
            throw Error.malformedResponse
        }
        guard let secret = Data(hex: secretHex) else {
            throw Error.secretNotHex
        }
        return Response(secret: secret, deviceID: deviceID)
    }
}

/// `URLSessionDelegate` 接受任何 TLS cert。**仅 /pair 路径用**——pairing trust anchor 是
/// PIN + Mac 端 server 验证,不依赖 TLS cert 正确性。pairing 完成后所有通信走 HMAC,
/// HMAC 签名层兜底防 MitM,TLS 此时只是 transport 加密
private final class TrustAnyDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private extension Data {
    init?(hex: String) {
        let chars = Array(hex.lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Self.hexDigit(chars[i]),
                  let lo = Self.hexDigit(chars[i + 1]) else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = Data(bytes)
    }

    static func hexDigit(_ c: Character) -> UInt8? {
        switch c {
        case "0"..."9": return UInt8(c.asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return UInt8(c.asciiValue! - Character("a").asciiValue!) + 10
        default: return nil
        }
    }
}

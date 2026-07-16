import Foundation
import Network
import UIKit
import DuoPasteCore

/// PIN 配对 HTTP client。无 HMAC（还没拿到 credential），先用 QR 带来的 leaf SHA-256
/// pin 验证 TLS server identity，再发送用户从同屏读取的 6 位 PIN。
///
/// 精确 leaf pin 允许 `.local` hostname / 私有 CA，不依赖系统 trust store；攻击者若用
/// 自己的 leaf 终止 TLS，会在 request 发出前失败，因此看不到 PIN 或签发结果。
@MainActor
enum PinPairingClient {
    struct Response: Sendable {
        let credential: ClientCredential
        let deviceID: String
        let endpointsPage: PeerEndpointsPage
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
        case missingEndpoints
        case channelBindingRequired
        case certificateMismatch

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
            case .missingEndpoints: return "服务端未返回 endpoints,请更新 Mac 端 duo-pasted"
            case .channelBindingRequired: return "安全配对需要扫描新版 Mac QR"
            case .certificateMismatch: return "TLS leaf 与 QR 不一致；可能证书已轮换或连接被劫持，请重扫 QR"
            }
        }
    }

    /// QR 的 host:port + leaf pin → 配对。host 是 Mac 生成的 mDNS `.local` hostname。
    static func pair(
        host: String,
        port: Int,
        tls: Bool,
        pin: String,
        certificateSHA256: String
    ) async throws -> Response {
        guard tls,
              let normalizedPin = PairingCertificatePin.normalizedSHA256(certificateSHA256),
              let delegate = PinnedCertificateDelegate(expectedSHA256: normalizedPin)
        else { throw Error.channelBindingRequired }
        let scheme = tls ? "https" : "http"
        // URLComponents 而非 URL(string:) — 让 host 即便含特殊字符也能 percent-encode。
        // 但 host 应该已是 sanitized .local 名,不该有特殊字符;这里 defensively
        var comp = URLComponents()
        comp.scheme = scheme
        comp.host = host
        comp.port = port
        comp.path = "/pair/\(pin)"
        guard let url = comp.url else {
            throw Error.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let metadata = PairingMetadata(
            clientDeviceID: try ClientCredentialKeychain.stableDeviceID(),
            clientName: UIDevice.current.name,
            platform: "ios"
        )
        req.httpBody = try JSONEncoder().encode(metadata)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        // data(for:delegate:) 走 URLSessionTaskDelegate;iOS 26 上 data(for:) 不可靠
        // 触发 session-level didReceive challenge,task delegate 才稳触发(实测)
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req, delegate: delegate)
        } catch {
            if delegate.rejectedCertificate { throw Error.certificateMismatch }
            throw error
        }
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
        let wire: PairWire
        do {
            wire = try JSONDecoder().decode(PairWire.self, from: data)
        } catch {
            throw Error.malformedResponse
        }
        let credential: ClientCredential
        if let modern = wire.credential,
           let requestSecret = Data(hex: modern.secret),
           requestSecret.count == 32,
           !modern.id.isEmpty,
           modern.token.hasPrefix("dpc1.") {
            credential = ClientCredential(
                credentialID: modern.id,
                requestSecret: requestSecret,
                token: modern.token
            )
        } else if let legacy = wire.secret,
                  let requestSecret = Data(hex: legacy),
                  requestSecret.count == 32 {
            // 新 iOS → 旧 Mac 的 rolling-upgrade fallback；仍只写 Keychain。
            credential = ClientCredential(
                credentialID: nil,
                requestSecret: requestSecret,
                token: nil
            )
        } else {
            throw Error.secretNotHex
        }
        guard !wire.endpointsPage.endpoints.isEmpty || !(wire.endpointsPage.meshPeers ?? []).isEmpty else {
            throw Error.missingEndpoints
        }
        return Response(credential: credential, deviceID: wire.deviceID, endpointsPage: wire.endpointsPage)
    }

    private struct PairWire: Decodable {
        let secret: String?
        let credential: CredentialWire?
        let deviceID: String
        let endpointsPage: PeerEndpointsPage

        enum CodingKeys: String, CodingKey {
            case secret
            case credential
            case deviceID = "device_id"
            case endpointsPage = "endpoints_page"
        }
    }

    private struct CredentialWire: Decodable {
        let id: String
        let secret: String
        let token: String
    }

    private struct PairingMetadata: Encodable {
        let clientDeviceID: String
        let clientName: String
        let platform: String

        enum CodingKeys: String, CodingKey {
            case clientDeviceID = "client_device_id"
            case clientName = "client_name"
            case platform
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

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
            }
        }
    }

    /// host:port + tls → 配对。host 应该是 mDNS sanitized hostname(从 Bonjour TXT
    /// 拿的 host 字段),不能用 Bonjour service.name(含空格/撇号会让 URL parse fail)
    static func pair(host: String, port: Int, tls: Bool, pin: String) async throws -> Response {
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
        req.httpBody = Data()
        req.timeoutInterval = 10

        let delegate = TrustAnyDelegate()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        // data(for:delegate:) 走 URLSessionTaskDelegate;iOS 26 上 data(for:) 不可靠
        // 触发 session-level didReceive challenge,task delegate 才稳触发(实测)
        let (data, resp) = try await session.data(for: req, delegate: delegate)
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
        guard let secret = Data(hex: wire.secret) else {
            throw Error.secretNotHex
        }
        guard !wire.endpointsPage.endpoints.isEmpty || !(wire.endpointsPage.meshPeers ?? []).isEmpty else {
            throw Error.missingEndpoints
        }
        return Response(secret: secret, deviceID: wire.deviceID, endpointsPage: wire.endpointsPage)
    }

    private struct PairWire: Decodable {
        let secret: String
        let deviceID: String
        let endpointsPage: PeerEndpointsPage

        enum CodingKeys: String, CodingKey {
            case secret
            case deviceID = "device_id"
            case endpointsPage = "endpoints_page"
        }
    }
}

// TrustAnyDelegate 提取到 TrustAnyDelegate.swift 共享给 EndpointPicker 等

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

import Foundation
import DuoPasteCore

/// iOS 端 peer HTTP client。直接 URLSession + HMAC,不复用 mac 端 DuoPasteSync 的 HTTPPeerClient
/// (那个绑了 Hummingbird-side 的依赖)。所有签名规则跟 mac 端一致——sign string
/// `<ts_ms>\n<METHOD>\n<signedPath>\n<bodyHashHex>`,header 用 X-DP-Timestamp/Body-SHA256/Auth。
actor PeerClient {
    let config: PeerConfig
    private let auth: HMACAuth
    private let session: URLSession
    private let decoder: JSONDecoder

    init(config: PeerConfig, session: URLSession = TrustAnyHTTP.shared) {
        self.config = config
        self.auth = HMACAuth(secret: config.sharedSecret)
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - /health

    struct HealthInfo: Sendable, Equatable {
        let deviceID: String
        let nowMs: Int64
        let ponteHost: String?
    }

    func fetchHealth() async throws -> HealthInfo {
        let url = config.baseURL.appendingPathComponent("/health")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, method: "GET", signedPath: "/health", bodyHash: HMACAuth.emptyBodyHashHex)
        let (data, resp) = try await session.data(for: req)
        try Self.requireOK(resp)
        let h = try decoder.decode(HealthWire.self, from: data)
        return HealthInfo(deviceID: h.deviceID, nowMs: h.nowMs, ponteHost: h.ponteHost)
    }

    // MARK: - /since

    func fetchSince(cursor: SinceCursor, limit: Int = 500) async throws -> SincePageWire {
        // query items 顺序跟 mac 端 SinceClient 一致——保证签名 path 完全一致
        let qi = [
            URLQueryItem(name: "cursor_ns", value: String(cursor.ingestedAtNs)),
            URLQueryItem(name: "cursor_id", value: cursor.id),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        var sigComp = URLComponents()
        sigComp.path = "/since"
        sigComp.queryItems = qi
        let signedPath = "/since" + (sigComp.percentEncodedQuery.map { "?\($0)" } ?? "")

        var urlComp = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        urlComp.path = (urlComp.path) + "/since"
        urlComp.queryItems = qi
        guard let url = urlComp.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, method: "GET", signedPath: signedPath, bodyHash: HMACAuth.emptyBodyHashHex)
        let (data, resp) = try await session.data(for: req)
        try Self.requireOK(resp)
        return try decoder.decode(SincePageWire.self, from: data)
    }

    /// 拉完所有 has_more 页直到 server 端追平。失败抛出。
    func fetchAllSincePages(
        startCursor: SinceCursor,
        pageLimit: Int = 500,
        maxPages: Int = 50
    ) async throws -> (items: [Item], finalCursor: SinceCursor) {
        var cursor = startCursor
        var collected: [Item] = []
        for _ in 0..<maxPages {
            try Task.checkCancellation()
            let page = try await fetchSince(cursor: cursor, limit: pageLimit)
            collected.append(contentsOf: page.items)
            cursor = page.nextCursor
            if !page.hasMore { break }
        }
        return (collected, cursor)
    }

    // MARK: - /blob/<sha>

    func fetchBlob(sha256: String) async throws -> Data {
        let path = "/blob/\(sha256)"
        let url = config.baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, method: "GET", signedPath: path, bodyHash: HMACAuth.emptyBodyHashHex)
        let (data, resp) = try await session.data(for: req)
        try Self.requireOK(resp)
        let actual = HMACAuth.sha256Hex(data)
        guard actual.lowercased() == sha256.lowercased() else {
            throw PeerClientError.shaMismatch(expected: sha256, actual: actual)
        }
        return data
    }

    // MARK: - /app_icon/<bundleID>

    /// 拉 macOS app icon PNG 字节。404 → nil(app 没装 / non-app bundleID);
    /// 其他错抛 PeerClientError。bundleID 含点 / hyphen / digits 都不用 percent-encode,
    /// 是 RFC 3986 unreserved 字符
    func fetchAppIcon(bundleID: String) async throws -> Data? {
        let path = "/app_icon/\(bundleID)"
        let url = config.baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, method: "GET", signedPath: path, bodyHash: HMACAuth.emptyBodyHashHex)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PeerClientError.nonHTTP }
        if http.statusCode == 404 { return nil }
        if !(200..<300).contains(http.statusCode) {
            throw PeerClientError.httpStatus(http.statusCode)
        }
        return data
    }

    // MARK: - GET /endpoints

    /// 拿 Mac 当前的可达 URL 候选 list。iOS EndpointPicker 用来探活测 RTT 选最低
    func fetchEndpoints() async throws -> PeerEndpointsPage {
        let url = config.baseURL.appendingPathComponent("/endpoints")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, method: "GET", signedPath: "/endpoints", bodyHash: HMACAuth.emptyBodyHashHex)
        let (data, resp) = try await session.data(for: req)
        try Self.requireOK(resp)
        return try decoder.decode(PeerEndpointsPage.self, from: data)
    }

    // MARK: - POST /bump/<id>

    /// 跨设备一致"复制即顶":iOS tap 某条 → Mac DB bump captured/ingested_at_ns →
    /// broadcaster 推 cursor_advanced → 其他 peer 通过 PullWorker 看到这条顶到前面。
    /// body 空,id 在 path 里被 HMAC 签名覆盖。
    ///
    /// 错误处理:404 → `.itemNotFound`(本机历史可能比 Mac DB 新,正常,swallow 不影响 UX);
    /// 410 → `.itemTombstoned`(Mac 端已软删,本机视图过期,swallow);其他 throw 让上层决定
    func bumpItem(id: String) async throws {
        let path = "/bump/\(id)"
        let url = config.baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // 显式 0-byte body 让 URLSession 不去 sniff 自动补 Content-Length
        req.httpBody = Data()
        sign(&req, method: "POST", signedPath: path, bodyHash: HMACAuth.emptyBodyHashHex)
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PeerClientError.nonHTTP }
        switch http.statusCode {
        case 200...299: return
        case 404: throw PeerClientError.itemNotFound
        case 410: throw PeerClientError.itemTombstoned
        default: throw PeerClientError.httpStatus(http.statusCode)
        }
    }

    // MARK: - 内部

    private func sign(
        _ req: inout URLRequest,
        method: String,
        signedPath: String,
        bodyHash: String
    ) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let sig = auth.sign(timestampMs: ts, method: method, path: signedPath, bodyHashHex: bodyHash)
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(bodyHash, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
    }

    private static func requireOK(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw PeerClientError.nonHTTP }
        if !(200..<300).contains(http.statusCode) {
            throw PeerClientError.httpStatus(http.statusCode)
        }
    }

    /// `/health` wire 形态。server 端把 now_ms 写成 String,这里宽容 String/Int64/Double。
    private struct HealthWire: Decodable {
        let deviceID: String
        let nowMs: Int64
        let ponteHost: String?

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case nowMs = "now_ms"
            case ponteHost = "ponte_host"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.deviceID = try c.decode(String.self, forKey: .deviceID)
            self.ponteHost = try c.decodeIfPresent(String.self, forKey: .ponteHost)
            if let s = try? c.decode(String.self, forKey: .nowMs), let n = Int64(s) {
                self.nowMs = n
            } else if let n = try? c.decode(Int64.self, forKey: .nowMs) {
                self.nowMs = n
            } else if let d = try? c.decode(Double.self, forKey: .nowMs) {
                self.nowMs = Int64(d)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nowMs, in: c, debugDescription: "now_ms not parseable"
                )
            }
        }
    }
}

enum PeerClientError: LocalizedError {
    case nonHTTP
    case httpStatus(Int)
    case shaMismatch(expected: String, actual: String)
    case itemNotFound      // POST /bump:server 没这条 id
    case itemTombstoned    // POST /bump:server 上已软删

    var errorDescription: String? {
        switch self {
        case .nonHTTP:
            return "非 HTTP 响应"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .shaMismatch(let e, let a):
            return "blob SHA 不匹配（期望 \(String(e.prefix(12)))…, 实际 \(String(a.prefix(12)))…）"
        case .itemNotFound:
            return "对端无此条目"
        case .itemTombstoned:
            return "对端已删除此条目"
        }
    }
}

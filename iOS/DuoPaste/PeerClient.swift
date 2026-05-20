import Foundation
import Network
import DuoPasteCore

/// iOS 端 peer HTTP client。直接 URLSession + HMAC,不复用 mac 端 DuoPasteSync 的 HTTPPeerClient
/// (那个绑了 Hummingbird-side 的依赖)。所有签名规则跟 mac 端一致——sign string
/// `<ts_ms>\n<METHOD>\n<signedPath>\n<bodyHashHex>`,header 用 X-DP-Timestamp/Body-SHA256/Auth。
actor PeerClient {
    let config: PeerConfig
    private let auth: HMACAuth
    private let session: URLSession
    private let taskDelegate: URLSessionTaskDelegate?
    private let decoder: JSONDecoder

    init(config: PeerConfig, session: URLSession? = nil) {
        self.config = config
        self.auth = HMACAuth(secret: config.sharedSecret)
        if let session {
            self.session = session
            self.taskDelegate = nil
        } else {
            let delegate = TrustAnyDelegate()
            self.taskDelegate = delegate
            self.session = URLSession(
                configuration: TrustAnyHTTP.makeConfiguration(),
                delegate: delegate,
                delegateQueue: nil
            )
        }
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
        let (data, resp) = try await data(for: req)
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
        let signedPath = HMACAuth.canonicalPath("/since", query: sigComp.percentEncodedQuery)

        var urlComp = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        urlComp.path = (urlComp.path) + "/since"
        urlComp.queryItems = qi
        guard let url = urlComp.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, method: "GET", signedPath: signedPath, bodyHash: HMACAuth.emptyBodyHashHex)
        let (data, resp) = try await data(for: req)
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
        let (data, resp) = try await data(for: req)
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
        let (data, resp) = try await data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PeerClientError.nonHTTP }
        if http.statusCode == 404 { return nil }
        if !(200..<300).contains(http.statusCode) {
            throw PeerClientError.httpStatus(http.statusCode)
        }
        return data
    }

    // MARK: - GET /endpoints

    /// 拿 Mac 当前的可达 URL 候选 list。iOS EndpointPicker 用来探活并按 route hint 选最佳路线。
    func fetchEndpoints() async throws -> PeerEndpointsPage {
        let url = config.baseURL.appendingPathComponent("/endpoints")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, method: "GET", signedPath: "/endpoints", bodyHash: HMACAuth.emptyBodyHashHex)
        let (data, resp) = try await data(for: req)
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
        let (_, resp) = try await data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PeerClientError.nonHTTP }
        switch http.statusCode {
        case 200...299: return
        case 404: throw PeerClientError.itemNotFound
        case 410: throw PeerClientError.itemTombstoned
        default: throw PeerClientError.httpStatus(http.statusCode)
        }
    }

    // MARK: - GET /search?q=<text>

    /// 委托 Mac peer 跑 fold-aware 全文搜索——iOS 本地没 GRDB/FTS5,query 非空时走这条
     /// 拿到跨设备口径一致的命中。返回 (items, snippets, totalCount)。
     ///
     /// snippets: id → 含 STX/ETX(0x02/0x03) 控制字符的高亮片段;query 为空时空 map。
     /// totalCount: fold 后 limit/offset 之前的真实总数,UI 显"共 N 条"
    func searchItems(q: String, limit: Int = 200, offset: Int = 0) async throws -> (items: [Item], snippets: [String: String], totalCount: Int) {
        // query items 顺序固定——签名 path 一致性硬不变量(跟 /since 同源)
        var qi: [URLQueryItem] = []
        if !q.isEmpty { qi.append(URLQueryItem(name: "q", value: q)) }
        qi.append(URLQueryItem(name: "limit", value: String(limit)))
        if offset > 0 { qi.append(URLQueryItem(name: "offset", value: String(offset))) }
        var sigComp = URLComponents()
        sigComp.path = "/search"
        sigComp.queryItems = qi
        let signedPath = HMACAuth.canonicalPath("/search", query: sigComp.percentEncodedQuery)

        var urlComp = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        urlComp.path = (urlComp.path) + "/search"
        urlComp.queryItems = qi
        guard let url = urlComp.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        sign(&req, method: "GET", signedPath: signedPath, bodyHash: HMACAuth.emptyBodyHashHex)
        let (data, resp) = try await data(for: req)
        try Self.requireOK(resp)
        let page = try decoder.decode(SearchPageWire.self, from: data)
        var snippets: [String: String] = [:]
        for hit in page.items {
            if let s = hit.snippet { snippets[hit.item.id] = s }
        }
        return (page.items.map(\.item), snippets, page.count)
    }

    // MARK: - DELETE /item/<id>

    /// 软删条目:iOS 长按"删除" → Mac DB 写 deleted_at_ns + bump ingested_at_ns →
    /// broadcaster 推 cursor_advanced → 其他 peer 通过 /since 看到 tombstone。
    /// body 空,id 在 path 里被 HMAC 签名覆盖。
    ///
    /// 错误处理:404 → `.itemNotFound`(罕见,Mac 已 retention 扫了 / 本机视图 stale);
    /// 410 → `.itemTombstoned`(Mac 已删,**幂等成功**——调用方应当 swallow,不暴露给 UI)。
    /// 其他 throw 让上层决定(乐观删除路径默认 swallow + 等 /since 自然 reconcile)
    func deleteItem(id: String) async throws {
        let path = "/item/\(id)"
        let url = config.baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.httpBody = Data()
        sign(&req, method: "DELETE", signedPath: path, bodyHash: HMACAuth.emptyBodyHashHex)
        let (_, resp) = try await data(for: req)
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

    private func data(for req: URLRequest) async throws -> (Data, URLResponse) {
        if Self.isPonte(req.url) {
            DebugLog.shared.append("http nw transport: \(req.httpMethod ?? "GET") \(req.url?.absoluteString ?? "?")")
            return try await NWHTTPTransport.data(for: req, timeoutSec: 12)
        }
        return try await session.data(for: req, delegate: taskDelegate)
    }

    private static func isPonte(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.hasSuffix(".sgponte")
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

private enum NWHTTPTransport {
    static func data(for req: URLRequest, timeoutSec: TimeInterval) async throws -> (Data, URLResponse) {
        guard let url = req.url,
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? defaultPort(for: url))),
              let method = req.httpMethod else {
            throw URLError(.badURL)
        }
        let isTLS = (url.scheme?.lowercased() == "https")
        let params: NWParameters
        if isTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, complete in complete(true) },
                DispatchQueue.global(qos: .userInitiated)
            )
            params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        let requestBytes = makeHTTPRequestBytes(req: req, method: method, url: url, host: host)
        return try await withCheckedThrowingContinuation { cont in
            let box = ResumeOnce()
            var buffer = Data()
            let queue = DispatchQueue(label: "io.duopaste.nw-http")

            func finish(_ result: Result<(Data, URLResponse), Error>) {
                if box.claim() {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    cont.resume(with: result)
                }
            }

            func receiveMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { chunk, _, isComplete, error in
                    if let error {
                        finish(.failure(error))
                        return
                    }
                    if let chunk {
                        buffer.append(chunk)
                    }
                    if let parsed = tryParse(buffer: buffer, url: url) {
                        finish(parsed)
                        return
                    }
                    if isComplete {
                        finish(tryParse(buffer: buffer, url: url) ?? .failure(URLError(.badServerResponse)))
                        return
                    }
                    receiveMore()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: requestBytes, completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(error))
                        } else {
                            receiveMore()
                        }
                    })
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CancellationError()))
                case .waiting(let error):
                    finish(.failure(error))
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeoutSec) {
                finish(.failure(URLError(.timedOut)))
            }
        }
    }

    private static func defaultPort(for url: URL) -> Int {
        (url.scheme?.lowercased() == "https") ? 443 : 80
    }

    private static func makeHTTPRequestBytes(req: URLRequest, method: String, url: URL, host: String) -> Data {
        let path = pathAndQuery(for: url)
        let portSuffix: String = {
            guard let port = url.port, port != defaultPort(for: url) else { return "" }
            return ":\(port)"
        }()
        var lines: [String] = [
            "\(method) \(path) HTTP/1.1",
            "Host: \(host)\(portSuffix)",
            "Connection: close",
            "Accept: */*",
        ]
        for (key, value) in req.allHTTPHeaderFields ?? [:] {
            if key.lowercased() == "host" || key.lowercased() == "connection" { continue }
            lines.append("\(key): \(value)")
        }
        let body = req.httpBody ?? Data()
        if !body.isEmpty {
            lines.append("Content-Length: \(body.count)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    private static func pathAndQuery(for url: URL) -> String {
        var out = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            out += "?\(query)"
        }
        return out
    }

    private static func tryParse(buffer: Data, url: URL) -> Result<(Data, URLResponse), Error>? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            return .failure(URLError(.badServerResponse))
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return .failure(URLError(.badServerResponse)) }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            return .failure(URLError(.badServerResponse))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<sep]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerEnd.upperBound
        let body = buffer[bodyStart...]
        if let te = headers.first(where: { $0.key.lowercased() == "transfer-encoding" })?.value.lowercased(),
           te.contains("chunked") {
            guard let decoded = decodeChunked(Data(body)) else { return nil }
            return .success((decoded, response(url: url, status: status, headers: headers)))
        }
        if let cl = headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
           let len = Int(cl) {
            guard body.count >= len else { return nil }
            return .success((Data(body.prefix(len)), response(url: url, status: status, headers: headers)))
        }
        return nil
    }

    private static func response(url: URL, status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        var pos = data.startIndex
        var out = Data()
        while true {
            guard let lineRange = data[pos...].range(of: Data("\r\n".utf8)) else { return nil }
            guard let line = String(data: data[pos..<lineRange.lowerBound], encoding: .ascii) else { return nil }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return nil }
            pos = lineRange.upperBound
            if size == 0 { return out }
            guard data.distance(from: pos, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(pos, offsetBy: size)
            out.append(data[pos..<chunkEnd])
            pos = data.index(chunkEnd, offsetBy: 2)
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var used = false
        nonisolated func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}

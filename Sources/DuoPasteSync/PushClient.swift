import Foundation
import DuoPasteCore

/// `POST /ingest` 的响应。和服务端 Server.swift 里 errorJSON / 成功 JSON 一致。
public struct IngestResponse: Codable, Sendable {
    public var ok: Bool
    public var id: String?
    public var ingestedAtNs: Int64?
    public var wasNew: Bool?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case id
        case ingestedAtNs = "ingested_at_ns"
        case wasNew = "was_new"
        case error
    }
}

/// 客户端到 primary 的传输抽象。生产用 HTTPIngestClient，测试用 in-memory 假实现。
public protocol IngestTransport: Sendable {
    func ingest(_ req: IngestRequest) async throws -> IngestResult
    /// 上传 blob 到 primary。`headIfExists=true` 时先 HEAD 探测，避免重传。
    /// data 的 sha256 必须等于 `sha256` 参数——content-addressed 契约。
    /// 返回 outcome：acked / rejected / transient，语义同 ingest。
    func putBlob(sha256: String, data: Data) async throws -> IngestResult
}

/// 业务层结果（屏蔽 HTTP 细节）。和 IngestResponse 不同：
/// - retryable=true → 网络 / 5xx，调用方应该重试
/// - retryable=false → 4xx / 解码失败，重试也没用，应该 mark failed
public struct IngestResult: Sendable {
    public enum Outcome: Sendable {
        case acked(ingestedAtNs: Int64?, wasNew: Bool)
        case rejected(reason: String)       // 4xx, 不重试
        case transient(reason: String)      // 网络 / 5xx, 重试
    }
    public let outcome: Outcome

    public init(outcome: Outcome) { self.outcome = outcome }
}

/// 默认 HTTP 实现。注入 URLSession 便于测试覆盖（mock URLProtocol）；生产用 .shared。
public struct HTTPIngestClient: IngestTransport {
    public let baseURL: URL
    public let auth: HMACAuth
    public let session: URLSession
    public let now: @Sendable () -> Int64

    public init(
        baseURL: URL,
        auth: HMACAuth,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
        self.now = now
    }

    public func ingest(_ req: IngestRequest) async throws -> IngestResult {
        // 编码 body
        let body: Data
        do {
            body = try JSONEncoder().encode(req)
        } catch {
            return IngestResult(outcome: .rejected(reason: "encode failed: \(error)"))
        }
        let bodyHash = HMACAuth.sha256Hex(body)
        let ts = now()
        let path = "/ingest"
        let sig = auth.sign(timestampMs: ts, method: "POST", path: path, bodyHashHex: bodyHash)

        var url = baseURL
        url.append(path: path)
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.httpBody = body
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        urlReq.setValue(bodyHash, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        urlReq.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlReq)
        } catch {
            // 网络层失败（连接拒绝、超时、DNS）→ transient
            return IngestResult(outcome: .transient(reason: "transport: \(error.localizedDescription)"))
        }
        guard let http = response as? HTTPURLResponse else {
            return IngestResult(outcome: .transient(reason: "non-http response"))
        }
        switch http.statusCode {
        case 200...299:
            let parsed = (try? JSONDecoder().decode(IngestResponse.self, from: data)) ?? IngestResponse(ok: true, id: req.id, ingestedAtNs: nil, wasNew: nil, error: nil)
            return IngestResult(outcome: .acked(
                ingestedAtNs: parsed.ingestedAtNs,
                wasNew: parsed.wasNew ?? true
            ))
        case 400, 401, 403, 404, 422:
            // 4xx：协议层拒绝，重试没用
            let msg = (try? JSONDecoder().decode(IngestResponse.self, from: data))?.error ?? "http \(http.statusCode)"
            return IngestResult(outcome: .rejected(reason: msg))
        default:
            // 5xx + 其他：当瞬时
            return IngestResult(outcome: .transient(reason: "http \(http.statusCode)"))
        }
    }

    public func putBlob(sha256: String, data: Data) async throws -> IngestResult {
        let actualHash = HMACAuth.sha256Hex(data)
        guard actualHash == sha256 else {
            // 本地 sha256 校验失败：blob 写盘后被改 / 传错了。立即拒绝，不浪费一次往返。
            return IngestResult(outcome: .rejected(reason: "local sha256 mismatch: \(sha256) vs \(actualHash)"))
        }
        let path = "/blob/\(sha256)"

        // 先 HEAD 探测：blob 已在 primary → 跳过上传
        if await blobExists(path: path) {
            return IngestResult(outcome: .acked(ingestedAtNs: nil, wasNew: false))
        }

        // PUT
        let ts = now()
        let sig = auth.sign(timestampMs: ts, method: "PUT", path: path, bodyHashHex: sha256)
        var url = baseURL
        url.append(path: path)
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "PUT"
        urlReq.httpBody = data
        urlReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        urlReq.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        urlReq.setValue(sha256, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        urlReq.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

        let respData: Data
        let response: URLResponse
        do {
            (respData, response) = try await session.data(for: urlReq)
        } catch {
            return IngestResult(outcome: .transient(reason: "blob put transport: \(error.localizedDescription)"))
        }
        guard let http = response as? HTTPURLResponse else {
            return IngestResult(outcome: .transient(reason: "blob put non-http"))
        }
        switch http.statusCode {
        case 200, 201:
            return IngestResult(outcome: .acked(ingestedAtNs: nil, wasNew: http.statusCode == 201))
        case 400, 401, 403, 404, 422:
            let msg = String(data: respData, encoding: .utf8) ?? "http \(http.statusCode)"
            return IngestResult(outcome: .rejected(reason: "blob put rejected: \(msg)"))
        default:
            return IngestResult(outcome: .transient(reason: "blob put http \(http.statusCode)"))
        }
    }

    private func blobExists(path: String) async -> Bool {
        let ts = now()
        let sig = auth.sign(timestampMs: ts, method: "HEAD", path: path,
                            bodyHashHex: HMACAuth.emptyBodyHashHex)
        var url = baseURL
        url.append(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }
}

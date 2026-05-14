import Foundation
import DuoPasteCore

/// 通用 HTTP 出站客户端：mesh 拓扑下每台 peer 互相通过这个跟对端通信。
/// PR 4 之前叫 HTTPIngestClient（含 push/ingest 路径），现在 push 链路已删，
/// 只剩 GET /since（PullWorker）/ GET /health / GET /blob/<sha>（lazy paste-back + eager）。
///
/// 协议适配：
/// - `SinceTransport` 在 SinceClient.swift 里 extension 实现 `/since` + `/health`
/// - `BlobFetcher` 在 SinceClient.swift 里 extension 实现 `/blob/<sha>`
///
/// 注入 URLSession 便于测试覆盖（mock URLProtocol）；生产用 .shared / AppDependencies.syncURLSession。
public struct HTTPPeerClient: Sendable {
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

    /// 从 peer 拉 blob 字节。content-addressed：本地重算 sha 校验防 MITM 字节篡改。
    /// - 返回 `.found(data)`：200，blob 字节获取成功
    /// - 返回 `.notFound`：404，peer 也没字节（image/file 历史 blob 缺失场景）
    /// - throw GetBlobError：4xx 非 404 / 5xx / 网络 / sha 校验失败。调用方判断是否重试
    public func getBlob(sha256: String) async throws -> GetBlobOutcome {
        let path = "/blob/\(sha256)"
        let ts = now()
        // GET body 为空，bodyHash = empty hash
        let sig = auth.sign(timestampMs: ts, method: "GET", path: path,
                            bodyHashHex: HMACAuth.emptyBodyHashHex)
        var url = baseURL
        url.append(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GetBlobError.transient(reason: "blob get transport: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw GetBlobError.transient(reason: "blob get non-http")
        }
        switch http.statusCode {
        case 200:
            // **必须**重算 sha 校验：content-addressed 契约要求；防 MITM 字节篡改 + 防 server
            // 实现 bug 给错 sha 的字节让客户端污染本地 BlobStore
            let actual = HMACAuth.sha256Hex(data)
            guard actual == sha256 else {
                throw GetBlobError.shaMismatch(expected: sha256, actual: actual)
            }
            return .found(data)
        case 404:
            return .notFound
        case 400, 401, 403, 422:
            let msg = String(data: data, encoding: .utf8) ?? "http \(http.statusCode)"
            throw GetBlobError.rejected(reason: msg)
        default:
            throw GetBlobError.transient(reason: "blob get http \(http.statusCode)")
        }
    }
}

public enum GetBlobOutcome: Sendable {
    case found(Data)
    case notFound
}

public enum GetBlobError: Error, CustomStringConvertible, Sendable {
    case rejected(reason: String)         // 4xx 非 404（鉴权 / 格式 / 拒绝）：重试无意义
    case transient(reason: String)        // 5xx / 网络 / 超时：可重试
    case shaMismatch(expected: String, actual: String)  // peer 返回字节 sha 不匹配——可能是 MITM 或字节流截断

    public var description: String {
        switch self {
        case .rejected(let r): return "blob fetch rejected: \(r)"
        case .transient(let r): return "blob fetch transient: \(r)"
        case .shaMismatch(let e, let a): return "blob sha mismatch: expected=\(e) actual=\(a)"
        }
    }
}

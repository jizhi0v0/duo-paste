import Foundation
import DuoPasteCore

/// PullWorker 用的传输抽象。让 PullWorker 只依赖最小契约，测试可注入 fake。
///
/// 两个方法：
/// - `fetchSince` — 增量拉一页
/// - `fetchPrimaryHealth` — 拿对端 peer 的 device_id（用于检测 peer 是否换了 →
///   清空 mirror 重拉，详见 PullWorker.swift）
public protocol SinceTransport: Sendable {
    func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult
    func fetchPrimaryHealth() async throws -> PrimaryHealthResult
}

/// PullWorker eager_blobs + paste-back lazy 路径用的最小依赖。生产由 HTTPPeerClient 实现
/// （`getBlob` 在 BlobClient.swift），测试可独立 mock。
public protocol BlobFetcher: Sendable {
    func getBlob(sha256: String) async throws -> GetBlobOutcome
}

public struct RemoteSinceResult: Sendable {
    public enum Outcome: Sendable {
        case ok(SincePageWire)
        case unreachable(reason: String)
        case rejected(reason: String)
    }
    public let outcome: Outcome
    public init(outcome: Outcome) { self.outcome = outcome }
}

public struct PrimaryHealthResult: Sendable {
    public enum Outcome: Sendable {
        /// `ponteHost` = 对端 daemon 通过 SurgePonte 自动发现的本机 `.sgponte` 主机名。
        /// 老 peer / 没装 Surge 的 peer 返回 nil。SmartTransport 用它作 ponte URL candidate
        case ok(deviceID: String, nowMs: Int64, ponteHost: String?)
        case unreachable(reason: String)
        case rejected(reason: String)
    }
    public let outcome: Outcome
    public init(outcome: Outcome) { self.outcome = outcome }
}

/// `/health` 响应的 wire 形态。注意 `now_ms` 服务端写成字符串（Server.swift），
/// 这里宽容地两种都接：String → Int64 / Int → Int64。
/// `ponte_host` 是后加字段，老 daemon 不返回，decode optional 兼容
private struct HealthResponse: Codable {
    let ok: String?    // "true" / "false"，字符串
    let deviceID: String
    let nowMs: Int64
    let ponteHost: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case deviceID = "device_id"
        case nowMs = "now_ms"
        case ponteHost = "ponte_host"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = try c.decodeIfPresent(String.self, forKey: .ok)
        self.deviceID = try c.decode(String.self, forKey: .deviceID)
        self.ponteHost = try c.decodeIfPresent(String.self, forKey: .ponteHost)
        if let s = try? c.decode(String.self, forKey: .nowMs), let n = Int64(s) {
            self.nowMs = n
        } else if let n = try? c.decode(Int64.self, forKey: .nowMs) {
            self.nowMs = n
        } else if let d = try? c.decode(Double.self, forKey: .nowMs) {
            // 保险：JSON formatter 把整数写成 1.7e18 这类 → 接受 Double 截断为 Int64
            self.nowMs = Int64(d)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .nowMs, in: c, debugDescription: "now_ms 非 Int64 / 数字字符串")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(ok, forKey: .ok)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(String(nowMs), forKey: .nowMs)
        try c.encodeIfPresent(ponteHost, forKey: .ponteHost)
    }
}

// HTTPPeerClient 已经在 PushClient.swift 实现 getBlob——这里仅声明 protocol 一致
extension HTTPPeerClient: BlobFetcher {}

extension HTTPPeerClient: SinceTransport {
    public func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        // 拼 query。空 cursor (.zero) 时也显式写 cursor_ns=0 / cursor_id=""——
        // 让签名 path 跟 client 的实际行为完全 deterministic。
        let qi: [URLQueryItem] = [
            .init(name: "cursor_ns", value: String(cursor.ingestedAtNs)),
            .init(name: "cursor_id", value: cursor.id),
            .init(name: "limit", value: String(limit)),
        ]

        var full = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = baseURL.path.isEmpty ? "" : baseURL.path
        full.path = basePath + "/since"
        full.queryItems = qi

        // 签名的 path 包含 query string——走 HMACAuth.canonicalPath 跟服务端 middleware
        // 共用同一份拼接逻辑，杜绝 encoding 漂移
        var sigComp = URLComponents()
        sigComp.path = "/since"
        sigComp.queryItems = qi
        let signedPath = HMACAuth.canonicalPath("/since", query: sigComp.percentEncodedQuery)

        let ts = now()
        let sig = auth.sign(timestampMs: ts, method: "GET", path: signedPath,
                            bodyHashHex: HMACAuth.emptyBodyHashHex)
        guard let url = full.url else {
            return RemoteSinceResult(outcome: .rejected(reason: "无法构造 /since URL"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw CancellationError()
        } catch {
            return RemoteSinceResult(outcome: .unreachable(reason: "transport: \(error.localizedDescription)"))
        }
        guard let http = response as? HTTPURLResponse else {
            return RemoteSinceResult(outcome: .unreachable(reason: "non-http"))
        }
        switch http.statusCode {
        case 200...299:
            do {
                let page = try JSONDecoder().decode(SincePageWire.self, from: data)
                return RemoteSinceResult(outcome: .ok(page))
            } catch {
                return RemoteSinceResult(outcome: .unreachable(reason: "decode: \(error)"))
            }
        case 400, 401, 403, 404, 422:
            let msg = String(data: data, encoding: .utf8) ?? "http \(http.statusCode)"
            return RemoteSinceResult(outcome: .rejected(reason: msg))
        default:
            return RemoteSinceResult(outcome: .unreachable(reason: "http \(http.statusCode)"))
        }
    }

    public func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        var url = baseURL
        url.append(path: "/health")
        let ts = now()
        let sig = auth.sign(timestampMs: ts, method: "GET", path: "/health",
                            bodyHashHex: HMACAuth.emptyBodyHashHex)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw CancellationError()
        } catch {
            return PrimaryHealthResult(outcome: .unreachable(reason: "transport: \(error.localizedDescription)"))
        }
        guard let http = response as? HTTPURLResponse else {
            return PrimaryHealthResult(outcome: .unreachable(reason: "non-http"))
        }
        switch http.statusCode {
        case 200...299:
            do {
                let h = try JSONDecoder().decode(HealthResponse.self, from: data)
                return PrimaryHealthResult(outcome: .ok(deviceID: h.deviceID, nowMs: h.nowMs, ponteHost: h.ponteHost))
            } catch {
                return PrimaryHealthResult(outcome: .unreachable(reason: "decode: \(error)"))
            }
        case 400, 401, 403, 404, 422:
            let msg = String(data: data, encoding: .utf8) ?? "http \(http.statusCode)"
            return PrimaryHealthResult(outcome: .rejected(reason: msg))
        default:
            return PrimaryHealthResult(outcome: .unreachable(reason: "http \(http.statusCode)"))
        }
    }
}

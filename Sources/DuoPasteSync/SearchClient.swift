import Foundation
import DuoPasteCore

/// 远端搜索的传输抽象——与 IngestTransport 独立，方便 UI 端只依赖搜索能力，
/// 不绑定 push 实现。生产由 HTTPIngestClient 同时实现两个协议。
public protocol SearchTransport: Sendable {
    func searchRemote(_ query: SearchQuery) async throws -> RemoteSearchResult
}

public struct RemoteSearchResult: Sendable {
    public enum Outcome: Sendable {
        case ok([SearchHit])
        case unreachable(reason: String)    // 网络 / 5xx：可降级本地
        case rejected(reason: String)       // 4xx / 401：配置错或签名错，本地降级 + UI 提示
    }
    public let outcome: Outcome
    public init(outcome: Outcome) { self.outcome = outcome }
}

/// 远端 /search 响应里每条结果：Item + 可选 snippet（仅 q 非空时填）。
public struct SearchHit: Sendable {
    public let item: Item
    public let snippet: String?
    public init(item: Item, snippet: String?) {
        self.item = item
        self.snippet = snippet
    }
}

extension HTTPIngestClient: SearchTransport {
    public func searchRemote(_ query: SearchQuery) async throws -> RemoteSearchResult {
        var components = URLComponents()
        components.path = "/search"
        var qi: [URLQueryItem] = []
        if let t = query.text, !t.isEmpty { qi.append(.init(name: "q", value: t)) }
        if let f = query.fromNs           { qi.append(.init(name: "from_ns", value: String(f))) }
        if let t = query.toNs             { qi.append(.init(name: "to_ns", value: String(t))) }
        if !query.kinds.isEmpty {
            qi.append(.init(name: "kinds", value: query.kinds.map { $0.rawValue }.joined(separator: ",")))
        }
        if query.pinnedOnly { qi.append(.init(name: "pinned", value: "1")) }
        qi.append(.init(name: "limit", value: String(query.limit)))
        qi.append(.init(name: "offset", value: String(query.offset)))
        components.queryItems = qi

        let pathWithQuery = (components.path) + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        let ts = now()
        let sig = auth.sign(
            timestampMs: ts, method: "GET", path: pathWithQuery,
            bodyHashHex: HMACAuth.emptyBodyHashHex
        )

        // 构造完整 URL
        var full = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        full.path = (baseURL.path.isEmpty ? "" : baseURL.path) + components.path
        full.queryItems = qi
        guard let url = full.url else {
            return RemoteSearchResult(outcome: .rejected(reason: "无法构造 URL"))
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
            // SwiftUI .task(id:) 用户打字时会 cancel 上一次 refresh——
            // 这是正常流程，必须传上去让 AppState.refresh 的 catch 静默吃掉，
            // 不能当 unreachable 触发本地降级（否则会显示 "primary 离线" 假阳性）
            throw CancellationError()
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw CancellationError()
        } catch {
            return RemoteSearchResult(outcome: .unreachable(reason: "transport: \(error.localizedDescription)"))
        }
        guard let http = response as? HTTPURLResponse else {
            return RemoteSearchResult(outcome: .unreachable(reason: "non-http"))
        }
        switch http.statusCode {
        case 200...299:
            do {
                let parsed = try JSONDecoder().decode(SearchResponse.self, from: data)
                let hits = parsed.items.map { wire -> SearchHit in
                    SearchHit(item: wire.item, snippet: wire.snippet)
                }
                return RemoteSearchResult(outcome: .ok(hits))
            } catch {
                // 响应解析失败当 unreachable——可能服务端版本不兼容
                return RemoteSearchResult(outcome: .unreachable(reason: "decode: \(error)"))
            }
        case 400, 401, 403, 404, 422:
            let msg = String(data: data, encoding: .utf8) ?? "http \(http.statusCode)"
            return RemoteSearchResult(outcome: .rejected(reason: msg))
        default:
            return RemoteSearchResult(outcome: .unreachable(reason: "http \(http.statusCode)"))
        }
    }
}

/// 服务端 /search 响应结构。每个 item 是 Item 的字段拼上可选 `snippet`——
/// 用嵌套 decoder 把 snippet 拆出来，剩下交给 Item.Codable 解。
private struct SearchResponse: Codable {
    let ok: Bool
    let count: Int
    let items: [Wire]

    struct Wire: Codable {
        let item: Item
        let snippet: String?

        init(from decoder: Decoder) throws {
            self.item = try Item(from: decoder)
            let c = try decoder.container(keyedBy: SnippetKey.self)
            self.snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
        }
        func encode(to encoder: Encoder) throws {
            try item.encode(to: encoder)
            if let snippet {
                var c = encoder.container(keyedBy: SnippetKey.self)
                try c.encode(snippet, forKey: .snippet)
            }
        }
        enum SnippetKey: String, CodingKey { case snippet }
    }
}

/// 选择层：根据 transport 是否存在 + 健康状态，决定打远端还是本地。
/// AppState 调 `search(_:)`，它返回结果 + 当前使用的模式（用于 UI banner）。
public struct SearchProvider: Sendable {
    public enum Mode: Sendable, Equatable {
        case local
        case remoteOK
        case remoteFallback(reason: String)
    }

    public struct Outcome: Sendable {
        public let items: [Item]
        public let mode: Mode
        /// `id → snippet`，仅 query.text 非空时填；query 为空时为空 map。
        /// snippet 含 STX/ETX 标记包围匹配词，UI 端切片渲染加粗。
        public let snippets: [String: String]

        public init(items: [Item], mode: Mode, snippets: [String: String] = [:]) {
            self.items = items
            self.mode = mode
            self.snippets = snippets
        }
    }

    public let local: SearchAPI
    public let remote: SearchTransport?

    public init(local: SearchAPI, remote: SearchTransport?) {
        self.local = local
        self.remote = remote
    }

    public func search(_ query: SearchQuery) async throws -> Outcome {
        // 无 remote → 直接本地（standalone / pure-primary）
        guard let remote else {
            let items = try local.search(query)
            let snippets = (try? local.snippets(forItemIDs: items.map(\.id), query: query)) ?? [:]
            return Outcome(items: items, mode: .local, snippets: snippets)
        }
        // 有 remote → 尝试远端。注意用 try await（不是 try?）让 CancellationError
        // 透传——上层 AppState.refresh 已经有 catch is CancellationError 处理，
        // 不应该被这里当 unreachable 误降级。
        let result = try await remote.searchRemote(query)
        switch result.outcome {
        case .ok(let hits):
            return Outcome(
                items: hits.map(\.item),
                mode: .remoteOK,
                snippets: Dictionary(uniqueKeysWithValues: hits.compactMap { h in
                    h.snippet.map { (h.item.id, $0) }
                })
            )
        case .unreachable(let reason), .rejected(let reason):
            // 真不可达 / 拒收时才降级到本地——保证可用性优先
            let items = try local.search(query)
            let snippets = (try? local.snippets(forItemIDs: items.map(\.id), query: query)) ?? [:]
            return Outcome(
                items: items,
                mode: .remoteFallback(reason: reason),
                snippets: snippets
            )
        }
    }
}

import Foundation
import DuoPasteCore

/// 远端搜索的传输抽象——与 IngestTransport 独立，方便 UI 端只依赖搜索能力，
/// 不绑定 push 实现。生产由 HTTPPeerClient 同时实现两个协议。
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

extension HTTPPeerClient: SearchTransport {
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

/// 选择层：根据 transport / mirror 状态决定打远端、本机 union 本地、还是仅本机 origin。
/// AppState 调 `search(_:)`，它返回结果 + 当前使用的模式（用于 UI banner）。
public struct SearchProvider: Sendable {
    public enum Mode: Sendable, Equatable {
        case local                                // standalone / pure-primary：纯本机 item
        case localMirror(stalenessSec: Int)       // pull worker 跑通过：本机 item + item_mirror union
        case remoteOK                             // 远端命中：UI 不显 banner
        case remoteFallback(reason: String)       // 远端配了但失败：本机降级 + banner
    }

    public struct Outcome: Sendable {
        public let items: [Item]
        public let mode: Mode
        /// `id → snippet`，仅 query.text 非空时填；query 为空时为空 map。
        /// snippet 含 STX/ETX 标记包围匹配词，UI 端切片渲染加粗。
        public let snippets: [String: String]
        /// 当前 query 条件下匹配的真实总数（忽略 limit）。
        /// - 空 query → 库（或 union 后）里的全部条数
        /// - 有 query → FTS 命中总数
        /// UI 显示这个值，**不是** `items.count`——后者被 limit 截断。
        public let totalCount: Int
        /// 按 kind 分桶的命中数。**忽略** `query.kinds`——chip 上挂 "图片 19" 时
        /// 显示的是"如果只选这个 kind 会有多少"，跟当前已选 chip 集合无关。
        /// `.remoteOK` 路径返回空字典：hits 来自远端，本地局部子集算出的数字会跟
        /// 用户点击后的 list 矛盾；transient 状态下宁可不显示 count。
        public let kindCounts: [ItemKind: Int]

        public init(
            items: [Item],
            mode: Mode,
            snippets: [String: String] = [:],
            totalCount: Int = 0,
            kindCounts: [ItemKind: Int] = [:]
        ) {
            self.items = items
            self.mode = mode
            self.snippets = snippets
            self.totalCount = totalCount
            self.kindCounts = kindCounts
        }
    }

    public let local: SearchAPI
    public let remote: SearchTransport?
    /// 闭包返回上次成功完整拉取的 wall-clock ns；非 nil → mirror 可用，走 union 路径。
    /// 注入 closure 而不是 MirrorStatus 直引用，便于测试 + 解耦层级。
    public let mirrorLastPullNs: @Sendable () -> Int64?
    /// 用来算 staleness 的 now。生产用 `Clock.nowNs`；测试可注入固定值。
    public let nowNs: @Sendable () -> Int64

    public init(
        local: SearchAPI,
        remote: SearchTransport?,
        mirrorLastPullNs: @escaping @Sendable () -> Int64? = { nil },
        nowNs: @escaping @Sendable () -> Int64 = { Clock.nowNs() }
    ) {
        self.local = local
        self.remote = remote
        self.mirrorLastPullNs = mirrorLastPullNs
        self.nowNs = nowNs
    }

    public func search(_ query: SearchQuery) async throws -> Outcome {
        // 1. Mirror 已就位（pull worker 至少完成过一轮严格追平）→ 直接 union 本地，**不打**远端。
        //    这是第二刀的核心收益：每次按键不再过 Tailscale。
        if let last = mirrorLastPullNs() {
            let staleness = Int(max(0, (nowNs() - last) / 1_000_000_000))
            return unionLocalOutcome(query: query, stalenessSec: staleness)
        }
        // 2. 无 remote → 纯本地（standalone / pure-primary）
        guard let remote else {
            return localOutcome(query: query, mode: .local)
        }
        // 3. 有 remote → 尝试远端。注意用 try await（不是 try?）让 CancellationError
        // 透传——上层 AppState.refresh 已经有 catch is CancellationError 处理，
        // 不应该被这里当 unreachable 误降级。
        let result = try await remote.searchRemote(query)
        switch result.outcome {
        case .ok(let hits):
            // 远端 transport 当前不返回 total / kindCounts（协议未扩字段）。本地 count 作 close
            // 兜底——常见部署里 client 一旦 mirror 就绪就不走 remoteOK，此路径只是 transient 状态。
            //
            // kindCounts **不**用本地算：hits 来自远端全集，本地 own/mirror 只是局部子集，
            // 两者数字会矛盾——chip 显示 "图片 (200)" 但点 image 后 remote 重打返回 0
            // （远端实际不含 image 命中）。Transient 状态下宁可不显示 count（UI 端 nil
            // → 隐藏），等 mirror 追平走 localMirror 路径再有正确数字。
            // 远端协议扩字段后这里可以从响应填，但 nil 也是有效降级路径。
            let total = (try? local.count(query)) ?? hits.count
            return Outcome(
                items: hits.map(\.item),
                mode: .remoteOK,
                snippets: Dictionary(uniqueKeysWithValues: hits.compactMap { h in
                    h.snippet.map { (h.item.id, $0) }
                }),
                totalCount: total,
                kindCounts: [:]
            )
        case .unreachable(let reason), .rejected(let reason):
            // 真不可达 / 拒收时才降级到本地——保证可用性优先
            return localOutcome(query: query, mode: .remoteFallback(reason: reason))
        }
    }

    private func localOutcome(query: SearchQuery, mode: Mode) -> Outcome {
        // 一次 SQL 同时拿 items + snippets——比之前 search() + snippets() 两次查询快一倍
        let hits = (try? local.searchHits(query)) ?? []
        let snippets = Dictionary(uniqueKeysWithValues: hits.compactMap { (item, s) in
            s.map { (item.id, $0) }
        })
        let total = (try? local.count(query)) ?? hits.count
        let raw = (try? local.countByKind(query)) ?? [:]
        return Outcome(
            items: hits.map(\.0),
            mode: mode,
            snippets: snippets,
            totalCount: total,
            kindCounts: Self.normalizeKindCounts(raw)
        )
    }

    private func unionLocalOutcome(query: SearchQuery, stalenessSec: Int) -> Outcome {
        let hits = (try? local.searchUnion(query)) ?? []
        let snippets = Dictionary(uniqueKeysWithValues: hits.compactMap { (item, s) in
            s.map { (item.id, $0) }
        })
        let total = (try? local.countUnion(query)) ?? hits.count
        let raw = (try? local.countByKindUnion(query)) ?? [:]
        return Outcome(
            items: hits.map(\.0),
            mode: .localMirror(stalenessSec: stalenessSec),
            snippets: snippets,
            totalCount: total,
            kindCounts: Self.normalizeKindCounts(raw)
        )
    }

    /// 本地 / unionLocal 路径下，把 `countByKind*` 返回的稀疏 dict 补全为「所有 ItemKind 都有 entry，
    /// 缺的填 0」。这样 caller 能用 `kindCounts.isEmpty` 区分：
    /// - 空 dict（remoteOK / 出错降级）→ unknown，UI 隐藏数字
    /// - 非空 dict（本地命中或本地全空）→ 已知，缺 kind 渲染为 "图片 0"
    ///
    /// 不这样补的话：本地搜索 0 命中场景 kindCounts 也是空 dict，跟 remoteOK 撞同一种 nil 渲染，
    /// KindChip 头注释 "0 也显示，避免误判 filter 失效" 的意图就 break（codex review P2 #2）。
    static func normalizeKindCounts(_ raw: [ItemKind: Int]) -> [ItemKind: Int] {
        var out = raw
        for k in ItemKind.allCases where out[k] == nil {
            out[k] = 0
        }
        return out
    }
}

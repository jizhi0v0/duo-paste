import Foundation
import DuoPasteCore

/// 搜索选择层。Mesh 拓扑下 item 表是单表混存 own + peer，永远走本机 fold-aware
/// （`SearchAPI.search / count / countByKind` 内部 text-fold）。AppState 调 `search(_:)`
/// 拿结果 + 当前 mode（用于 UI banner）。
///
/// PR 6 之前还有 `.remoteOK / .remoteFallback / .localMirror` 等 mode + 一条远端
/// `/search` 路径，给老 client/primary 拓扑用。Mesh 重构后 item 表本身就是全集，
/// 没有"本地子集 vs 远端全集"的差异，远端 path 整段删——chip 总数永远靠本机算
/// 跟对端永远口径一致。
public struct SearchProvider: Sendable {
    public enum Mode: Sendable, Equatable {
        /// Standalone / 还没收到对端任何 peer 行的初始态——本机 item 表是全集。
        case local
        /// Mesh peer 模式：item 表混本机 own + 对端 peer 行。`stalenessSec` 是
        /// `now - 最旧 peer 的 lastPullNs`，nil 表示不知道（没启 PullWorker / 还没 tick 过）。
        /// UI banner 用这个值显示"mesh · X 秒前同步"
        case mesh(stalenessSec: Int?)
    }

    public struct Outcome: Sendable {
        public let items: [Item]
        public let mode: Mode
        /// `id → snippet`，仅 query.text 非空时填；query 为空时为空 map。
        /// snippet 含 STX/ETX 标记包围匹配词，UI 端切片渲染加粗。
        public let snippets: [String: String]
        /// 当前 query 条件下匹配的真实总数（fold 后，跟 chip / list 三者口径一致）。
        /// UI 显示这个值，**不是** `items.count`——后者被 limit 截断。
        public let totalCount: Int
        /// 按 kind 分桶的 fold 后命中数。**忽略** `query.kinds`——chip 上挂 "图片 19" 时
        /// 显示的是"如果只选这个 kind 会有多少"，跟当前已选 chip 集合无关。
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
    /// 闭包返回所有 peer 中**最旧**的 lastPullNs（最悲观）；nil = 还没追平任何 peer
    /// （standalone / 还没启 PullWorker / 首次启动未跑过 tick）。生产从 MeshStatus.oldestLastPullNs 注入
    public let oldestPeerLastPullNs: @Sendable () -> Int64?
    /// 用来算 staleness 的 now。生产用 `Clock.nowNs`；测试可注入固定值。
    public let nowNs: @Sendable () -> Int64

    public init(
        local: SearchAPI,
        oldestPeerLastPullNs: @escaping @Sendable () -> Int64? = { nil },
        nowNs: @escaping @Sendable () -> Int64 = { Clock.nowNs() }
    ) {
        self.local = local
        self.oldestPeerLastPullNs = oldestPeerLastPullNs
        self.nowNs = nowNs
    }

    /// 同步搜索。Mesh 拓扑下 item 表是全集，本机 fold-aware 算就够了——`async` 只为
    /// 跟 SwiftUI `.task(id:)` 调用点接口稳定保留（删 remote 后没有真 await，但不强制
    /// 改 sync 让 AppState 改一片）。
    public func search(_ query: SearchQuery) async throws -> Outcome {
        let last = oldestPeerLastPullNs()
        let mode: Mode = last.map { .mesh(stalenessSec: Int(max(0, (nowNs() - $0) / 1_000_000_000))) }
            ?? .local
        return foldOutcome(query: query, mode: mode)
    }

    private func foldOutcome(query: SearchQuery, mode: Mode) -> Outcome {
        // 一次 SQL 拿 items + snippets，count / countByKind 走同源 fold 路径——
        // list / total / chip 三者口径一致是 plan §"Search 改动"的硬不变量
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

    /// 把 `countByKind` 返回的稀疏 dict 补全为「所有 ItemKind 都有 entry，缺的填 0」。
    /// KindChip 头注释要求"0 也显示，避免误判 filter 失效"，靠这条不变量保证
    /// `kindCounts.isEmpty == false`（命中 0 时也是非空 dict 全 0）
    static func normalizeKindCounts(_ raw: [ItemKind: Int]) -> [ItemKind: Int] {
        var out = raw
        for k in ItemKind.allCases where out[k] == nil {
            out[k] = 0
        }
        return out
    }
}

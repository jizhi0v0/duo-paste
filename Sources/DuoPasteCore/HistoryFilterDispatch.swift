import Foundation

/// iOS `HistoryStore.filtered` 的纯 dispatch 逻辑——从 UI / SwiftUI / @Observable 路径解耦
/// 出来,在 DuoPasteCore 单测覆盖四条分支契约。Server / Mac 端不调用本模块.
///
/// **契约**(跟 issue #42 列的四条分支对齐):
/// 1. `query.isEmpty && qualifiers.isEmpty` → `Item.foldByTextFull` 展示 dedup + iOS list 排序
/// 2. `query.isEmpty && !qualifiers.isEmpty` → 先 qualifier filter,后 fold + 排序
/// 3. `!query.isEmpty && lastServerSearch.q == query && lastServerSearch.qualifiers == qualifiers` →
///    server items 已 fold + 已 sort + **已按 qualifier filter**(server #41 透传),
///    **不再 fold 不再 sort 不再 client-side qualifier filter**。
///    **qualifier strict 比对**(review #48 Minor 1):server cache 命中必须 qualifier 集合
///    完全一致;不一致 → cache stale(server 收窄过的 items 跟当前 chip 不匹配),回退到
///    branch 4 contains fallback 直到新一轮 /search 返回。否则 chip toggle 250ms 窗口内
///    会用 server-收窄过 items + 更宽 client-side filter → 显示比"应该出现"少 → 闪烁
/// 4. `!query.isEmpty && (server miss / q stale / qualifiers stale)` → contains fallback +
///    qualifier filter,然后 fold + 排序
///
/// **为什么不放在 HistoryStore**:`HistoryStore` 是 `@MainActor @Observable`,跟 SwiftUI
/// runtime 强耦合,DuoPasteCoreTests 拉不进去单测;dispatch 逻辑本身纯数据 in / 纯数据 out,
/// 抽到 DuoPasteCore 让 4 条分支契约直接单测覆盖,改 dispatch 时单测先 fail.
///
/// Fold / 排序契约定义在 `Item.foldByTextFull` + `HistoryFilterDispatch.iosListOrder`
/// 单点,避免 Mac / iOS 两端漂移.
public enum HistoryFilterDispatch {
    /// 已 cache 的 server `/search` 结果——`q` + `qualifiers` 是当时发的 query 状态,
    /// 跟当前 store.query / activeQualifiers 联合比对决定是否复用。该结构是 dispatch
    /// 的纯入参,不依赖 SwiftUI / Observable.
    ///
    /// **为什么 qualifiers 也要 snapshot**(review #48 Minor 1):server #41 已经按 qualifier
    /// 收窄过返回 items;chip toggle 后 onChange 250ms debounce 才发新请求,这段窗口内
    /// 若仅按 `q` 命中 cache,旧 cache items 跟新 qualifier 集合不匹配,UI 会闪
    public struct ServerSearchContext: Equatable, Sendable {
        public let q: String
        public let qualifiers: Set<QueryQualifier>
        public let items: [Item]

        public init(q: String, qualifiers: Set<QueryQualifier>, items: [Item]) {
            self.q = q
            self.qualifiers = qualifiers
            self.items = items
        }
    }

    /// 计算最终展示列表. 纯函数, 无副作用. 调用方(iOS HistoryStore.filtered)直接返结果给 UI
    ///
    /// - Parameters:
    ///   - items: 本机 in-memory 全集(从 /since pull 拿到的 + 用户乐观操作过的)
    ///   - query: 搜索框文本(已 debounce)
    ///   - lastServerSearch: 最近一次 server /search 返回结果,nil 表示没 cache 或刚清掉
    ///   - qualifiers: 用户已激活的 slash qualifier chip(OR 语义),空集合等于不过滤
    /// - Returns: 已 fold + 已排序的展示列表(server 命中分支保留 server 顺序)
    public static func dispatch(
        items: [Item],
        query: String,
        lastServerSearch: ServerSearchContext?,
        qualifiers: [QueryQualifier]
    ) -> [Item] {
        // Branch 1: 空 query + 空 qualifier → 全列表 fold + sort
        if query.isEmpty && qualifiers.isEmpty {
            return foldAndSort(items)
        }

        // Branch 2: 空 query + 有 qualifier → items filter qualifier 后 fold + sort
        if query.isEmpty {
            return foldAndSort(items.filter { QueryQualifier.matches($0, qualifiers: qualifiers) })
        }

        // Branch 3: query 非空且命中 cached server search(q + qualifier snapshot 双匹配)→
        // 用 server fold-aware items,保留 server 顺序(含 prefix24h boost)。
        // server #41 已按 qualifier filter 过,client-side filter 是 idempotent no-op
        // (qualifier 匹配的语义在两端同源 `QueryQualifier.matches`),仍保留作为老 server
        // 兜底——若 cache.qualifiers 非空但 items 含不匹配项(理论上不应该,纵深防御)
        if let cache = lastServerSearch, cache.q == query, cache.qualifiers == Set(qualifiers) {
            if qualifiers.isEmpty { return cache.items }
            return cache.items.filter { QueryQualifier.matches($0, qualifiers: qualifiers) }
        }

        // Branch 4: query 非空且无 cached server(或 q/qualifier 不匹配)→ contains fallback + qualifier + fold + sort
        let q = query.lowercased()
        let contained = items.filter { item in
            (item.preview?.lowercased().contains(q) ?? false)
                || (item.textFull?.lowercased().contains(q) ?? false)
                || (item.extractedText?.lowercased().contains(q) ?? false)
        }
        let qFiltered = qualifiers.isEmpty
            ? contained
            : contained.filter { QueryQualifier.matches($0, qualifiers: qualifiers) }
        return foldAndSort(qFiltered)
    }

    /// fold + iOS list 排序契约一体应用. fold 走 `Item.foldByTextFull` 单点契约,
    /// sort 本地化(Mac 跟 iOS 排序契约不同,Mac 多 prefix24h boost——见 `dispatch` 文档).
    public static func foldAndSort(_ list: [Item]) -> [Item] {
        Item.foldByTextFull(list).sorted(by: iosListOrder)
    }

    /// iOS 列表排序契约 — pinned DESC, captured_at_ns DESC.
    /// 单点定义避免多处 sort 闭包重复 + 漂移; Mac 端走 `Search.fetchHitsFolded` 自己的契约
    /// (pinned > prefix24h > captured_at_ns) 不调本函数.
    public static func iosListOrder(_ a: Item, _ b: Item) -> Bool {
        if a.pinned != b.pinned { return a.pinned && !b.pinned }
        return a.capturedAtNs > b.capturedAtNs
    }
}

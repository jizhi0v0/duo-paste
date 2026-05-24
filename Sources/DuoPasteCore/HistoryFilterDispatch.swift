import Foundation

/// iOS `HistoryStore.filtered` 的纯 dispatch 逻辑——从 UI / SwiftUI / @Observable 路径解耦
/// 出来,在 DuoPasteCore 单测覆盖四条分支契约。Server / Mac 端不调用本模块.
///
/// **契约**(跟 issue #42 列的四条分支对齐):
/// 1. `query.isEmpty && qualifiers.isEmpty` → `Item.foldByTextFull` + iOS list 排序
/// 2. `query.isEmpty && !qualifiers.isEmpty` → 先 qualifier filter,后 fold + 排序
/// 3. `!query.isEmpty && lastServerSearch.q == query` →
///    server items 已 fold + 已 sort(含 prefix24h boost),**不再 fold 不再 sort**.
///    qualifier 非空时仅做 client-side filter(server 不识别 slash qualifier),
///    **保留 server 顺序**——iosListOrder 会丢 prefix boost,让用户感觉勾 chip 后卡片
///    顺序"突然变样"(回归测试 PR#40 review #2)
/// 4. `!query.isEmpty && (server miss or stale)` → contains fallback + qualifier filter,
///    然后 fold + 排序
///
/// **为什么不放在 HistoryStore**:`HistoryStore` 是 `@MainActor @Observable`,跟 SwiftUI
/// runtime 强耦合,DuoPasteCoreTests 拉不进去单测;dispatch 逻辑本身纯数据 in / 纯数据 out,
/// 抽到 DuoPasteCore 让 4 条分支契约直接单测覆盖,改 dispatch 时单测先 fail.
///
/// Fold / 排序契约定义在 `Item.foldByTextFull` + `HistoryFilterDispatch.iosListOrder`
/// 单点,避免 Mac / iOS 两端漂移.
public enum HistoryFilterDispatch {
    /// 已 cache 的 server `/search` 结果——`q` 字段是当时发的 query,跟当前 store.query
    /// 比对决定是否复用. 该结构是 dispatch 的纯入参,不依赖 SwiftUI / Observable
    public struct ServerSearchContext: Equatable, Sendable {
        public let q: String
        public let items: [Item]

        public init(q: String, items: [Item]) {
            self.q = q
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

        // Branch 3: query 非空且命中 cached server search → 用 server fold-aware items,
        // 保留 server 顺序(含 prefix24h boost). qualifier 仅 client-side filter,不再 fold + sort
        if let cache = lastServerSearch, cache.q == query {
            if qualifiers.isEmpty { return cache.items }
            return cache.items.filter { QueryQualifier.matches($0, qualifiers: qualifiers) }
        }

        // Branch 4: query 非空且无 cached server(或 q 不匹配)→ contains fallback + qualifier + fold + sort
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

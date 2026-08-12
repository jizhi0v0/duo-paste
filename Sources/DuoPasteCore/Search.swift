import Foundation
import GRDB

/// `GET /search` 响应的 wire 形态。iOS client `JSONDecoder().decode(SearchPageWire.self, ...)`
/// 解。`items` 用自定义 `SearchHitWire`——每条同时含 Item 完整字段 + 可选 `snippet`
/// (FTS5 高亮片段,STX/ETX 包围匹配词)。**Codable 复用**:Item 已经 Codable,wire 字段
/// 直接对应 JSON 顶层(handler 走 itemToJSON 把 Item dict 跟 snippet 并平铺)
public struct SearchPageWire: Decodable, Sendable {
    public let ok: Bool
    /// **qualifier-filtered + fold 后的总数**(issue #41 之后语义校准):server 端走
    /// `searchHitsAndCount` 单次 fold-aware pass,先 FTS5 命中 → 跨 origin fold → 按
    /// `kinds` / `file_sub_kinds` / `text_suffixes` qualifier filter,然后 limit/offset 切页。
    /// `count` 是 **filter 之后、limit 之前** 的真实总数,跟 `items.count` 关系:
    /// `items.count = min(count, limit)`。UI 显"共 N 条"直接用本字段,跟 Mac chip 总数对齐
    public let count: Int
    public let items: [SearchHitWire]

    public init(ok: Bool, count: Int, items: [SearchHitWire]) {
        self.ok = ok
        self.count = count
        self.items = items
    }
}

/// 单条 /search hit。Item 字段平铺 + 可选 snippet。Item 直接走自身 Codable 解 Decoder,
/// snippet 通过同一份 container 旁路取出
public struct SearchHitWire: Decodable, Sendable {
    public let item: Item
    public let snippet: String?

    public init(item: Item, snippet: String?) {
        self.item = item
        self.snippet = snippet
    }

    private enum SnippetCodingKeys: String, CodingKey {
        case snippet
    }

    public init(from decoder: Decoder) throws {
        self.item = try Item(from: decoder)
        let c = try decoder.container(keyedBy: SnippetCodingKeys.self)
        self.snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
    }
}

public struct SearchQuery: Sendable, Equatable {
    public var text: String?
    public var fromNs: Int64?
    public var toNs: Int64?
    public var kinds: [ItemKind]
    /// `.file` kind 的虚拟 sub-kind 过滤(视频/PDF/音频/图片文件)。语义上跟 `kinds`
    /// **OR 关系**——`kinds=[.text]` + `fileSubKinds=[.video]` 命中文本 OR 视频文件
    public var fileSubKinds: [FileSubKind]
    /// 文件扩展名后缀过滤（如 [".java", ".py"]）。跟 kinds / fileSubKinds **OR 关系**。
    /// 走 `LOWER(text_full) LIKE '%.java'`——FTS5 unicode61 tokenizer 对 `.` 不可靠，
    /// 用 LIKE 后缀匹配跟 sub-kind ext 路径同构。给 slash qualifier `/java /c /py` 用
    public var textFullSuffixes: [String]
    public var pinnedOnly: Bool
    public var includeDeleted: Bool
    public var limit: Int
    public var offset: Int

    public init(
        text: String? = nil,
        fromNs: Int64? = nil,
        toNs: Int64? = nil,
        kinds: [ItemKind] = [],
        fileSubKinds: [FileSubKind] = [],
        textFullSuffixes: [String] = [],
        pinnedOnly: Bool = false,
        includeDeleted: Bool = false,
        limit: Int = 200,
        offset: Int = 0
    ) {
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.fromNs = fromNs
        self.toNs = toNs
        self.kinds = kinds
        self.fileSubKinds = fileSubKinds
        self.textFullSuffixes = textFullSuffixes
        self.pinnedOnly = pinnedOnly
        self.includeDeleted = includeDeleted
        self.limit = limit
        self.offset = offset
    }
}

/// R4.2 一次搜索刷新所需的完整结果。list/total/facets 必须来自同一 reader snapshot 与
/// 同一 fold pass，避免 UI 四次独立全表 fold，也避免 capture 恰好插入时四个数字互相打架。
public struct SearchSummary: Sendable {
    public let hits: [(Item, String?)]
    public let totalCount: Int
    public let kindCounts: [ItemKind: Int]
    public let fileSubKindCounts: [FileSubKind: Int]

    public init(
        hits: [(Item, String?)],
        totalCount: Int,
        kindCounts: [ItemKind: Int],
        fileSubKindCounts: [FileSubKind: Int]
    ) {
        self.hits = hits
        self.totalCount = totalCount
        self.kindCounts = kindCounts
        self.fileSubKindCounts = fileSubKindCounts
    }
}

public struct SearchAPI: Sendable {
    public let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func search(_ q: SearchQuery) throws -> [Item] {
        return try database.pool.read { db in
            try Self.fetch(db, query: q)
        }
    }

    /// 匹配词高亮分隔符。STX/ETX 是 ASCII 控制字符，几乎不会出现在剪贴板真实文本里——
    /// UI 拿到字符串按这两个 marker 切片、夹在中间的部分加粗。
    public static let snippetStartMarker = "\u{02}"
    public static let snippetEndMarker   = "\u{03}"

    /// 一次 SQL 同时返回 item + FTS snippet，**fold-aware**——跨 origin 同 text_full 的行
    /// 折成一条（capture 层 dedup 只防同 origin，跨 origin 兜底靠这一层；详 CLAUDE.md
    /// "文本永久 dedup"）。snippet 仅当 query.text 非空时填；其它情况第二元素为 nil。
    /// max tokens=8：紧密围绕匹配词，SwiftUI `lineLimit(2)` 一定能显示到高亮段。
    ///
    /// PR 6 之前还有 `searchUnion` 是"fold-aware"路径、`searchHits` 是"raw"路径，mesh
    /// 拓扑下 item 表本身就混 own + peer 行，raw 路径出来的总数跟对端不齐——直接合并
    /// 成单一 fold-aware 路径，删 raw 公开 API。
    public func searchHits(_ q: SearchQuery) throws -> [(Item, String?)] {
        if Self.canUseFoldProjection(q) {
            try database.refreshSearchFoldProjection()
            return try database.pool.read { db in
                try Self.fetchProjectionHits(db, query: q)
            }
        }
        return try database.pool.read { db in
            try Self.fetchHitsFolded(db, query: q)
        }
    }

    /// 某条 item 在**空查询列表**里的位置。给"从搜索结果跳回完整列表"用:
    /// 只有知道位次,才能只拉它前后一小段而不是把整库 22k 行都拉出来。
    public struct FoldPosition: Sendable, Equatable {
        /// fold 之后真正被展示的那一行的 id。跨 origin 重复文本会被折叠,用户右键的那条
        /// 未必是展示行——定位必须落到展示行上,否则列表里根本没有这个 id
        public let displayItemID: String
        /// 0-based 位次,按空查询排序 `(pinned DESC, captured_at_ns DESC, item_id ASC)`
        public let rank: Int
    }

    /// 查 `itemID` 在当前 (chip / pinnedOnly) 条件下的空查询列表位次。
    ///
    /// 只支持 fold projection 路径(无搜索词、无自定义时间范围)——那条路的 `LIMIT/OFFSET`
    /// 是真 SQL 分页,拿到 rank 后即可只取窗口。FTS / 时间范围路径的 offset 是 Swift 端
    /// 切数组,先要构造全集,拿 rank 反而更贵,直接返回 nil 让调用方降级。
    ///
    /// 找不到(条目已删 / 被 chip 过滤掉 / 不走 projection)返回 nil。
    public func foldPosition(ofItemID itemID: String, query q: SearchQuery) throws -> FoldPosition? {
        guard Self.canUseFoldProjection(q) else { return nil }
        try database.refreshSearchFoldProjection()
        return try database.pool.read { db in
            // 1. 先把 item 映射到它所在 fold group 的展示行。group_type / group_key 完全由
            //    item 行自身决定(见 Database.searchFoldGroupKeySQL),所以能直接 JOIN 出来。
            //    blob group 会按 15s 时间窗分多个 cluster,取 captured_at 最接近的那个
            let anchorSQL = """
                SELECT f.item_id AS display_id, f.pinned AS pinned, f.captured_at_ns AS captured_at_ns
                FROM item i
                JOIN search_fold f
                  ON f.group_type = \(Database.searchFoldGroupTypeSQL(alias: "i"))
                 AND f.group_key = \(Database.searchFoldGroupKeySQL(alias: "i"))
                WHERE i.id = ?
                ORDER BY ABS(f.captured_at_ns - i.captured_at_ns) ASC
                LIMIT 1
            """
            guard let anchor = try Row.fetchOne(db, sql: anchorSQL, arguments: [itemID]) else {
                return nil
            }
            let displayID: String = anchor["display_id"]
            let pinned: Int = anchor["pinned"]
            let capturedAtNs: Int64 = anchor["captured_at_ns"]

            // 2. 数排在展示行**之前**的行数 = 它的 0-based 位次。谓词必须逐字对应
            //    fetchProjectionHits 的 ORDER BY (pinned DESC, captured_at_ns DESC, item_id ASC),
            //    否则窗口会错位
            var args: [DatabaseValueConvertible] = []
            var wheres: [String] = []
            if q.pinnedOnly { wheres.append("f.pinned = 1") }
            if let qualifier = Self.projectionQualifierPredicate(q, alias: "f", args: &args) {
                wheres.append(qualifier)
            }
            // 展示行自己被 chip 过滤掉时位次没有意义 —— 让调用方走"不在列表里"的提示
            var selfArgs = args
            var selfWheres = wheres
            selfWheres.append("f.item_id = ?")
            selfArgs.append(displayID)
            let selfSQL = "SELECT COUNT(*) FROM search_fold f WHERE " + selfWheres.joined(separator: " AND ")
            let selfCount = try Int.fetchOne(db, sql: selfSQL, arguments: StatementArguments(selfArgs)) ?? 0
            if selfCount == 0 { return nil }

            wheres.append("""
                (f.pinned > ?
                 OR (f.pinned = ? AND f.captured_at_ns > ?)
                 OR (f.pinned = ? AND f.captured_at_ns = ? AND f.item_id < ?))
            """)
            let rankArgs: [DatabaseValueConvertible] = [
                pinned, pinned, capturedAtNs, pinned, capturedAtNs, displayID
            ]
            args.append(contentsOf: rankArgs)
            let rankSQL = "SELECT COUNT(*) FROM search_fold f WHERE " + wheres.joined(separator: " AND ")
            let rank = try Int.fetchOne(db, sql: rankSQL, arguments: StatementArguments(args)) ?? 0
            return FoldPosition(displayItemID: displayID, rank: rank)
        }
    }

    /// 一次返回生产 UI 所需的 list + total + facets。
    ///
    /// - 空 query 且无时间范围：走 v16 持久化 fold projection，SQL 一次窄表聚合 + 最近页。
    /// - FTS / 自定义时间范围：只做一次无 qualifier fold，在同一数组上派生 total/facets/list。
    ///
    /// 两条路径都保持 qualifier 在 fold 后按 winner 字段过滤；chip counts 忽略 kinds /
    /// fileSubKinds 但保留 suffix 的既有语义。
    public func searchSummary(_ q: SearchQuery) throws -> SearchSummary {
        if Self.canUseFoldProjection(q) {
            try database.refreshSearchFoldProjection()
            return try database.pool.read { db in
                try Self.fetchProjectionSummary(db, query: q)
            }
        }
        return try database.pool.read { db in
            try Self.fetchFoldedSummary(db, query: q)
        }
    }

    /// 单次 fold-aware pass 同时返回 hits + total count——给"既要 list 也要 chip 总数"的
    /// 调用方(HTTP `/search` handler / SwiftUI 顶 chip)用。
    ///
    /// **性能**:跟 `searchHits + count` 分两次比起来,这里 fetchHitsFolded 只跑一次
    /// (limit=Int.max 拿全集),再 Swift 端切片到 (offset..<offset+limit) 给 hits,
    /// 全集 .count 直接当 total。10k 行 + FTS5 命中数千时省一倍 SQL+Swift fold 工。
    ///
    /// 等价性:total 跟 `count(q)` 一致(同源 fetchHitsFolded);hits 跟 `searchHits(q)`
    /// 一致(slice 顺序跟 fetchHitsFolded 内置 limit/offset 一致)。回归测试钉死
    public func searchHitsAndCount(_ q: SearchQuery) throws -> (hits: [(Item, String?)], total: Int) {
        if Self.canUseFoldProjection(q) {
            let summary = try searchSummary(q)
            return (summary.hits, summary.totalCount)
        }
        return try database.pool.read { db in
            // limit=Int.max + offset=0 → fetchHitsFolded 返回全部排序后的命中
            // (内部 needsPostFilter 时 oversample 本来就是 Int.max,所以这一改不增加开销)
            let allQuery = SearchQuery(
                text: q.text,
                fromNs: q.fromNs, toNs: q.toNs,
                kinds: q.kinds,
                fileSubKinds: q.fileSubKinds,
                textFullSuffixes: q.textFullSuffixes,
                pinnedOnly: q.pinnedOnly,
                includeDeleted: q.includeDeleted,
                limit: Int.max,
                offset: 0
            )
            let all = try Self.fetchHitsFolded(db, query: allQuery)
            let total = all.count
            let start = min(q.offset, all.count)
            let end = min(q.offset + q.limit, all.count)
            let sliced = start < end ? Array(all[start..<end]) : []
            return (sliced, total)
        }
    }

    /// Fold-aware fetch 内部实现：oversample raw（无 kinds/pinnedOnly 过滤）→ text-fold
    /// （跨 origin 同 text_full 折一条，pinned OR 聚合）→ 后置 kinds/pinnedOnly 过滤 →
    /// 排序契约：非空 query = prefix group / contains group，各组 captured DESC；
    /// 空 query = pinned DESC / captured DESC。最后再 LIMIT/OFFSET。
    static func fetchHitsFolded(_ db: GRDB.Database, query q: SearchQuery) throws -> [(Item, String?)] {
        // Exact empty-result fast path for qualifier searches. Fold can change the representative
        // row and OR pinned state, but it cannot synthesize a kind/sub-kind/suffix that no raw hit
        // has. Probing the indexed SQL predicates first avoids decoding/folding 100k rows for a
        // sparse chip that has zero matches. `pinnedOnly + qualifiers` is excluded because the pin
        // and qualifier may live on different siblings of one fold group.
        if !q.pinnedOnly,
           (!q.kinds.isEmpty || !q.fileSubKinds.isEmpty || !q.textFullSuffixes.isEmpty) {
            let probe = SearchQuery(
                text: q.text,
                fromNs: q.fromNs,
                toNs: q.toNs,
                kinds: q.kinds,
                fileSubKinds: q.fileSubKinds,
                textFullSuffixes: q.textFullSuffixes,
                pinnedOnly: false,
                includeDeleted: q.includeDeleted,
                limit: 1,
                offset: 0
            )
            if try fetchHitsRaw(db, query: probe).isEmpty { return [] }
        }
        // pinnedOnly / kinds 必须在 text-fold **之后**按 winner 行的字段过滤——fold 会做 pinned
        // OR 聚合，过滤依据必须是聚合后 winner。否则：跨 origin 同文本一边 pinned=true 一边
        // false，子查询带 `pinned=1` 过滤后只剩 pinned 那条参与 fold，winner 不变；但 list /
        // countByKindUnion 走同源 oversample 流程要保证三者口径一致。
        //
        // pinnedOnly=true 或 q.kinds 非空时 oversample 必须无界——否则按时间倒序取 limit+offset
        // 行可能全是不该出现在结果里的类型/未 pin 状态，filter 后凑不齐 q.limit。剪贴板量级
        // 万级，Swift 端 fold 几毫秒，可接受。
        let needsPostFilter = q.pinnedOnly || !q.kinds.isEmpty || !q.fileSubKinds.isEmpty || !q.textFullSuffixes.isEmpty
        let oversampleLimit = needsPostFilter ? Int.max : (q.limit + q.offset)
        let oversample = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: [], fileSubKinds: [], textFullSuffixes: [], pinnedOnly: false,
            includeDeleted: q.includeDeleted,
            limit: oversampleLimit,
            offset: 0
        )
        let raw = try fetchHitsRaw(db, query: oversample)

        // 展示 fold：文本按 text_full 永久 dedup；blob 同 sha 仅折叠近时间的
        // 跨-origin Continuity 副本，同 origin 主动重复复制仍保留时间线。
        //
        // 必须在下面的 kind/pinned 后置 filter **之前**——pinned 聚合后 winner.pinned 才是
        // 正确的过滤依据。
        //
        // **契约定义在 `Item.foldByTextFull`(DuoPasteCore)**。Mac 只在 fold 后把
        // 代表行 id 对应的 FTS snippet 接回去，不再维护第二份 fold 逻辑。
        var snippetByID: [String: String] = [:]
        for (item, snippet) in raw {
            if let snippet { snippetByID[item.id] = snippet }
        }
        var deduped = Item.foldByTextFull(raw.map(\.0)).map { item in
            (item, snippetByID[item.id])
        }

        // 按 winner 行的字段过滤——不可前置到子查询。countByKindUnion / countUnion 走同源
        // 不变量保证 chip 数字、count、list 三者口径一致。
        // kinds + fileSubKinds + textFullSuffixes 走 **OR** 关系——任一命中即保留(空 = 全保留)
        if !q.kinds.isEmpty || !q.fileSubKinds.isEmpty || !q.textFullSuffixes.isEmpty {
            let allowedKinds = Set(q.kinds)
            let subSet = Set(q.fileSubKinds)
            let suffixes = q.textFullSuffixes.map { $0.lowercased() }
            deduped = deduped.filter { hit in
                let item = hit.0
                if allowedKinds.contains(item.kind) { return true }
                if !subSet.isEmpty, item.kind == .file,
                   let sub = ItemClassifier.fileSubKind(item),
                   subSet.contains(sub) {
                    return true
                }
                if !suffixes.isEmpty, let tf = item.textFull?.lowercased(),
                   suffixes.contains(where: { tf.hasSuffix($0) }) {
                    return true
                }
                return false
            }
        }
        if q.pinnedOnly {
            deduped = deduped.filter { $0.0.pinned }
        }
        // 排序契约：
        // - 非空 query：prefix group → contains group，每组 captured_at_ns DESC；pin 不参与
        // - 空 query：pinned DESC → captured_at_ns DESC
        // preview / text_full 的前缀属于同一个 relevance tier，不再细分 2/1。
        let prefixText = q.text
        // 不要在 sort comparator 内 lowercased()：比较次数是 O(n log n)，百万行库即使命中
        // 只有数百条也会把同一段 text 重复分配/归一化。每个 folded item 只算一次 membership，
        // comparator 退化成 Set lookup + Int64 compare。
        let prefixIDs: Set<String>
        if let prefixText, !prefixText.isEmpty {
            let needle = prefixText.lowercased()
            prefixIDs = Set(deduped.compactMap { hit in
                let item = hit.0
                let previewMatches = item.preview?.lowercased().hasPrefix(needle) == true
                let fullTextMatches = item.textFull?.lowercased().hasPrefix(needle) == true
                return previewMatches || fullTextMatches ? item.id : nil
            })
        } else {
            prefixIDs = []
        }
        deduped.sort { lhs, rhs in
            if prefixText != nil {
                let lp = prefixIDs.contains(lhs.0.id)
                let rp = prefixIDs.contains(rhs.0.id)
                if lp != rp { return lp && !rp }
            } else if lhs.0.pinned != rhs.0.pinned {
                return lhs.0.pinned
            }
            return lhs.0.capturedAtNs > rhs.0.capturedAtNs
        }
        let start = min(q.offset, deduped.count)
        let end = min(q.offset + q.limit, deduped.count)
        guard start < end else { return [] }
        return Array(deduped[start..<end])
    }

    /// Raw 单表 fetch：纯 SQL，没有 Swift 端 fold。仅 `fetchHitsFolded` 内部 oversample
    /// 时用——公开 API 永远走 fold-aware 的 `searchHits`，跟对端口径一致
    private static func fetchHitsRaw(_ db: GRDB.Database, query q: SearchQuery) throws -> [(Item, String?)] {
        var wheres: [String] = []
        var args: [DatabaseValueConvertible] = []

        if !q.includeDeleted { wheres.append("item.deleted_at_ns IS NULL") }
        if let from = q.fromNs { wheres.append("item.captured_at_ns >= ?"); args.append(from) }
        if let to = q.toNs { wheres.append("item.captured_at_ns <= ?"); args.append(to) }
        if let kindPred = buildKindPredicate(q, args: &args) {
            wheres.append(kindPred)
        }
        if q.pinnedOnly { wheres.append("item.pinned = 1") }

        let useFTS: Bool
        if let text = q.text, let match = ftsQuery(from: text) {
            useFTS = true
            wheres.append("item_fts MATCH ?")
            args.append(match)
        } else {
            useFTS = false
        }

        let join = useFTS ? "JOIN item_fts ON item_fts.rowid = item.rowid" : ""
        // snippet 窗口 = match 前后各 N 个 token。FTS5 硬限 1..64,取上限 64
        // 让卡片尽量多带上下文;物理截断由 `lineLimit(20) + frame(height: 204)` 兜底
        let snippetCol = useFTS
            ? ", snippet(item_fts, -1, char(2), char(3), '…', 64) AS _snippet"
            : ""
        let prefixCol: String
        let needsPrefix = q.text != nil && ftsQuery(from: q.text!) != nil
        if needsPrefix {
            prefixCol = """
                , CASE
                    WHEN instr(LOWER(IFNULL(item.preview, '')), LOWER(?)) = 1
                      OR instr(LOWER(IFNULL(item.text_full, '')), LOWER(?)) = 1 THEN 1
                    ELSE 0
                  END AS _prefix
                """
            args.insert(contentsOf: [q.text! as DatabaseValueConvertible, q.text! as DatabaseValueConvertible], at: 0)
        } else {
            prefixCol = ""
        }
        let order = needsPrefix
            ? "_prefix DESC, item.captured_at_ns DESC"
            : "item.pinned DESC, item.captured_at_ns DESC"
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item.*\(snippetCol)\(prefixCol)
            FROM item
            \(join)
            \(whereClause)
            ORDER BY \(order)
            LIMIT ? OFFSET ?
        """
        args.append(q.limit)
        args.append(q.offset)

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return try rows.map { row -> (Item, String?) in
            let item = try Item(row: row)
            let snippet: String? = useFTS ? row["_snippet"] : nil
            return (item, snippet)
        }
    }

    /// 当前 query 条件下匹配的真实总数（忽略 limit/offset，**fold-aware**）。
    /// UI 用来显示真实 counter，不受 200 cap 截断影响。跟 `searchHits` 同源走
    /// fold 路径——保证 list / total / chip 三者口径一致。
    public func count(_ q: SearchQuery) throws -> Int {
        if Self.canUseFoldProjection(q) {
            return try searchSummary(q).totalCount
        }
        return try database.pool.read { db in
            let oversample = SearchQuery(
                text: q.text,
                fromNs: q.fromNs, toNs: q.toNs,
                kinds: q.kinds,
                fileSubKinds: q.fileSubKinds,
                textFullSuffixes: q.textFullSuffixes,
                pinnedOnly: q.pinnedOnly,
                includeDeleted: q.includeDeleted,
                limit: Int.max,
                offset: 0
            )
            return try Self.fetchHitsFolded(db, query: oversample).count
        }
    }

    /// 当前 (query / timeRange / pinnedOnly) 维度下，按 kind 分桶的 fold 后命中数。
    /// **忽略**输入 `q.kinds` + `q.fileSubKinds`——chip count 显示的是"如果我只点这个
    /// chip 会得到多少"，跟当前已选 chip 集合无关。否则多选时 count 来回跳，用户没法
    /// 判断稀疏类型。跟 `searchHits` / `count` 同源走 fold 路径，保证 chip / total / list 口径一致。
    public func countByKind(_ q: SearchQuery) throws -> [ItemKind: Int] {
        if Self.canUseFoldProjection(q) {
            return try searchSummary(q).kindCounts
        }
        // textFullSuffixes 是搜索维度（用户输 /java 想看 java 文件），不是 chip 维度，
        // 跟 kinds/fileSubKinds 不同——保留进 stripped 让 chip count 反映"如果只选这个
        // chip + 当前搜索范围有多少"，而不是"忽略整个搜索范围"
        let stripped = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: [],
            fileSubKinds: [],
            textFullSuffixes: q.textFullSuffixes,
            pinnedOnly: q.pinnedOnly,
            includeDeleted: q.includeDeleted,
            limit: Int.max, offset: 0
        )
        return try database.pool.read { db in
            let hits = try Self.fetchHitsFolded(db, query: stripped)
            var out: [ItemKind: Int] = [:]
            for hit in hits {
                out[hit.0.kind, default: 0] += 1
            }
            return out
        }
    }

    /// 按 file sub-kind 分桶的 fold 后命中数。同 `countByKind` 的语义——chip "视频 N"
    /// 显示假如**只**选视频会有多少条,忽略当前已选 chip。返回所有 FileSubKind 的 entry
    /// (缺的填 0),让 chip "0" 状态可见
    public func countByFileSubKind(_ q: SearchQuery) throws -> [FileSubKind: Int] {
        if Self.canUseFoldProjection(q) {
            return try searchSummary(q).fileSubKindCounts
        }
        let stripped = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: [],
            fileSubKinds: [],
            textFullSuffixes: q.textFullSuffixes,
            pinnedOnly: q.pinnedOnly,
            includeDeleted: q.includeDeleted,
            limit: Int.max, offset: 0
        )
        return try database.pool.read { db in
            let hits = try Self.fetchHitsFolded(db, query: stripped)
            var out: [FileSubKind: Int] = [:]
            for k in FileSubKind.allCases { out[k] = 0 }
            for hit in hits where hit.0.kind == .file {
                if let sub = ItemClassifier.fileSubKind(hit.0) {
                    out[sub, default: 0] += 1
                }
            }
            return out
        }
    }

    private static func canUseFoldProjection(_ q: SearchQuery) -> Bool {
        q.text == nil && q.fromNs == nil && q.toNs == nil
    }

    /// FTS/time fallback：拿无 qualifier 的完整 folded scope 一次，再从该数组派生四类输出。
    private static func fetchFoldedSummary(
        _ db: GRDB.Database,
        query q: SearchQuery
    ) throws -> SearchSummary {
        let baseQuery = SearchQuery(
            text: q.text,
            fromNs: q.fromNs,
            toNs: q.toNs,
            kinds: [],
            fileSubKinds: [],
            textFullSuffixes: [],
            pinnedOnly: q.pinnedOnly,
            includeDeleted: q.includeDeleted,
            limit: Int.max,
            offset: 0
        )
        let base = try fetchHitsFolded(db, query: baseQuery)
        let actual = hasAnyQualifier(q)
            ? base.filter { matchesQualifier($0.0, query: q) }
            : base
        let facetScope = q.textFullSuffixes.isEmpty
            ? base
            : base.filter { matchesSuffix($0.0, suffixes: q.textFullSuffixes) }

        var kinds: [ItemKind: Int] = [:]
        var fileKinds = Dictionary(uniqueKeysWithValues: FileSubKind.allCases.map { ($0, 0) })
        for hit in facetScope {
            let item = hit.0
            kinds[item.kind, default: 0] += 1
            if let sub = ItemClassifier.fileSubKind(item) {
                fileKinds[sub, default: 0] += 1
            }
        }
        let start = min(q.offset, actual.count)
        let end = min(q.offset + q.limit, actual.count)
        let hits = start < end ? Array(actual[start..<end]) : []
        return SearchSummary(
            hits: hits,
            totalCount: actual.count,
            kindCounts: kinds,
            fileSubKindCounts: fileKinds
        )
    }

    private static func hasAnyQualifier(_ q: SearchQuery) -> Bool {
        !q.kinds.isEmpty || !q.fileSubKinds.isEmpty || !q.textFullSuffixes.isEmpty
    }

    private static func matchesQualifier(_ item: Item, query q: SearchQuery) -> Bool {
        if q.kinds.contains(item.kind) { return true }
        if let sub = ItemClassifier.fileSubKind(item), q.fileSubKinds.contains(sub) { return true }
        return matchesSuffix(item, suffixes: q.textFullSuffixes)
    }

    private static func matchesSuffix(_ item: Item, suffixes: [String]) -> Bool {
        guard !suffixes.isEmpty, let text = item.textFull?.lowercased() else { return false }
        return suffixes.contains { text.hasSuffix($0.lowercased()) }
    }

    private static func fetchProjectionSummary(
        _ db: GRDB.Database,
        query q: SearchQuery
    ) throws -> SearchSummary {
        if q.textFullSuffixes.isEmpty {
            let counts = try fetchIndexedProjectionCounts(db, query: q)
            return SearchSummary(
                hits: try fetchProjectionHits(db, query: q),
                totalCount: counts.total,
                kindCounts: counts.kinds,
                fileSubKindCounts: counts.fileKinds
            )
        }

        var aggregateArgs: [DatabaseValueConvertible] = []
        let actualPredicate = projectionQualifierPredicate(q, alias: "f", args: &aggregateArgs) ?? "1"
        let suffixPredicate = projectionSuffixPredicate(
            q.textFullSuffixes, alias: "f", args: &aggregateArgs
        ) ?? "1"
        let commonWhere = q.pinnedOnly ? "WHERE f.pinned = 1" : ""
        let kindColumns = ItemKind.allCases.map { kind in
            "COALESCE(SUM(CASE WHEN chip_match = 1 AND kind = '\(kind.rawValue)' THEN 1 ELSE 0 END), 0) AS kind_\(kind.rawValue)"
        }
        let fileColumns = FileSubKind.allCases.map { sub in
            "COALESCE(SUM(CASE WHEN chip_match = 1 AND file_sub_kind = '\(sub.rawValue)' THEN 1 ELSE 0 END), 0) AS file_\(sub.rawValue)"
        }
        let aggregateSQL = """
            WITH scoped AS (
                SELECT kind, file_sub_kind,
                       CASE WHEN \(actualPredicate) THEN 1 ELSE 0 END AS actual_match,
                       CASE WHEN \(suffixPredicate) THEN 1 ELSE 0 END AS chip_match
                FROM search_fold f
                \(commonWhere)
            )
            SELECT COALESCE(SUM(actual_match), 0) AS total_count,
                   \((kindColumns + fileColumns).joined(separator: ",\n                   "))
            FROM scoped
        """
        guard let row = try Row.fetchOne(
            db, sql: aggregateSQL, arguments: StatementArguments(aggregateArgs)
        ) else {
            return SearchSummary(hits: [], totalCount: 0, kindCounts: [:], fileSubKindCounts: [:])
        }
        let total: Int = row["total_count"]
        var kinds: [ItemKind: Int] = [:]
        for kind in ItemKind.allCases {
            let count: Int = row["kind_\(kind.rawValue)"]
            if count > 0 { kinds[kind] = count }
        }
        var fileKinds: [FileSubKind: Int] = [:]
        for sub in FileSubKind.allCases {
            fileKinds[sub] = row["file_\(sub.rawValue)"] as Int
        }
        return SearchSummary(
            hits: try fetchProjectionHits(db, query: q),
            totalCount: total,
            kindCounts: kinds,
            fileSubKindCounts: fileKinds
        )
    }

    /// 默认空搜索不需要逐行算 11 个 CASE。total、kind、file-sub-kind 分别从覆盖索引
    /// COUNT/GROUP BY；三次 B-tree scan 比一个宽 conditional aggregate 更省 CPU，百万行
    /// release p95 的收益由 R4.2 benchmark gate 约束。suffix 是动态字符串，只能留慢路。
    private static func fetchIndexedProjectionCounts(
        _ db: GRDB.Database,
        query q: SearchQuery
    ) throws -> (total: Int, kinds: [ItemKind: Int], fileKinds: [FileSubKind: Int]) {
        var totalArgs: [DatabaseValueConvertible] = []
        var totalWheres: [String] = []
        if q.pinnedOnly { totalWheres.append("f.pinned = 1") }
        if let qualifier = projectionQualifierPredicate(q, alias: "f", args: &totalArgs) {
            totalWheres.append(qualifier)
        }
        let totalWhere = totalWheres.isEmpty
            ? ""
            : "WHERE " + totalWheres.joined(separator: " AND ")
        let total = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM search_fold f \(totalWhere)",
            arguments: StatementArguments(totalArgs)
        ) ?? 0

        let facetWhere = q.pinnedOnly ? "WHERE pinned = 1" : ""
        let kindRows = try Row.fetchAll(db, sql: """
            SELECT kind, COUNT(*) AS count
            FROM search_fold
            \(facetWhere)
            GROUP BY kind
        """)
        var kinds: [ItemKind: Int] = [:]
        for row in kindRows {
            guard let raw: String = row["kind"], let kind = ItemKind(rawValue: raw) else { continue }
            kinds[kind] = row["count"]
        }

        let fileWhere = q.pinnedOnly
            ? "WHERE file_sub_kind IS NOT NULL AND pinned = 1"
            : "WHERE file_sub_kind IS NOT NULL"
        let fileRows = try Row.fetchAll(db, sql: """
            SELECT file_sub_kind, COUNT(*) AS count
            FROM search_fold
            \(fileWhere)
            GROUP BY file_sub_kind
        """)
        var fileKinds = Dictionary(uniqueKeysWithValues: FileSubKind.allCases.map { ($0, 0) })
        for row in fileRows {
            guard let raw: String = row["file_sub_kind"],
                  let sub = FileSubKind(rawValue: raw) else { continue }
            fileKinds[sub] = row["count"]
        }
        return (total, kinds, fileKinds)
    }

    private static func fetchProjectionHits(
        _ db: GRDB.Database,
        query q: SearchQuery
    ) throws -> [(Item, String?)] {
        var args: [DatabaseValueConvertible] = []
        var wheres: [String] = []
        if q.pinnedOnly { wheres.append("f.pinned = 1") }
        if let qualifier = projectionQualifierPredicate(q, alias: "f", args: &args) {
            wheres.append(qualifier)
        }
        let whereSQL = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item.*,
                   f.captured_at_ns AS _fold_captured_at_ns,
                   f.pinned AS _fold_pinned
            FROM search_fold f
            JOIN item ON item.id = f.item_id
            \(whereSQL)
            ORDER BY f.pinned DESC, f.captured_at_ns DESC, f.item_id ASC
            LIMIT ? OFFSET ?
        """
        args.append(q.limit)
        args.append(q.offset)
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
            var item = try Item(row: row)
            item.capturedAtNs = row["_fold_captured_at_ns"]
            item.pinned = row["_fold_pinned"]
            return (item, nil)
        }
    }

    private static func projectionQualifierPredicate(
        _ q: SearchQuery,
        alias: String,
        args: inout [DatabaseValueConvertible]
    ) -> String? {
        var clauses: [String] = []
        if !q.kinds.isEmpty {
            clauses.append("\(alias).kind IN (\(q.kinds.map { _ in "?" }.joined(separator: ",")))")
            args.append(contentsOf: q.kinds.map(\.rawValue))
        }
        if !q.fileSubKinds.isEmpty {
            clauses.append("\(alias).file_sub_kind IN (\(q.fileSubKinds.map { _ in "?" }.joined(separator: ",")))")
            args.append(contentsOf: q.fileSubKinds.map(\.rawValue))
        }
        if let suffix = projectionSuffixPredicate(q.textFullSuffixes, alias: alias, args: &args) {
            clauses.append(suffix)
        }
        guard !clauses.isEmpty else { return nil }
        return clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: " OR ") + ")"
    }

    private static func projectionSuffixPredicate(
        _ suffixes: [String],
        alias: String,
        args: inout [DatabaseValueConvertible]
    ) -> String? {
        guard !suffixes.isEmpty else { return nil }
        let clauses = suffixes.map { suffix -> String in
            let normalized = suffix.lowercased()
            args.append(normalized)
            args.append(normalized)
            // 用 SUBSTR 而非 LIKE：`%` / `_` 在 SearchQuery suffix 里必须仍是字面字符，
            // 与 Swift `hasSuffix` 后置过滤完全一致。
            return "SUBSTR(LOWER(IFNULL(\(alias).text_full, '')), -LENGTH(?)) = ?"
        }
        return clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: " OR ") + ")"
    }

    /// 构造 kind + fileSubKinds 的 OR'd WHERE 谓词。返回 nil 表示无 kind 过滤。
    /// args 通过 inout 追加占位符值,调用方拼到自己的 args 序列里。
    /// 注意:占位符顺序必须跟 args 追加顺序严格对齐
    private static func buildKindPredicate(_ q: SearchQuery, args: inout [DatabaseValueConvertible]) -> String? {
        var clauses: [String] = []
        if !q.kinds.isEmpty {
            let p = q.kinds.map { _ in "?" }.joined(separator: ",")
            clauses.append("item.kind IN (\(p))")
            args.append(contentsOf: q.kinds.map { $0.rawValue })
        }
        for sub in q.fileSubKinds {
            let pred = subKindSQL(sub, args: &args)
            clauses.append("(item.kind = 'file' AND \(pred))")
        }
        for suffix in q.textFullSuffixes {
            args.append("%" + suffix.lowercased())
            clauses.append("LOWER(IFNULL(item.text_full,'')) LIKE ?")
        }
        guard !clauses.isEmpty else { return nil }
        return clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: " OR ") + ")"
    }

    /// 单个 FileSubKind 的 SQL 谓词:mime OR 路径后缀 LIKE。多 ext 用 OR 串联,
    /// LIKE 用 `LOWER(IFNULL(text_full,''))` 兼容空字段 + 大小写
    private static func subKindSQL(_ sub: FileSubKind, args: inout [DatabaseValueConvertible]) -> String {
        let mimeClause: String
        let exts: [String]
        switch sub {
        case .video:
            args.append("video/%")
            mimeClause = "item.blob_mime LIKE ?"
            exts = [".mp4", ".m4v", ".mov"]
        case .pdf:
            args.append("application/pdf")
            mimeClause = "item.blob_mime = ?"
            exts = [".pdf"]
        case .audio:
            args.append("audio/%")
            mimeClause = "item.blob_mime LIKE ?"
            exts = [".mp3", ".m4a", ".aac", ".wav", ".flac", ".aiff", ".aif", ".ogg", ".opus"]
        case .imageFile:
            args.append("image/%")
            mimeClause = "item.blob_mime LIKE ?"
            exts = [".png", ".jpg", ".jpeg", ".heic", ".heif", ".gif", ".webp", ".tiff", ".tif", ".bmp", ".svg"]
        }
        let likeClauses = exts.map { ext -> String in
            args.append("%" + ext)
            return "LOWER(IFNULL(item.text_full,'')) LIKE ?"
        }
        return "(" + ([mimeClause] + likeClauses).joined(separator: " OR ") + ")"
    }

    /// 把用户输入的自由文本转成 FTS5 MATCH 表达式。
    /// 策略：按空白拆词，每个 token 转义双引号后作为前缀短语，AND 连接。
    /// 比如 `foo bar"baz` → `"foo"* AND "bar""baz"*`
    public static func ftsQuery(from text: String) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " AND ")
    }

    public static func fetch(_ db: GRDB.Database, query q: SearchQuery) throws -> [Item] {
        var wheres: [String] = []
        var args: [DatabaseValueConvertible] = []

        if !q.includeDeleted {
            wheres.append("item.deleted_at_ns IS NULL")
        }
        if let from = q.fromNs {
            wheres.append("item.captured_at_ns >= ?")
            args.append(from)
        }
        if let to = q.toNs {
            wheres.append("item.captured_at_ns <= ?")
            args.append(to)
        }
        if let kindPred = buildKindPredicate(q, args: &args) {
            wheres.append(kindPred)
        }
        if q.pinnedOnly {
            wheres.append("item.pinned = 1")
        }

        let useFTS: Bool
        if let text = q.text, let match = ftsQuery(from: text) {
            useFTS = true
            wheres.append("item_fts MATCH ?")
            args.append(match)
        } else {
            useFTS = false
        }

        let join = useFTS ? "JOIN item_fts ON item_fts.rowid = item.rowid" : ""
        let needsPrefix = q.text != nil && ftsQuery(from: q.text!) != nil
        let prefixCol: String
        if needsPrefix {
            prefixCol = """
                , CASE
                    WHEN instr(LOWER(IFNULL(item.preview, '')), LOWER(?)) = 1
                      OR instr(LOWER(IFNULL(item.text_full, '')), LOWER(?)) = 1 THEN 1
                    ELSE 0
                  END AS _prefix
                """
            args.insert(contentsOf: [q.text! as DatabaseValueConvertible, q.text! as DatabaseValueConvertible], at: 0)
        } else {
            prefixCol = ""
        }
        let order = needsPrefix
            ? "_prefix DESC, item.captured_at_ns DESC"
            : "item.pinned DESC, item.captured_at_ns DESC"
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item.*\(prefixCol)
            FROM item
            \(join)
            \(whereClause)
            ORDER BY \(order)
            LIMIT ? OFFSET ?
        """
        args.append(q.limit)
        args.append(q.offset)

        return try Item.fetchAll(db, sql: sql, arguments: StatementArguments(args))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

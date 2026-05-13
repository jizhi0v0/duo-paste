import Foundation
import GRDB

public struct SearchQuery: Sendable, Equatable {
    public var text: String?
    public var fromNs: Int64?
    public var toNs: Int64?
    public var kinds: [ItemKind]
    public var pinnedOnly: Bool
    public var includeDeleted: Bool
    public var limit: Int
    public var offset: Int

    public init(
        text: String? = nil,
        fromNs: Int64? = nil,
        toNs: Int64? = nil,
        kinds: [ItemKind] = [],
        pinnedOnly: Bool = false,
        includeDeleted: Bool = false,
        limit: Int = 200,
        offset: Int = 0
    ) {
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.fromNs = fromNs
        self.toNs = toNs
        self.kinds = kinds
        self.pinnedOnly = pinnedOnly
        self.includeDeleted = includeDeleted
        self.limit = limit
        self.offset = offset
    }
}

public struct SearchAPI: Sendable {
    public let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func search(_ q: SearchQuery) throws -> [Item] {
        try database.pool.read { db in
            try Self.fetch(db, query: q)
        }
    }

    /// 匹配词高亮分隔符。STX/ETX 是 ASCII 控制字符，几乎不会出现在剪贴板真实文本里——
    /// UI 拿到字符串按这两个 marker 切片、夹在中间的部分加粗。
    public static let snippetStartMarker = "\u{02}"
    public static let snippetEndMarker   = "\u{03}"

    /// 一次 SQL 同时返回 item + FTS snippet——比 search() + snippets() 两次查询快一倍以上。
    /// snippet 仅当 query.text 非空时填；其它情况第二元素为 nil。
    /// max tokens=8：紧密围绕匹配词，SwiftUI `lineLimit(2)` 一定能显示到高亮段。
    public func searchHits(_ q: SearchQuery) throws -> [(Item, String?)] {
        try database.pool.read { db in
            try Self.fetchHits(db, query: q)
        }
    }

    /// Mesh 模式：v7 合表后 peer 行直接落 `item` 表，本机 own 行也在 `item` 表。原来的
    /// "本机 item ∪ 远端 item_mirror" 跨表 union 退化为单表 fetchHits + Swift 端 text-fold。
    ///
    /// **保留 fetchUnion 接口**：SearchProvider.localMirror 路径仍调它（PR 6 才清 Mode 枚举）。
    /// 内部逻辑：fetchHits oversample（无 kinds/pinnedOnly 过滤）→ text-fold（pinned OR 聚合）
    /// → 后置 kinds/pinnedOnly 过滤 → 排序契约（pinned/prefix24h/captured DESC）→ LIMIT/OFFSET。
    ///
    /// text-fold 必须保留：合表后同文本可能跨 origin 重复（本机 own 行 + peer mirror 行），capture
    /// 层 dedup 只过滤同 origin，跨 origin 兜底靠这一层（详 CLAUDE.md "文本永久 dedup"）。
    public func searchUnion(_ q: SearchQuery) throws -> [(Item, String?)] {
        try database.pool.read { db in
            try Self.fetchUnion(db, query: q)
        }
    }

    static func fetchUnion(_ db: GRDB.Database, query q: SearchQuery) throws -> [(Item, String?)] {
        // pinnedOnly / kinds 必须在 text-fold **之后**按 winner 行的字段过滤——fold 会做 pinned
        // OR 聚合，过滤依据必须是聚合后 winner。否则：跨 origin 同文本一边 pinned=true 一边
        // false，子查询带 `pinned=1` 过滤后只剩 pinned 那条参与 fold，winner 不变；但 list /
        // countByKindUnion 走同源 oversample 流程要保证三者口径一致。
        //
        // pinnedOnly=true 或 q.kinds 非空时 oversample 必须无界——否则按时间倒序取 limit+offset
        // 行可能全是不该出现在结果里的类型/未 pin 状态，filter 后凑不齐 q.limit。剪贴板量级
        // 万级，Swift 端 fold 几毫秒，可接受。
        let needsPostFilter = q.pinnedOnly || !q.kinds.isEmpty
        let oversampleLimit = needsPostFilter ? Int.max : (q.limit + q.offset)
        let oversample = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: [], pinnedOnly: false,
            includeDeleted: q.includeDeleted,
            limit: oversampleLimit,
            offset: 0
        )
        let raw = try fetchHits(db, query: oversample)

        // 文本永久 dedup：单表 item 内按 text_full 二次 fold。仅 blob_sha256 IS NULL 行参与
        // （即 text/url/file，"字节相等即同"），blob kind 不动——同 sha 图片多次复制可能是
        // 用户故意保留时间线。winner = max(capturedAtNs)，pinned 通过 OR 聚合（任一条 pinned
        // → fold 结果 pinned=true），符合"pin 是对内容的属性而非具体 row"心智。
        //
        // 必须在下面的 kind/pinned 后置 filter **之前**——pinned 聚合后 winner.pinned 才是
        // 正确的过滤依据。
        var byText: [String: (Item, String?)] = [:]
        var nonTextFolded: [(Item, String?)] = []
        nonTextFolded.reserveCapacity(raw.count)
        for hit in raw {
            let it = hit.0
            if it.blobSha256 == nil, let tf = it.textFull, !tf.isEmpty {
                if let existing = byText[tf] {
                    let winner = it.capturedAtNs > existing.0.capturedAtNs ? hit : existing
                    var w = winner.0
                    w.pinned = it.pinned || existing.0.pinned
                    byText[tf] = (w, winner.1)
                } else {
                    byText[tf] = hit
                }
            } else {
                nonTextFolded.append(hit)
            }
        }
        var deduped = Array(byText.values) + nonTextFolded

        // 按 winner 行的字段过滤——不可前置到子查询。countByKindUnion / countUnion 走同源
        // 不变量保证 chip 数字、count、list 三者口径一致。
        if !q.kinds.isEmpty {
            let allowed = Set(q.kinds)
            deduped = deduped.filter { allowed.contains($0.0.kind) }
        }
        if q.pinnedOnly {
            deduped = deduped.filter { $0.0.pinned }
        }
        // 排序契约：pinned DESC → prefix DESC → captured_at_ns DESC。
        // prefix 分数跟 SQL 端 CASE 一致（preview 起始=2, text_full 起始=1, 否则 0）。
        let prefixText = q.text
        // 跟 SQL 端口径一致：24h 窗外的项 prefix 分数清零，强制走时间倒序。
        let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let windowNs: Int64 = 86_400 * 1_000_000_000
        func prefixScore(_ item: Item) -> Int {
            guard let t = prefixText, !t.isEmpty else { return 0 }
            if nowNs - item.capturedAtNs >= windowNs { return 0 }
            let needle = t.lowercased()
            if let pv = item.preview, pv.lowercased().hasPrefix(needle) { return 2 }
            if let tf = item.textFull, tf.lowercased().hasPrefix(needle) { return 1 }
            return 0
        }
        deduped.sort { lhs, rhs in
            if lhs.0.pinned != rhs.0.pinned { return lhs.0.pinned }
            let lp = prefixScore(lhs.0)
            let rp = prefixScore(rhs.0)
            if lp != rp { return lp > rp }
            return lhs.0.capturedAtNs > rhs.0.capturedAtNs
        }
        let start = min(q.offset, deduped.count)
        let end = min(q.offset + q.limit, deduped.count)
        guard start < end else { return [] }
        return Array(deduped[start..<end])
    }

    static func fetchHits(_ db: GRDB.Database, query q: SearchQuery) throws -> [(Item, String?)] {
        var wheres: [String] = []
        var args: [DatabaseValueConvertible] = []

        if !q.includeDeleted { wheres.append("item.deleted_at_ns IS NULL") }
        if let from = q.fromNs { wheres.append("item.captured_at_ns >= ?"); args.append(from) }
        if let to = q.toNs { wheres.append("item.captured_at_ns <= ?"); args.append(to) }
        if !q.kinds.isEmpty {
            let p = q.kinds.map { _ in "?" }.joined(separator: ",")
            wheres.append("item.kind IN (\(p))")
            args.append(contentsOf: q.kinds.map { $0.rawValue })
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
        let snippetCol = useFTS
            ? ", snippet(item_fts, -1, char(2), char(3), '…', 8) AS _snippet"
            : ""
        let prefixCol: String
        let needsPrefix = q.text != nil && ftsQuery(from: q.text!) != nil
        if needsPrefix {
            prefixCol = """
                , CASE
                    WHEN instr(LOWER(IFNULL(item.preview, '')), LOWER(?)) = 1 THEN 2
                    WHEN instr(LOWER(IFNULL(item.text_full, '')), LOWER(?)) = 1 THEN 1
                    ELSE 0
                  END AS _prefix
                """
            args.insert(contentsOf: [q.text! as DatabaseValueConvertible, q.text! as DatabaseValueConvertible], at: 0)
        } else {
            prefixCol = ""
        }
        // 时间窗：prefix-boost 仅对 24h 内的项生效。跨天的老内容（哪怕起头匹配）也按
        // 时间倒序排——剪贴板心智里"搜=找最近用过的"，不希望陈年老条目被翻上来。
        // SQLite 自带 strftime('%s','now')，避免 Swift 端再往 args 里塞 now_ns。
        let orderPrefix = needsPrefix
            ? "(CASE WHEN (CAST(strftime('%s','now') AS INTEGER) * 1000000000 - item.captured_at_ns) < 86400000000000 THEN _prefix ELSE 0 END) DESC, "
            : ""
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item.*\(snippetCol)\(prefixCol)
            FROM item
            \(join)
            \(whereClause)
            ORDER BY item.pinned DESC, \(orderPrefix)item.captured_at_ns DESC
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

    /// 当前 query 条件下本机 `item` 表里的匹配总数（忽略 limit/offset）。
    /// UI 用来显示真实 counter，不受 200 cap 截断影响。
    public func count(_ q: SearchQuery) throws -> Int {
        try database.pool.read { db in
            try Self.countItem(db, query: q)
        }
    }

    /// Mesh 模式下：合表后 `item` 单表，countUnion 跟 fetchUnion 同源走 text-fold 路径
    /// （`countUnionStatic` 内部调 `fetchUnion(limit=.max)`），保证 list / total / chip 三者口径
    /// 一致。原跨表 union 语义在 v7 合表后退化为单表 fold，但 API 保留给 SearchProvider 用。
    public func countUnion(_ q: SearchQuery) throws -> Int {
        try database.pool.read { db in
            try Self.countUnionStatic(db, query: q)
        }
    }

    /// 构造 count 用的 WHERE/JOIN 片段。复用 fetchHits 的过滤逻辑，
    /// 只是不取列也不排序——保证 counter 跟 list 的过滤口径一致。
    private static func buildCountClauses(
        table: String,
        ftsTable: String,
        query q: SearchQuery
    ) -> (join: String, whereClause: String, args: [DatabaseValueConvertible]) {
        var wheres: [String] = []
        var args: [DatabaseValueConvertible] = []

        if !q.includeDeleted { wheres.append("\(table).deleted_at_ns IS NULL") }
        if let from = q.fromNs { wheres.append("\(table).captured_at_ns >= ?"); args.append(from) }
        if let to = q.toNs { wheres.append("\(table).captured_at_ns <= ?"); args.append(to) }
        if !q.kinds.isEmpty {
            let p = q.kinds.map { _ in "?" }.joined(separator: ",")
            wheres.append("\(table).kind IN (\(p))")
            args.append(contentsOf: q.kinds.map { $0.rawValue })
        }
        if q.pinnedOnly { wheres.append("\(table).pinned = 1") }

        var join = ""
        if let text = q.text, let match = ftsQuery(from: text) {
            join = "JOIN \(ftsTable) ON \(ftsTable).rowid = \(table).rowid"
            wheres.append("\(ftsTable) MATCH ?")
            args.append(match)
        }
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        return (join, whereClause, args)
    }

    static func countItem(_ db: GRDB.Database, query q: SearchQuery) throws -> Int {
        let (join, whereClause, args) = buildCountClauses(table: "item", ftsTable: "item_fts", query: q)
        let sql = "SELECT COUNT(*) FROM item \(join) \(whereClause)"
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
    }

    static func countUnionStatic(_ db: GRDB.Database, query q: SearchQuery) throws -> Int {
        // 走 fetchUnion 同源路径——id-dedup + 文本 fold + 按 winner 字段过滤——保证
        // list / total-count / kind-count 三者口径一致。规模上剪贴板 item+mirror 万级，
        // FTS 命中后通常千级以下，Swift 端 dedup 几毫秒；与 fetchUnion 顶头 tradeoff 注释同源。
        let oversample = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: q.kinds,
            pinnedOnly: q.pinnedOnly,
            includeDeleted: q.includeDeleted,
            limit: Int.max,
            offset: 0
        )
        let hits = try fetchUnion(db, query: oversample)
        return hits.count
    }

    /// 当前 (query / timeRange / pinnedOnly) 维度下，按 kind 分桶的命中数。
    /// **忽略**输入 `q.kinds`——chip count 显示的是"如果我只点这个 kind 会得到多少"，
    /// 跟当前已选 chip 集合无关。否则多选时 count 来回跳，用户没法判断稀疏类型。
    public func countByKind(_ q: SearchQuery) throws -> [ItemKind: Int] {
        let stripped = Self.stripKinds(q)
        return try database.pool.read { db in
            try Self.countByKindItem(db, query: stripped)
        }
    }

    /// Mesh 模式下：合表后单表 `item` 按 text-fold 后 GROUP BY kind。`countByKindUnionStatic`
    /// 走 fetchUnion 同源路径——text-fold + pinned 后置过滤——保证 chip / count / list 口径一致。
    public func countByKindUnion(_ q: SearchQuery) throws -> [ItemKind: Int] {
        let stripped = Self.stripKinds(q)
        return try database.pool.read { db in
            try Self.countByKindUnionStatic(db, query: stripped)
        }
    }

    private static func stripKinds(_ q: SearchQuery) -> SearchQuery {
        SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: [],
            pinnedOnly: q.pinnedOnly,
            includeDeleted: q.includeDeleted,
            limit: 0, offset: 0
        )
    }

    static func countByKindItem(_ db: GRDB.Database, query q: SearchQuery) throws -> [ItemKind: Int] {
        let (join, whereClause, args) = buildCountClauses(table: "item", ftsTable: "item_fts", query: q)
        let sql = "SELECT item.kind AS kind, COUNT(*) AS cnt FROM item \(join) \(whereClause) GROUP BY item.kind"
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return decodeKindCountRows(rows)
    }

    static func countByKindUnionStatic(_ db: GRDB.Database, query q: SearchQuery) throws -> [ItemKind: Int] {
        // 走 fetchUnion 同源路径——id-dedup + 文本 fold + pinned 后置过滤——保证 chip
        // 数字、total count、list 三条路径口径一致。q.kinds 已被 stripKinds 清空，所以
        // fetchUnion 返回的是"所有 kind 的 winner"，外层按 winner.kind 分桶即可。
        let oversample = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: q.kinds,            // 通常已被 stripKinds 清空
            pinnedOnly: q.pinnedOnly,
            includeDeleted: q.includeDeleted,
            limit: Int.max,
            offset: 0
        )
        let hits = try fetchUnion(db, query: oversample)
        var out: [ItemKind: Int] = [:]
        for hit in hits {
            out[hit.0.kind, default: 0] += 1
        }
        return out
    }

    private static func decodeKindCountRows(_ rows: [Row]) -> [ItemKind: Int] {
        var out: [ItemKind: Int] = [:]
        for r in rows {
            let raw: String? = r["kind"]
            guard let raw, let k = ItemKind(rawValue: raw) else { continue }
            let cnt: Int = r["cnt"] ?? 0
            out[k] = cnt
        }
        return out
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
        if !q.kinds.isEmpty {
            let placeholders = q.kinds.map { _ in "?" }.joined(separator: ",")
            wheres.append("item.kind IN (\(placeholders))")
            args.append(contentsOf: q.kinds.map { $0.rawValue })
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
                    WHEN instr(LOWER(IFNULL(item.preview, '')), LOWER(?)) = 1 THEN 2
                    WHEN instr(LOWER(IFNULL(item.text_full, '')), LOWER(?)) = 1 THEN 1
                    ELSE 0
                  END AS _prefix
                """
            args.insert(contentsOf: [q.text! as DatabaseValueConvertible, q.text! as DatabaseValueConvertible], at: 0)
        } else {
            prefixCol = ""
        }
        // 时间窗：prefix-boost 仅对 24h 内的项生效。跨天的老内容（哪怕起头匹配）也按
        // 时间倒序排——剪贴板心智里"搜=找最近用过的"，不希望陈年老条目被翻上来。
        // SQLite 自带 strftime('%s','now')，避免 Swift 端再往 args 里塞 now_ns。
        let orderPrefix = needsPrefix
            ? "(CASE WHEN (CAST(strftime('%s','now') AS INTEGER) * 1000000000 - item.captured_at_ns) < 86400000000000 THEN _prefix ELSE 0 END) DESC, "
            : ""
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item.*\(prefixCol)
            FROM item
            \(join)
            \(whereClause)
            ORDER BY item.pinned DESC, \(orderPrefix)item.captured_at_ns DESC
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

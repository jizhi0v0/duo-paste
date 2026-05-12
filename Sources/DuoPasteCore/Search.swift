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

    /// Mirror 模式：本机 `item`（origin=self）UNION 远端 `item_mirror`（origin≠self）。
    /// PullWorker 写 item_mirror 时跳过自家 origin，所以两表 id 不重叠，但保留 `seen` 去重
    /// 兜底（promote-to-primary 流程会瞬间产生重叠状态）。
    ///
    /// 排序契约：pinned DESC, captured_at_ns DESC。两表各超量取 limit+offset，
    /// 合并后再裁剪——这是必须的，否则某一侧 limit 截断会丢掉真正应该排前面的远端项。
    public func searchUnion(_ q: SearchQuery) throws -> [(Item, String?)] {
        try database.pool.read { db in
            try Self.fetchUnion(db, query: q)
        }
    }

    static func fetchUnion(_ db: GRDB.Database, query q: SearchQuery) throws -> [(Item, String?)] {
        let oversample = SearchQuery(
            text: q.text,
            fromNs: q.fromNs, toNs: q.toNs,
            kinds: q.kinds, pinnedOnly: q.pinnedOnly,
            includeDeleted: q.includeDeleted,
            limit: q.limit + q.offset,
            offset: 0
        )
        let own = try fetchHits(db, query: oversample)
        let mirror = try fetchHitsMirror(db, query: oversample)

        // 同 id 跨表 dedup：promote 过渡期 / pin 状态分歧时，可能同 id 在 item 和 item_mirror 各一份。
        // **必须**在排序前按 captured_at_ns 取最新——否则若 mirror 那份 pinned=true 而 own 那份
        // pinned=false（用户在 primary 上 pin 了但还没同步回 own），(pinned DESC) 会让旧 mirror 行
        // 赢过新 own 行，UI 显示陈旧文本。
        var byID: [String: (Item, String?)] = [:]
        byID.reserveCapacity(own.count + mirror.count)
        for hit in own + mirror {
            if let existing = byID[hit.0.id] {
                if hit.0.capturedAtNs > existing.0.capturedAtNs {
                    byID[hit.0.id] = hit
                }
            } else {
                byID[hit.0.id] = hit
            }
        }
        var deduped = Array(byID.values)
        // 排序契约：pinned DESC → prefix DESC → captured_at_ns DESC。
        // prefix 分数跟 SQL 端 CASE 一致（preview 起始=2, text_full 起始=1, 否则 0），
        // 让 union 跨表合并后顺序跟单表 fetchHits 完全可预测。
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

    /// `item_mirror` 版的 fetchHits。schema 差异（无 push_state/push_attempts/last_push_error，
    /// 多 mirrored_at_ns）在 SELECT 列表里补：合成 `'acked' AS push_state, 0 AS push_attempts,
    /// NULL AS last_push_error` 让 Row → Item 解码不报缺字段。
    static func fetchHitsMirror(_ db: GRDB.Database, query q: SearchQuery) throws -> [(Item, String?)] {
        var wheres: [String] = []
        var args: [DatabaseValueConvertible] = []

        if !q.includeDeleted { wheres.append("item_mirror.deleted_at_ns IS NULL") }
        if let from = q.fromNs { wheres.append("item_mirror.captured_at_ns >= ?"); args.append(from) }
        if let to = q.toNs { wheres.append("item_mirror.captured_at_ns <= ?"); args.append(to) }
        if !q.kinds.isEmpty {
            let p = q.kinds.map { _ in "?" }.joined(separator: ",")
            wheres.append("item_mirror.kind IN (\(p))")
            args.append(contentsOf: q.kinds.map { $0.rawValue })
        }
        if q.pinnedOnly { wheres.append("item_mirror.pinned = 1") }

        let useFTS: Bool
        if let text = q.text, let match = ftsQuery(from: text) {
            useFTS = true
            wheres.append("item_mirror_fts MATCH ?")
            args.append(match)
        } else {
            useFTS = false
        }

        let join = useFTS ? "JOIN item_mirror_fts ON item_mirror_fts.rowid = item_mirror.rowid" : ""
        let snippetCol = useFTS
            ? ", snippet(item_mirror_fts, -1, char(2), char(3), '…', 8) AS _snippet"
            : ""
        // 前缀优先：preview / text_full 以 query 文本起始的项排到同时间组的前面。
        // case-insensitive 用 instr(LOWER(...), LOWER(?)) = 1，避开 LIKE 通配转义。
        // text_full 兜底是因为图片/blob 类没 preview 但搜不到也无所谓——主要照顾文本项。
        // 注意：CASE 在 SELECT 列表里，占位符出现在所有 WHERE/LIMIT 占位符之前，
        // 所以 prefix args 必须 insert 到 args 头部，而不是 append 尾部。
        let prefixCol: String
        let needsPrefix = q.text != nil && ftsQuery(from: q.text!) != nil
        if needsPrefix {
            prefixCol = """
                , CASE
                    WHEN instr(LOWER(IFNULL(item_mirror.preview, '')), LOWER(?)) = 1 THEN 2
                    WHEN instr(LOWER(IFNULL(item_mirror.text_full, '')), LOWER(?)) = 1 THEN 1
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
            ? "(CASE WHEN (CAST(strftime('%s','now') AS INTEGER) * 1000000000 - item_mirror.captured_at_ns) < 86400000000000 THEN _prefix ELSE 0 END) DESC, "
            : ""
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item_mirror.id, item_mirror.origin_device, item_mirror.captured_at_ns,
                   item_mirror.ingested_at_ns, item_mirror.kind,
                   item_mirror.source_app, item_mirror.source_app_name, item_mirror.preview,
                   item_mirror.text_full, item_mirror.blob_sha256, item_mirror.blob_size,
                   item_mirror.blob_mime, item_mirror.pinned, item_mirror.deleted_at_ns,
                   'acked' AS push_state, 0 AS push_attempts, NULL AS last_push_error\(snippetCol)\(prefixCol)
            FROM item_mirror
            \(join)
            \(whereClause)
            ORDER BY item_mirror.pinned DESC, \(orderPrefix)item_mirror.captured_at_ns DESC
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

    /// Mirror 模式下：`item` ∪ `item_mirror` 按 id 去重后的匹配总数。
    /// 用 `UNION` 让 SQLite 在 id 维度自动 dedup，避免同 id 跨表存在被双算
    /// （promote 过渡期 / pin 分歧时可能出现，跟 fetchUnion 里那段 byID dedupe 同源原因）。
    public func countUnion(_ q: SearchQuery) throws -> Int {
        try database.pool.read { db in
            try Self.countUnionStatic(db, query: q)
        }
    }

    /// 构造 count 用的 WHERE/JOIN 片段。复用 fetchHits/fetchHitsMirror 的过滤逻辑，
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

    static func countMirror(_ db: GRDB.Database, query q: SearchQuery) throws -> Int {
        let (join, whereClause, args) = buildCountClauses(table: "item_mirror", ftsTable: "item_mirror_fts", query: q)
        let sql = "SELECT COUNT(*) FROM item_mirror \(join) \(whereClause)"
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
    }

    static func countUnionStatic(_ db: GRDB.Database, query q: SearchQuery) throws -> Int {
        // UNION（不是 UNION ALL）自动按行去重，但我们只 select id 一列，所以等价于按 id dedupe。
        // 用 sub-select 包一层让外层 COUNT(*) 数 dedup 后的行数。
        let own = buildCountClauses(table: "item", ftsTable: "item_fts", query: q)
        let mir = buildCountClauses(table: "item_mirror", ftsTable: "item_mirror_fts", query: q)
        let sql = """
            SELECT COUNT(*) FROM (
              SELECT item.id FROM item \(own.join) \(own.whereClause)
              UNION
              SELECT item_mirror.id FROM item_mirror \(mir.join) \(mir.whereClause)
            )
        """
        var args: [DatabaseValueConvertible] = []
        args.append(contentsOf: own.args)
        args.append(contentsOf: mir.args)
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
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

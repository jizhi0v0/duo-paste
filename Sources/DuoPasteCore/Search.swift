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
        deduped.sort { lhs, rhs in
            if lhs.0.pinned != rhs.0.pinned { return lhs.0.pinned }
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
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item_mirror.id, item_mirror.origin_device, item_mirror.captured_at_ns,
                   item_mirror.ingested_at_ns, item_mirror.kind,
                   item_mirror.source_app, item_mirror.source_app_name, item_mirror.preview,
                   item_mirror.text_full, item_mirror.blob_sha256, item_mirror.blob_size,
                   item_mirror.blob_mime, item_mirror.pinned, item_mirror.deleted_at_ns,
                   'acked' AS push_state, 0 AS push_attempts, NULL AS last_push_error\(snippetCol)
            FROM item_mirror
            \(join)
            \(whereClause)
            ORDER BY item_mirror.pinned DESC, item_mirror.captured_at_ns DESC
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
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item.*\(snippetCol)
            FROM item
            \(join)
            \(whereClause)
            ORDER BY item.pinned DESC, item.captured_at_ns DESC
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
        let whereClause = wheres.isEmpty ? "" : "WHERE " + wheres.joined(separator: " AND ")
        let sql = """
            SELECT item.*
            FROM item
            \(join)
            \(whereClause)
            ORDER BY item.pinned DESC, item.captured_at_ns DESC
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

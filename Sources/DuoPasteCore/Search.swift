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

    /// FTS5 snippet：对给定 item ids 子集，返回 id → 包围匹配词的上下文片段。
    /// 仅 FTS 查询（query.text 非空）时有意义；其它情况返回空 map。
    public func snippets(forItemIDs ids: [String], query q: SearchQuery) throws -> [String: String] {
        guard let text = q.text, let match = Self.ftsQuery(from: text), !ids.isEmpty else {
            return [:]
        }
        return try database.pool.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = ids
            args.append(match)
            // snippet(<fts>, <col>, <start>, <end>, <ellipsis>, <max tokens>)
            // col=-1 表示从所有 FTS 列里选（实际命中哪列就用哪列）
            let sql = """
                SELECT item.id,
                       snippet(item_fts, -1, char(2), char(3), '…', 16) AS s
                FROM item
                JOIN item_fts ON item_fts.rowid = item.rowid
                WHERE item.id IN (\(placeholders))
                  AND item_fts MATCH ?
            """
            var map: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            for row in rows {
                if let id: String = row["id"], let s: String = row["s"] {
                    map[id] = s
                }
            }
            return map
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

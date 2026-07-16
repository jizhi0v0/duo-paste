import Foundation
import GRDB

/// Mirror 模式增量拉取的 watermark。`(ingested_at_ns, id)` 二元 cursor 而不是单 ns
/// ——同一纳秒可能有多条（primary 局部高并发 + ingested_at_ns 来自 server now()），
/// 单 ns cursor 会在跨页边界处漏行或重复。
///
/// `zero` 表示从头开始（首次 pull / 换 primary 时 pull_cursor 表里没记录）。
public struct SinceCursor: Sendable, Equatable, Codable {
    public var ingestedAtNs: Int64
    public var id: String

    public init(ingestedAtNs: Int64, id: String) {
        self.ingestedAtNs = ingestedAtNs
        self.id = id
    }

    public static let zero = SinceCursor(ingestedAtNs: 0, id: "")

    enum CodingKeys: String, CodingKey {
        case ingestedAtNs = "ingested_at_ns"
        case id
    }
}

public struct SinceQuery: Sendable, Equatable {
    public var cursor: SinceCursor
    public var limit: Int

    public init(cursor: SinceCursor = .zero, limit: Int = 500) {
        self.cursor = cursor
        self.limit = limit
    }
}

/// `GET /since` 响应的 wire 形态。PullWorker 直接 `JSONDecoder().decode(SincePageWire.self, ...)`
/// 解，**不**靠 JSONSerialization + 字典里 Int/Int64 转换的脆弱兜底。
/// `items` 用 `[Item]`——Item 已经是 Codable，wire 字段映射靠 Item.CodingKeys。
public struct SincePageWire: Codable, Sendable {
    public var ok: Bool
    public var count: Int
    public var items: [Item]
    public var nextCursor: SinceCursor
    public var hasMore: Bool
    /// Server 当前可由 `/since` 遍历到的 raw item 行数（含 tombstone）。新 server 返回；
    /// nil 兼容旧 server。Client 用它发现“cursor 已到顶但迟到旧行落在 cursor 之前”的缺口。
    public var totalCount: Int?
    /// 返回本页的 server 稳定 device ID。Client 用它把“已见过这个 source 的哪些 ID”
    /// 与本地多 peer union 分开记账，避免 union 额外行掩盖单一 source 的缺口。
    public var sourceDeviceID: String?

    public init(
        ok: Bool,
        count: Int,
        items: [Item],
        nextCursor: SinceCursor,
        hasMore: Bool,
        totalCount: Int? = nil,
        sourceDeviceID: String? = nil
    ) {
        self.ok = ok
        self.count = count
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.totalCount = totalCount
        self.sourceDeviceID = sourceDeviceID
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case count
        case items
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
        case totalCount = "total_count"
        case sourceDeviceID = "source_device_id"
    }
}

/// 一页 since 返回。`nextCursor` **始终**给出：
/// - 有新行 → 最后一行的 (ingested_at_ns, id)
/// - 无新行 → 原样回输入 cursor（client 持久化它一样，下次再来）
///
/// `hasMore` 单独表示"这次刚好达到 limit，可能还有更多" —— 不把这个语义塞进 nextCursor=nil
/// 是为了让 client 端 cursor 持久化逻辑无脑：拿到响应就更新 pull_cursor.cursor_ns。
public struct SincePage: Sendable {
    public let items: [Item]
    public let nextCursor: SinceCursor
    public let hasMore: Bool
    public let totalCount: Int

    public init(items: [Item], nextCursor: SinceCursor, hasMore: Bool, totalCount: Int) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.totalCount = totalCount
    }
}

/// `GET /since` 的查询执行体。语义跟 SearchAPI 平行：
/// - 只看 item 表（mirror 拉的是 primary 的 origin/聚合视图，不是 mirror 自己的影子）
/// - **包含软删行**（deleted_at_ns 非空也返回）—— mirror 需要 replay 删除
/// - `ingested_at_ns IS NOT NULL` 过滤掉本机 client 自己还没 push 的本地条目
///   （理论上 primary 上不会有 NULL，但 schema 允许，挡一下防万一）
public struct SinceAPI: Sendable {
    public let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// 默认 limit。500 是个折中：单页 ~500 KB（含 preview/text_full），单次 RTT 不堵塞，
    /// 多页拉时也不会撑爆 client 进程内存。
    public static let defaultLimit = 500
    public static let maxLimit = 1000

    public func fetch(_ query: SinceQuery) throws -> SincePage {
        try database.pool.read { db in
            try Self.fetch(db, query: query)
        }
    }

    static func fetch(_ db: GRDB.Database, query q: SinceQuery) throws -> SincePage {
        let limit = max(1, min(q.limit, maxLimit))
        // 跨页 stable 排序：(ingested_at_ns ASC, id ASC) 严格全序。
        // WHERE 用 (a > x) OR (a = x AND b > y) 等价 (a, b) > (x, y)，避开 SQLite 缺乏行值
        // 比较的写法（虽然现代 SQLite 支持，但显式 OR 更稳）。
        let rows = try Item.fetchAll(db, sql: """
            SELECT * FROM item
            WHERE ingested_at_ns IS NOT NULL
              AND (
                ingested_at_ns > ?
                OR (ingested_at_ns = ? AND id > ?)
              )
            ORDER BY ingested_at_ns ASC, id ASC
            LIMIT ?
        """, arguments: [q.cursor.ingestedAtNs, q.cursor.ingestedAtNs, q.cursor.id, limit])
        let totalCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM item WHERE ingested_at_ns IS NOT NULL
        """) ?? 0

        let nextCursor: SinceCursor
        if let last = rows.last, let lastNs = last.ingestedAtNs {
            nextCursor = SinceCursor(ingestedAtNs: lastNs, id: last.id)
        } else {
            nextCursor = q.cursor
        }
        return SincePage(
            items: rows,
            nextCursor: nextCursor,
            hasMore: rows.count >= limit,
            totalCount: totalCount
        )
    }
}

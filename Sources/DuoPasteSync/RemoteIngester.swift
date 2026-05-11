import Foundation
import GRDB
import DuoPasteCore

/// 把单条远端 client push 的 IngestRequest 写入本地 item 表。
///
/// 幂等：同 id 二次推入跳过，不更新已有行。
/// 这是 M2 的契约：item 一旦 ingest 就不可变。pin / 软删的跨设备同步留到 M3+
/// 单独走 `/update` 之类路由，避免 ingest 路径承担太多职责。
public struct RemoteIngester: Sendable {
    public let database: DuoPasteCore.Database
    public let now: @Sendable () -> Int64

    public init(
        database: DuoPasteCore.Database,
        now: @escaping @Sendable () -> Int64 = { Clock.nowNs() }
    ) {
        self.database = database
        self.now = now
    }

    public struct Result: Sendable {
        public let id: String
        public let ingestedAtNs: Int64
        /// true → 这是第一次见到；false → 已存在（幂等重试）。
        /// client 收到后任一种都该把本地 push_state 标 acked，所以这个字段
        /// 主要用于服务端日志 / 后续 audit 调试。
        public let wasNew: Bool
    }

    public func ingest(_ req: IngestRequest) async throws -> Result {
        try req.validate()
        let ts = now()
        let item = req.toItem(ingestedAtNs: ts)
        let wasNew = try await database.pool.write { db -> Bool in
            // 先查存在再 insert 一来更准确知道 wasNew，二来避免 INSERT OR IGNORE
            // 静默吃掉真正的冲突（比如 NOT NULL 违反）——OR IGNORE 会把所有错都忍了。
            let exists = try Item
                .filter(Column("id") == item.id)
                .fetchCount(db) > 0
            if exists { return false }
            try item.insert(db)
            return true
        }
        return Result(id: item.id, ingestedAtNs: ts, wasNew: wasNew)
    }
}

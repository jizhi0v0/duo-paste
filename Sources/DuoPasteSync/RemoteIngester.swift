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
    public let selfDeviceID: String
    /// 跨设备 Continuity dedup 时间窗（纳秒）。0 = 关闭这个 dedup 层。
    /// 默认 5_000_000_000 = 5s——Universal Clipboard 同步延迟通常 < 1s，5s buffer 充足。
    public let crossDeviceWindowNs: Int64
    public let now: @Sendable () -> Int64

    public init(
        database: DuoPasteCore.Database,
        selfDeviceID: String = "",
        crossDeviceWindowNs: Int64 = 5_000_000_000,
        now: @escaping @Sendable () -> Int64 = { Clock.nowNs() }
    ) {
        self.database = database
        self.selfDeviceID = selfDeviceID
        self.crossDeviceWindowNs = crossDeviceWindowNs
        self.now = now
    }

    public struct Result: Sendable {
        public let id: String
        public let ingestedAtNs: Int64
        /// true → 这是第一次见到；false → 已存在（幂等重试 / 跨设备 dedup 拒收）。
        /// client 收到后任一种都该把本地 push_state 标 acked，所以这个字段
        /// 主要用于服务端日志 / 后续 audit 调试。
        public let wasNew: Bool
        /// dedup 拒收的原因：nil = 正常入库或 id 幂等命中；非 nil = Continuity 副本拒收等。
        /// 字段加在 wire 的可选位置（Server.handleIngest 序列化时只在非 nil 时输出），
        /// 老 client 不感知。
        public let dedupReason: String?

        public init(id: String, ingestedAtNs: Int64, wasNew: Bool, dedupReason: String? = nil) {
            self.id = id
            self.ingestedAtNs = ingestedAtNs
            self.wasNew = wasNew
            self.dedupReason = dedupReason
        }
    }

    public func ingest(_ req: IngestRequest) async throws -> Result {
        try req.validate()
        // 注意：ingested_at_ns 必须在 pool.write 里打，**不能**提前到这里。
        // 否则两路并发 ingest 在 GRDB writer 队列里排队，stamp 顺序和 commit 顺序可能
        // 反过来 → /since reader 推进 cursor 后永远漏掉"晚 commit 但 ns 更小"那一行。
        let nowCallback = self.now
        let selfID = self.selfDeviceID
        let windowNs = self.crossDeviceWindowNs
        let result = try await database.pool.write { db -> (Int64, Bool, String?) in
            // 先查存在再 insert 一来更准确知道 wasNew，二来避免 INSERT OR IGNORE
            // 静默吃掉真正的冲突（比如 NOT NULL 违反）——OR IGNORE 会把所有错都忍了。
            if let existing = try Item.filter(Column("id") == req.id).fetchOne(db) {
                // 幂等重试：返回已有行的 ingested_at_ns，让 client log 一致
                return (existing.ingestedAtNs ?? 0, false, nil)
            }
            // 跨设备 Continuity dedup：req.originDevice ≠ primary 自己且窗口非 0 时，
            // 检查 primary 本机（origin=selfID）同内容是否在 ±window 内已存。命中 →
            // 这条 push 视为 Universal Clipboard 副本，ACK 拒收不入表，下游 push 状态标 acked。
            // selfDeviceID 为空（向后兼容老调用方）则跳过这层，行为退化到原样。
            if !selfID.isEmpty && windowNs > 0 && req.originDevice != selfID {
                if let near = try DuoPasteCore.Database.findNearbyOwnContent(
                    db,
                    kind: req.kind,
                    textFull: req.textFull,
                    blobSha256: req.blobSha256,
                    ownDeviceID: selfID,
                    capturedAtNs: req.capturedAtNs,
                    windowNs: windowNs
                ) {
                    return (near.ingestedAtNs ?? 0, false, "continuity-dup of \(near.id)")
                }
            }
            let ts = try DuoPasteCore.Database.nextIngestNs(db, now: nowCallback())
            let item = req.toItem(ingestedAtNs: ts)
            try item.insert(db)
            return (ts, true, nil)
        }
        return Result(id: req.id, ingestedAtNs: result.0, wasNew: result.1, dedupReason: result.2)
    }
}

import Foundation
import GRDB
import DuoPasteCore

/// `audit-push` 子命令的核心：扫本地 own-origin item 表，跟 primary `/since` 全量对账，
/// 找出 "本地有但 primary 没收到" 的行 + push_state 分布 + failed 详情。
///
/// 设计要点：
/// - 纯函数 + transport 闭包注入，方便单测（不依赖具体 HTTP client）
/// - 全量分页拉 `/since`：promote-to-primary 之前必须确认这台机器没漏推，所以接受
///   一次 audit 把 primary 走一遍的代价（通常几秒级，bytes 限于 item 元数据）
/// - 只对 `origin_device == selfDeviceID` 的行做"是否到达 primary"判定。别人 origin
///   的行在本机要么是 mirror 表（不该参与 audit），要么是 server 自己捕获的（不可能
///   "推到 primary"）
/// - 软删行也参与对账：deleted_at_ns 非空但 primary 没收到这条 → 软删事件本身丢了
public enum AuditPush {
    /// audit 结果。CLI 渲染成多行文本输出；测试直接断言字段。
    public struct Report: Sendable, Equatable {
        public struct FailedSample: Sendable, Equatable {
            public let id: String
            public let attempts: Int
            public let lastError: String?
        }
        /// 本机 own-origin item 总数（含软删）
        public let localOwnTotal: Int
        /// own-origin 按 push_state 分桶
        public let pending: Int
        public let acked: Int
        public let failed: Int
        /// primary `/since` 走完拿到的去重 id 集合大小（含 own + 其它 origin）
        public let primaryItemTotal: Int
        /// own-origin 在本机有、primary 不在 since 流里的 id 列表
        /// 截断到前 sampleLimit 条避免 1000+ 行刷屏
        public let missingOnPrimary: [String]
        /// missing 实际总数（可能 > missingOnPrimary.count）
        public let missingTotal: Int
        /// push_state=failed 的样本（含 last_push_error），最多 sampleLimit 条
        public let failedSamples: [FailedSample]

        public init(
            localOwnTotal: Int,
            pending: Int,
            acked: Int,
            failed: Int,
            primaryItemTotal: Int,
            missingOnPrimary: [String],
            missingTotal: Int,
            failedSamples: [FailedSample]
        ) {
            self.localOwnTotal = localOwnTotal
            self.pending = pending
            self.acked = acked
            self.failed = failed
            self.primaryItemTotal = primaryItemTotal
            self.missingOnPrimary = missingOnPrimary
            self.missingTotal = missingTotal
            self.failedSamples = failedSamples
        }
    }

    public enum AuditError: Error, CustomStringConvertible {
        case sinceFailed(reason: String)
        case pageLoopGuard

        public var description: String {
            switch self {
            case .sinceFailed(let r): return "/since 拉取失败: \(r)"
            case .pageLoopGuard:     return "/since 分页超过保护上限，可能是 cursor 没推进"
            }
        }
    }

    /// 跑一遍 audit。
    ///
    /// - Parameters:
    ///   - database: 本机 client DB
    ///   - selfDeviceID: 本机 device_id，用来过滤 own-origin
    ///   - fetchPage: 拉一页 `/since`。返回 `(items, nextCursor, hasMore)`；
    ///     抛 throws → 直接终止 audit。CLI 用 HTTPIngestClient 包装；测试用本地闭包
    ///   - sampleLimit: missing + failed 截取的样本数上限
    ///   - batchLimit: 每页拉的 item 上限
    /// - Returns: Report
    public static func run(
        database: DuoPasteCore.Database,
        selfDeviceID: String,
        fetchPage: @Sendable (SinceCursor, Int) async throws -> SincePageWire,
        sampleLimit: Int = 20,
        batchLimit: Int = 500
    ) async throws -> Report {
        // 1. 收集 primary 全量 id 集合
        var primaryIDs: Set<String> = []
        var cursor = SinceCursor.zero
        // 保护：单次 audit 最多翻 1024 页（默认 batchLimit=500 → 50 万 item 已超过任何
        // 真实使用场景）。cursor 没推进时及时 break，避免死循环
        for _ in 0..<1024 {
            let page = try await fetchPage(cursor, batchLimit)
            for it in page.items {
                primaryIDs.insert(it.id)
            }
            if !page.hasMore { cursor = page.nextCursor; break }
            // cursor 没推进 → server bug，主动报错避免死循环
            if page.nextCursor == cursor {
                throw AuditError.pageLoopGuard
            }
            cursor = page.nextCursor
        }

        // 2. 读本机 own-origin 全部 id + 分桶
        struct LocalRow {
            var id: String
            var pushState: String
            var pushAttempts: Int
            var lastPushError: String?
        }
        let local = try await database.pool.read { db -> [LocalRow] in
            try Row.fetchAll(db, sql: """
                SELECT id, push_state, push_attempts, last_push_error
                FROM item
                WHERE origin_device = ?
            """, arguments: [selfDeviceID]).map { row in
                LocalRow(
                    id: row["id"] ?? "",
                    pushState: row["push_state"] ?? "pending",
                    pushAttempts: row["push_attempts"] ?? 0,
                    lastPushError: row["last_push_error"]
                )
            }
        }

        var pending = 0, acked = 0, failed = 0
        var missing: [String] = []
        var failedSamples: [Report.FailedSample] = []
        for row in local {
            switch row.pushState {
            case "pending": pending += 1
            case "acked":   acked += 1
            case "failed":
                failed += 1
                if failedSamples.count < sampleLimit {
                    failedSamples.append(.init(id: row.id, attempts: row.pushAttempts,
                                               lastError: row.lastPushError))
                }
            default: break  // 防御性：未知 state 算入 total 不分桶
            }
            if !primaryIDs.contains(row.id) {
                missing.append(row.id)
            }
        }
        let missingTotal = missing.count
        return Report(
            localOwnTotal: local.count,
            pending: pending,
            acked: acked,
            failed: failed,
            primaryItemTotal: primaryIDs.count,
            missingOnPrimary: Array(missing.prefix(sampleLimit)),
            missingTotal: missingTotal,
            failedSamples: failedSamples
        )
    }
}

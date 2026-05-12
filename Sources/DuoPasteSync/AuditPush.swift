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
///
/// 两个 P2 修正（PR#4 review）：
/// 1. RemoteIngester 跨设备 Continuity dedup 路径会 ACK 而**不**把本地 id 插入 primary
///    （`crossDeviceWindowNs` 默认 5s 内同 kind/content 的 own-origin 行视为同一剪贴板事件）。
///    简单的"id 不在 primary 集合 → missing"误把这种 acked 行长期标 missing。本审计把
///    primary `/since` 里跨 origin 的 (kind, content) 项建索引，acked 且 id 不在 primary
///    但内容能在 ±windowNs 找到非自家 origin 项 → 标 `dedupAbsorbed` 而**非** missing。
/// 2. 同 id 在 primary 但状态过期：本地 pin/软删/merge 触发的 captured_at_ns 刷新通过
///    PushWorker 二次 push，但 RemoteIngester 收到同 id 直接 ACK 不更新 primary 行，
///    primary 永远停留在第一次 ingest 时的状态。同 id 还要对比 pinned / deletedAtNs /
///    capturedAtNs，diverge → 标 `staleOnPrimary`，参与 exit code。
///
/// **Lineage-aware 吸收源过滤**：单 primary deployment 下 "origin != self" 启发式没问题
/// （非 self 的 candidate 必然是当前 primary）。但跨任期场景——`duo-pasted promote-to-primary`
/// 切了 primary，老 primary 的历史 own-origin 行经 mirror→item 转移进新 primary 的 /since
/// 流——"origin != self" 会把老 primary 的所有 own 行当成合法吸收源，造成跨任期内容碰撞
/// 误判（air 推 "hello" 在 mbp 任期内，mini 的历史 "hello" 离 5s 窗内 → 被误算成 mini
/// 吸收 air，实际 mbp 才有可能吸收）。修：读 `primary_lineage` 按 row.capturedAtNs 落在
/// `[started_at_ns, ended_at_ns)` 区间确定该 push 时刻的 active primary，候选必须 origin
/// 严格 == 这个 device_id。lineage 没覆盖到时间点（空 lineage / 时间点在所有 entry 区间外
/// / 期望 primary == self 的 stale lineage 边界）→ 回退 "origin != self"，保单 primary 老
/// 行为零回归。
public enum AuditPush {
    /// audit 结果。CLI 渲染成多行文本输出；测试直接断言字段。
    public struct Report: Sendable, Equatable {
        public struct FailedSample: Sendable, Equatable {
            public let id: String
            public let attempts: Int
            public let lastError: String?
            public init(id: String, attempts: Int, lastError: String?) {
                self.id = id
                self.attempts = attempts
                self.lastError = lastError
            }
        }
        /// Continuity dedup 吸收掉的本地行：本地 id ≠ primary 上承接它的 id（不同设备的
        /// 同一剪贴板事件）。展示给操作员让其确信"acked 但 primary 没我这条"不是数据丢失。
        public struct DedupSample: Sendable, Equatable {
            public let localID: String
            public let absorbedByID: String
            public init(localID: String, absorbedByID: String) {
                self.localID = localID
                self.absorbedByID = absorbedByID
            }
        }
        /// 同 id 在 primary 但 state diverge。reasons 是人类可读的字段对比串。
        public struct StaleSample: Sendable, Equatable {
            public let id: String
            public let reasons: [String]
            public init(id: String, reasons: [String]) {
                self.id = id
                self.reasons = reasons
            }
        }
        /// 本机 own-origin item 总数（含软删）
        public let localOwnTotal: Int
        /// own-origin 按 push_state 分桶
        public let pending: Int
        public let acked: Int
        public let failed: Int
        /// primary `/since` 走完拿到的去重 id 集合大小（含 own + 其它 origin）
        public let primaryItemTotal: Int
        /// own-origin 在本机有、primary 不在 since 流里、且**不能**用 Continuity dedup 解释的
        /// id 列表（截断到 sampleLimit）
        public let missingOnPrimary: [String]
        /// missing 实际总数（可能 > missingOnPrimary.count）
        public let missingTotal: Int
        /// push_state=failed 的样本（含 last_push_error），最多 sampleLimit 条
        public let failedSamples: [FailedSample]
        /// "本地 acked 但 id 不在 primary，内容能在 primary 跨 origin 行 ±windowNs 找到"
        /// 的总数 + 样本。属于预期行为不计入 missing，但仍打印让操作员知情。
        public let dedupAbsorbed: Int
        public let dedupAbsorbedSamples: [DedupSample]
        /// dedupAbsorbed 的子集：吸收源 primary 行后来被软删（`deletedAtNs != nil`）。
        /// 语义上仍是"曾经到达过 primary"——数据没丢——但 canonical 事件已被 tombstone，
        /// 跟"活着的吸收源"性质不同：可能是误删 / 旧清理脚本 / 跨设备状态分歧。
        /// 单独成桶让操作员可见，非零时主动确认是不是预期。
        public let dedupAbsorbedThenDeleted: Int
        public let dedupAbsorbedThenDeletedSamples: [DedupSample]
        /// 同 id 存在但 state diverge（pinned / deletedAtNs / capturedAtNs > primary）的总数 + 样本。
        /// 当前 RemoteIngester 不更新已有行，这类 stale 通过 push 无法自愈，promote 前必须知道。
        public let staleTotal: Int
        public let staleSamples: [StaleSample]

        public init(
            localOwnTotal: Int,
            pending: Int,
            acked: Int,
            failed: Int,
            primaryItemTotal: Int,
            missingOnPrimary: [String],
            missingTotal: Int,
            failedSamples: [FailedSample],
            dedupAbsorbed: Int,
            dedupAbsorbedSamples: [DedupSample],
            dedupAbsorbedThenDeleted: Int,
            dedupAbsorbedThenDeletedSamples: [DedupSample],
            staleTotal: Int,
            staleSamples: [StaleSample]
        ) {
            self.localOwnTotal = localOwnTotal
            self.pending = pending
            self.acked = acked
            self.failed = failed
            self.primaryItemTotal = primaryItemTotal
            self.missingOnPrimary = missingOnPrimary
            self.missingTotal = missingTotal
            self.failedSamples = failedSamples
            self.dedupAbsorbed = dedupAbsorbed
            self.dedupAbsorbedSamples = dedupAbsorbedSamples
            self.dedupAbsorbedThenDeleted = dedupAbsorbedThenDeleted
            self.dedupAbsorbedThenDeletedSamples = dedupAbsorbedThenDeletedSamples
            self.staleTotal = staleTotal
            self.staleSamples = staleSamples
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
    ///   - selfDeviceID: 本机 device_id，用来过滤 own-origin 以及把 Continuity dedup 限制
    ///     在跨 origin 匹配上（避免误把本机自家两条同内容行算成互相吸收）
    ///   - fetchPage: 拉一页 `/since`。返回 `(items, nextCursor, hasMore)`；
    ///     抛 throws → 直接终止 audit。CLI 用 HTTPIngestClient 包装；测试用本地闭包
    ///   - sampleLimit: missing / failed / dedup / stale 各自截取的样本数上限
    ///   - batchLimit: 每页拉的 item 上限
    ///   - dedupWindowNs: 跟 RemoteIngester.crossDeviceWindowNs 同义；用作 Continuity 内容
    ///     匹配的时间窗。默认 5s = 5_000_000_000ns，与 RemoteIngester 默认一致
    /// - Returns: Report
    public static func run(
        database: DuoPasteCore.Database,
        selfDeviceID: String,
        fetchPage: @Sendable (SinceCursor, Int) async throws -> SincePageWire,
        sampleLimit: Int = 20,
        batchLimit: Int = 500,
        dedupWindowNs: Int64 = 5_000_000_000
    ) async throws -> Report {
        // 1. 收集 primary 全量 items：按 id 索引（state 对比）+ 按 (kind,content) 索引（dedup 匹配）
        var primaryByID: [String: Item] = [:]
        // key = "<kind>|sha:<sha>" 或 "<kind>|txt:<textFull>"，value 含 originDevice 用于跨 origin 过滤
        var primaryByContent: [String: [ContentEntry]] = [:]
        var cursor = SinceCursor.zero
        // 保护：单次 audit 最多翻 1024 页（默认 batchLimit=500 → 50 万 item 已超过任何
        // 真实使用场景）。cursor 没推进时及时 break，避免死循环
        for _ in 0..<1024 {
            let page = try await fetchPage(cursor, batchLimit)
            for it in page.items {
                primaryByID[it.id] = it
                if let key = contentKey(kind: it.kind, blobSha256: it.blobSha256, textFull: it.textFull) {
                    primaryByContent[key, default: []].append(
                        ContentEntry(id: it.id, originDevice: it.originDevice,
                                     capturedAtNs: it.capturedAtNs,
                                     deletedAtNs: it.deletedAtNs)
                    )
                }
            }
            if !page.hasMore { break }
            // cursor 没推进 → server bug，主动报错避免死循环
            if page.nextCursor == cursor {
                throw AuditError.pageLoopGuard
            }
            cursor = page.nextCursor
        }

        // 2a. 读 primary_lineage 全部行（一般空；v5 后只有 promote-to-primary 写）。
        //    用来判定每条 own-origin 行被 push 时刻的 active primary device_id——只有
        //    那个 device 的 own 行才可能是 Continuity dedup 吸收源。
        let lineage = try await database.pool.read { db -> [LineageEntry] in
            try Row.fetchAll(db, sql: """
                SELECT device_id, started_at_ns, ended_at_ns FROM primary_lineage
            """).map { row in
                LineageEntry(
                    deviceID: row["device_id"] ?? "",
                    startedAtNs: row["started_at_ns"] ?? 0,
                    endedAtNs: row["ended_at_ns"]
                )
            }
        }

        // 2b. 读本机 own-origin 全部行。额外取 kind / content / capturedAt / pinned / deletedAt 用于
        //    dedup 内容匹配 + 同 id state 对比
        let local = try await database.pool.read { db -> [LocalRow] in
            try Row.fetchAll(db, sql: """
                SELECT id, push_state, push_attempts, last_push_error,
                       kind, text_full, blob_sha256, captured_at_ns, pinned, deleted_at_ns
                FROM item
                WHERE origin_device = ?
            """, arguments: [selfDeviceID]).map { row in
                let kindRaw: String = row["kind"] ?? "text"
                return LocalRow(
                    id: row["id"] ?? "",
                    pushState: row["push_state"] ?? "pending",
                    pushAttempts: row["push_attempts"] ?? 0,
                    lastPushError: row["last_push_error"],
                    kind: ItemKind(rawValue: kindRaw) ?? .text,
                    textFull: row["text_full"],
                    blobSha256: row["blob_sha256"],
                    capturedAtNs: row["captured_at_ns"] ?? 0,
                    pinned: (row["pinned"] ?? 0) != 0,
                    deletedAtNs: row["deleted_at_ns"]
                )
            }
        }

        var pending = 0, acked = 0, failed = 0
        var missing: [String] = []
        var failedSamples: [Report.FailedSample] = []
        var dedupSamples: [Report.DedupSample] = []
        var dedupDeletedSamples: [Report.DedupSample] = []
        var staleSamples: [Report.StaleSample] = []
        var dedupCount = 0
        var dedupDeletedCount = 0
        var staleCount = 0

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

            if let primaryItem = primaryByID[row.id] {
                // 同 id：state 对比。RemoteIngester 不更新已有行 → 这类 diverge 通过 push
                // 不能自愈，必须让操作员看到
                var reasons: [String] = []
                if row.pinned != primaryItem.pinned {
                    reasons.append("pinned: local=\(row.pinned) primary=\(primaryItem.pinned)")
                }
                if row.deletedAtNs != primaryItem.deletedAtNs {
                    reasons.append("deleted_at_ns: local=\(formatOptInt64(row.deletedAtNs)) primary=\(formatOptInt64(primaryItem.deletedAtNs))")
                }
                // 只在 local capturedAt > primary 时报：表示本地有 merge 刷新但 primary 没收到。
                // 反向不报——primary 可能有自家 merge 行为，超出 audit 的 "我推的东西到没到" 范围
                if row.capturedAtNs > primaryItem.capturedAtNs {
                    reasons.append("captured_at_ns: local=\(row.capturedAtNs) primary=\(primaryItem.capturedAtNs)")
                }
                if !reasons.isEmpty {
                    staleCount += 1
                    if staleSamples.count < sampleLimit {
                        staleSamples.append(.init(id: row.id, reasons: reasons))
                    }
                }
            } else {
                // id 不在 primary：可能是 Continuity dedup 吸收（acked 且跨 origin 同内容匹配），
                // 或真 missing（pending/failed 未推送，或 acked 但找不到吸收源 → 可能 primary 丢数据）
                var absorbedEntry: ContentEntry? = nil
                if row.pushState == "acked",
                   let key = contentKey(kind: row.kind, blobSha256: row.blobSha256, textFull: row.textFull) {
                    let candidates = primaryByContent[key] ?? []
                    let floor = row.capturedAtNs &- dedupWindowNs
                    let ceiling = row.capturedAtNs &+ dedupWindowNs
                    // RemoteIngester.crossDeviceWindowNs 契约：dedup 只对 origin != 推送方
                    // 的本地 own-origin 行触发。Lineage-aware 路径：用 row.capturedAtNs 当
                    // push 时刻的 proxy 查 lineage 找该时刻 active primary，候选必须 origin
                    // == 这个 device_id（严格匹配；跨任期碰撞被挡掉）。lineage 没覆盖（空
                    // lineage / 早于所有任期 / 期望 primary == self 的 stale lineage 边界）
                    // → 回退 origin != self 启发式保单 primary 老行为零回归。
                    let expectedAbsorberOrigin = Self.activePrimaryDeviceID(
                        at: row.capturedAtNs, lineage: lineage, selfDeviceID: selfDeviceID
                    )
                    absorbedEntry = candidates.first(where: { entry in
                        let originOK: Bool
                        if let expected = expectedAbsorberOrigin {
                            originOK = entry.originDevice == expected
                        } else {
                            originOK = entry.originDevice != selfDeviceID
                        }
                        return originOK
                            && entry.capturedAtNs >= floor
                            && entry.capturedAtNs <= ceiling
                    })
                }
                if let absorbedEntry {
                    // /since 会下发软删行（tombstone）。被 tombstone 的吸收源在性质上跟"活着的
                    // 吸收源"不同——前者 canonical 事件已被显式删，可能是误删 / 旧清理脚本 /
                    // 跨设备 pin 分歧。分桶让操作员可见，不混到 dedupAbsorbed 主计数里
                    if absorbedEntry.deletedAtNs != nil {
                        dedupDeletedCount += 1
                        if dedupDeletedSamples.count < sampleLimit {
                            dedupDeletedSamples.append(.init(localID: row.id, absorbedByID: absorbedEntry.id))
                        }
                    } else {
                        dedupCount += 1
                        if dedupSamples.count < sampleLimit {
                            dedupSamples.append(.init(localID: row.id, absorbedByID: absorbedEntry.id))
                        }
                    }
                } else {
                    missing.append(row.id)
                }
            }
        }
        return Report(
            localOwnTotal: local.count,
            pending: pending,
            acked: acked,
            failed: failed,
            primaryItemTotal: primaryByID.count,
            missingOnPrimary: Array(missing.prefix(sampleLimit)),
            missingTotal: missing.count,
            failedSamples: failedSamples,
            dedupAbsorbed: dedupCount,
            dedupAbsorbedSamples: dedupSamples,
            dedupAbsorbedThenDeleted: dedupDeletedCount,
            dedupAbsorbedThenDeletedSamples: dedupDeletedSamples,
            staleTotal: staleCount,
            staleSamples: staleSamples
        )
    }

    // MARK: - private

    private struct LocalRow {
        let id: String
        let pushState: String
        let pushAttempts: Int
        let lastPushError: String?
        let kind: ItemKind
        let textFull: String?
        let blobSha256: String?
        let capturedAtNs: Int64
        let pinned: Bool
        let deletedAtNs: Int64?
    }

    private struct ContentEntry {
        let id: String
        let originDevice: String
        let capturedAtNs: Int64
        let deletedAtNs: Int64?
    }

    /// `primary_lineage` 表的内存形态。`startedAtNs == 0` 表示"未知何时开始"
    /// （`Admin.promoteToPrimary` 闭老 primary 任期时使用的 sentinel）。
    /// `endedAtNs == nil` 表示任期当前仍开（self 的开新任期行）。
    private struct LineageEntry {
        let deviceID: String
        let startedAtNs: Int64
        let endedAtNs: Int64?
    }

    /// 给定一个 push 时刻 `t`，从 lineage 里挑出覆盖该时刻的 active primary。
    /// 覆盖规则：`(startedAtNs == 0 || startedAtNs <= t) && (endedAtNs == nil || t < endedAtNs)`
    ///
    /// 返回 nil 的几种情况，调用方都应该回退到 "origin != selfDeviceID" 启发式：
    /// - lineage 空（最常见，从未 promote 过）
    /// - 时间点不落在任何 [started, ended) 区间内
    /// - 期望 primary == selfDeviceID 的 stale lineage（self 曾 promote 过、又手动改 config
    ///   回 client → 本地 lineage 仍记 self 任期开着）。严格匹配 self 会让所有 candidate 都
    ///   被拒，把合法吸收源误算成 missing，因此 stale 边界落到回退路径
    ///
    /// 多 entry 覆盖同一时间点时（不规范的 lineage，但防御性处理）取 startedAtNs 最大的
    /// 那条——最具体的开始时间最可能反映真实任期切换点。
    private static func activePrimaryDeviceID(
        at t: Int64, lineage: [LineageEntry], selfDeviceID: String
    ) -> String? {
        let active = lineage
            .filter { e in
                let startedOK = e.startedAtNs == 0 || e.startedAtNs <= t
                let endedOK = e.endedAtNs == nil || t < e.endedAtNs!
                return startedOK && endedOK
            }
            .max(by: { $0.startedAtNs < $1.startedAtNs })
        guard let device = active?.deviceID, !device.isEmpty, device != selfDeviceID else {
            return nil
        }
        return device
    }

    /// 同 `Database.findNearbyOwnContent` 的内容指纹规则：blob 类型按 sha256 比对，
    /// text 类型按 text_full 全等比对。两者都不给 → 内容不可识别（典型是空剪贴），跳过 dedup 匹配。
    private static func contentKey(kind: ItemKind, blobSha256: String?, textFull: String?) -> String? {
        if let sha = blobSha256, !sha.isEmpty {
            return "\(kind.rawValue)|sha:\(sha)"
        }
        if let txt = textFull, !txt.isEmpty {
            return "\(kind.rawValue)|txt:\(txt)"
        }
        return nil
    }

    private static func formatOptInt64(_ v: Int64?) -> String {
        guard let v else { return "nil" }
        return String(v)
    }
}

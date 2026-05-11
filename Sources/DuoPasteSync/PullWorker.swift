import Foundation
import GRDB
import DuoPasteCore

/// 周期把 primary 的 item 表增量拉到本地 `item_mirror`，让 client 搜索走纯本地 FTS。
///
/// 设计要点：
/// - 单 actor 串行，避免并发写 item_mirror 抢库锁
/// - 每 tick：`/health` 拿当前 primary device_id（防止换 primary 后用错 cursor）→
///   `/since` 一页 → INSERT OR REPLACE INTO item_mirror（跳过 origin=self）→
///   更新 pull_cursor → has_more 立刻再来一轮，否则 sleep `intervalSec`
/// - 「跳过 origin=self」让 client 搜索不用 dedup（本机捕获在 `item`，他机捕获在
///   `item_mirror`，永不重叠）
/// - 「primary 换了」检测：persisted primary_id 跟 /health 不一致 → 清空 mirror + cursor
///   重拉。这是 plan moonlit-wave.md §c 的 promote-follower 流程要求
/// - `lastPullNs` 通过 `MirrorStatus` 暴露给 SearchProvider，让 search 决定是否走 union
///   本地路径（绕开远端）
public actor PullWorker {
    public struct Config: Sendable {
        public var intervalSec: TimeInterval
        public var batchLimit: Int
        public var initialBackoffSec: TimeInterval
        public var maxBackoffSec: TimeInterval

        public init(
            intervalSec: TimeInterval = 30,
            batchLimit: Int = 500,
            initialBackoffSec: TimeInterval = 2,
            maxBackoffSec: TimeInterval = 120
        ) {
            self.intervalSec = intervalSec
            self.batchLimit = batchLimit
            self.initialBackoffSec = initialBackoffSec
            self.maxBackoffSec = maxBackoffSec
        }

        public static let `default` = Config()
    }

    private let database: DuoPasteCore.Database
    private let transport: SinceTransport
    private let selfDeviceID: String
    private let mirrorStatus: MirrorStatus
    private let config: Config
    private let nowNs: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void

    private var runTask: Task<Void, Never>?
    private var currentSleep: Task<Void, Error>?
    private var consecutiveTransientFailures = 0

    public init(
        database: DuoPasteCore.Database,
        transport: SinceTransport,
        selfDeviceID: String,
        mirrorStatus: MirrorStatus,
        config: Config = .default,
        nowNs: @escaping @Sendable () -> Int64 = { Clock.nowNs() },
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("pull: \(msg)\n".utf8))
        }
    ) {
        self.database = database
        self.transport = transport
        self.selfDeviceID = selfDeviceID
        self.mirrorStatus = mirrorStatus
        self.config = config
        self.nowNs = nowNs
        self.log = log
    }

    public func start() {
        guard runTask == nil else { return }
        self.runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        currentSleep?.cancel()
        currentSleep = nil
        runTask?.cancel()
        runTask = nil
    }

    /// 外部（比如手动「立即同步」入口）通知：跳过当前 sleep。
    /// 用法和 PushWorker.wake() 一致。
    public nonisolated func wake() {
        Task { await self.cancelCurrentSleep() }
    }

    private func cancelCurrentSleep() {
        currentSleep?.cancel()
    }

    private func runLoop() async {
        log("worker started · self=\(selfDeviceID) · interval=\(Int(config.intervalSec))s")
        while !Task.isCancelled {
            let r = await tick()

            // 标 lastPullNs 的语义：「mirror 已严格追平 primary」——only when has_more=false 且无 transient
            // 若 has_more=true（中途）或有 transient，保持原值，SearchProvider 可能仍能看到旧 lastPullNs
            if !r.hadTransient && !r.hasMore {
                mirrorStatus.setLastPullNs(nowNs())
            }

            if r.hadTransient {
                consecutiveTransientFailures += 1
            } else {
                consecutiveTransientFailures = 0
            }

            let sleepSec: TimeInterval
            if r.hadTransient {
                sleepSec = min(
                    config.initialBackoffSec * pow(2.0, Double(consecutiveTransientFailures - 1)),
                    config.maxBackoffSec
                )
            } else if r.hasMore {
                sleepSec = 0  // 立刻接下一页，赶上为止
            } else {
                sleepSec = config.intervalSec
            }

            if r.applied > 0 || r.hadTransient {
                log("tick applied=\(r.applied) hasMore=\(r.hasMore) transient=\(r.hadTransient) sleep=\(sleepSec)")
            }

            if sleepSec > 0 {
                let task = Task {
                    try await Task.sleep(nanoseconds: UInt64(sleepSec * 1_000_000_000))
                }
                self.currentSleep = task
                _ = try? await task.value   // wake() / stop() 取消时抛 CancellationError，忽略
                self.currentSleep = nil
            }
        }
        log("worker stopped")
    }

    private struct TickResult: Sendable {
        var applied: Int = 0    // 实际写入 item_mirror 的行数（已扣除 origin=self skip）
        var hasMore: Bool = false
        var hadTransient: Bool = false
    }

    private func tick() async -> TickResult {
        var result = TickResult()

        // 1. /health：拿当前 primary device_id
        let healthRes: PrimaryHealthResult
        do {
            healthRes = try await transport.fetchPrimaryHealth()
        } catch is CancellationError {
            return result
        } catch {
            log("health threw: \(error)")
            result.hadTransient = true
            return result
        }
        let currentPrimaryID: String
        switch healthRes.outcome {
        case .ok(let id, _):
            // 拒绝空 device_id：会污染 pull_cursor.primary_id 主键 + 在 reconcile 里假阳性触发
            // mirror 清空。理论上 server 永远不会返回空（DeviceID.loadOrCreate 保证），
            // 但万一旧版 / 篡改 / 网络中间件改包，guard 在这里。
            guard !id.isEmpty else {
                log("health 返回空 device_id，当 transient 跳过")
                result.hadTransient = true
                return result
            }
            currentPrimaryID = id
        case .unreachable(let r):
            log("health unreachable: \(r)")
            result.hadTransient = true
            return result
        case .rejected(let r):
            log("health rejected: \(r)")
            result.hadTransient = true
            return result
        }
        mirrorStatus.setPrimaryDeviceID(currentPrimaryID)

        // 2. 检测 primary 换了 → 清空 mirror + cursor
        do {
            try await reconcilePrimary(currentPrimaryID: currentPrimaryID)
        } catch {
            log("reconcile primary failed: \(error)")
            result.hadTransient = true
            return result
        }

        // 3. 读 cursor
        let cursor: SinceCursor
        do {
            cursor = try await loadCursor(primaryID: currentPrimaryID)
        } catch {
            log("load cursor failed: \(error)")
            result.hadTransient = true
            return result
        }

        // 4. /since
        let sinceRes: RemoteSinceResult
        do {
            sinceRes = try await transport.fetchSince(cursor: cursor, limit: config.batchLimit)
        } catch is CancellationError {
            return result
        } catch {
            log("since threw: \(error)")
            result.hadTransient = true
            return result
        }
        switch sinceRes.outcome {
        case .ok(let page):
            do {
                result.applied = try await applyPage(page, primaryID: currentPrimaryID)
                result.hasMore = page.hasMore
            } catch {
                log("apply page failed: \(error)")
                result.hadTransient = true
            }
        case .unreachable(let r):
            log("since unreachable: \(r)")
            result.hadTransient = true
        case .rejected(let r):
            log("since rejected: \(r)")
            result.hadTransient = true
        }
        return result
    }

    /// 比对 persisted primary_id 跟新探测到的 currentPrimaryID。不一致 → 清空 mirror + cursor。
    private func reconcilePrimary(currentPrimaryID: String) async throws {
        let persisted = try await database.pool.read { db -> String? in
            try String.fetchOne(db, sql: "SELECT primary_id FROM pull_cursor LIMIT 1")
        }
        guard let persisted else { return }   // 首次启动 / 已被清空 → 啥也不做
        if persisted == currentPrimaryID { return }
        log("primary device changed (\(persisted) → \(currentPrimaryID))，重置 mirror + cursor")
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM item_mirror")
            try db.execute(sql: "DELETE FROM pull_cursor")
        }
    }

    private func loadCursor(primaryID: String) async throws -> SinceCursor {
        try await database.pool.read { db -> SinceCursor in
            let row = try Row.fetchOne(db, sql: """
                SELECT cursor_ns, cursor_id FROM pull_cursor WHERE primary_id = ?
            """, arguments: [primaryID])
            guard let row else { return .zero }
            let ns: Int64 = row["cursor_ns"] ?? 0
            let id: String = row["cursor_id"] ?? ""
            return SinceCursor(ingestedAtNs: ns, id: id)
        }
    }

    /// 写 item_mirror + 更新 pull_cursor，单事务。返回实际入表行数（扣除 origin=self skip）。
    private func applyPage(_ page: SincePageWire, primaryID: String) async throws -> Int {
        let device = selfDeviceID
        let now = nowNs()
        return try await database.pool.write { db -> Int in
            var written = 0
            for item in page.items {
                // 跳过自家 origin —— 已经在 item 表里，搜索 UNION 时不重叠
                if item.originDevice == device { continue }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO item_mirror
                      (id, origin_device, captured_at_ns, ingested_at_ns, kind,
                       source_app, source_app_name, preview, text_full,
                       blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
                       mirrored_at_ns)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    item.id,
                    item.originDevice,
                    item.capturedAtNs,
                    item.ingestedAtNs,
                    item.kind.rawValue,
                    item.sourceApp,
                    item.sourceAppName,
                    item.preview,
                    item.textFull,
                    item.blobSha256,
                    item.blobSize,
                    item.blobMime,
                    item.pinned ? 1 : 0,
                    item.deletedAtNs,
                    now,
                ])
                written += 1
            }
            // UPSERT cursor。SQLite 3.24+ ON CONFLICT 语法，macOS 14 自带 SQLite > 3.24 OK。
            try db.execute(sql: """
                INSERT INTO pull_cursor (primary_id, cursor_ns, cursor_id, updated_at_ns)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(primary_id) DO UPDATE SET
                    cursor_ns = excluded.cursor_ns,
                    cursor_id = excluded.cursor_id,
                    updated_at_ns = excluded.updated_at_ns
            """, arguments: [primaryID, page.nextCursor.ingestedAtNs, page.nextCursor.id, now])
            return written
        }
    }
}

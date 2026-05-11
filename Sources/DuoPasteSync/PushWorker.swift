import Foundation
import GRDB
import DuoPasteCore

/// 把本机 origin 的 pending item 推到 primary，处理 ack / 失败 / 重试。
///
/// 设计：
/// - 单 actor 串行，避免并发写 push_state 抢库锁
/// - 一个 tick：捞所有 `push_state='pending'` → 顺序逐条 POST → 更新状态
/// - 没有 pending 时 sleep `idleIntervalSec`；连续失败 N 次进入指数退避，
///   最大 `maxBackoffSec`
/// - `wake()` 由 AppDelegate 在捕获新条目时调用，缩短延迟到 ~0
/// - 阈值：`maxAttempts` 次仍 transient 失败 → 标 failed，等用户手动重试
public actor PushWorker {
    public struct Config: Sendable {
        public var idleIntervalSec: TimeInterval
        public var initialBackoffSec: TimeInterval
        public var maxBackoffSec: TimeInterval
        public var maxAttempts: Int
        public var batchSize: Int

        public init(
            idleIntervalSec: TimeInterval = 5,
            initialBackoffSec: TimeInterval = 1,
            maxBackoffSec: TimeInterval = 300,
            maxAttempts: Int = 50,
            batchSize: Int = 100
        ) {
            self.idleIntervalSec = idleIntervalSec
            self.initialBackoffSec = initialBackoffSec
            self.maxBackoffSec = maxBackoffSec
            self.maxAttempts = maxAttempts
            self.batchSize = batchSize
        }

        public static let `default` = Config()
    }

    private let database: DuoPasteCore.Database
    private let blobs: BlobStore
    private let transport: IngestTransport
    private let originDevice: String
    private let config: Config
    private let log: @Sendable (String) -> Void

    private var runTask: Task<Void, Never>?
    private var currentSleep: Task<Void, Error>?
    private var consecutiveTransientFailures = 0

    public init(
        database: DuoPasteCore.Database,
        blobs: BlobStore,
        transport: IngestTransport,
        originDevice: String,
        config: Config = .default,
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("push: \(msg)\n".utf8))
        }
    ) {
        self.database = database
        self.blobs = blobs
        self.transport = transport
        self.originDevice = originDevice
        self.config = config
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

    /// 外部（AppDelegate 捕获回调）通知：可能有新 pending。
    /// 实现：取消当前正在睡的 sleep task，让 runLoop 提前进入下一 tick。
    /// 没有当前 sleep → 下一次 tick 自然会看到新 pending。
    public nonisolated func wake() {
        Task { await self.cancelCurrentSleep() }
    }

    private func cancelCurrentSleep() {
        currentSleep?.cancel()
    }

    private func runLoop() async {
        log("worker started · originDevice=\(originDevice)")
        while !Task.isCancelled {
            let drained = await tick()
            let sleepSec: TimeInterval
            if drained.anyTransient {
                // 退避按 consecutive 次数，封顶 maxBackoffSec
                let backoff = min(
                    config.initialBackoffSec * pow(2.0, Double(consecutiveTransientFailures - 1)),
                    config.maxBackoffSec
                )
                sleepSec = backoff
            } else {
                sleepSec = config.idleIntervalSec
            }
            let task = Task {
                try await Task.sleep(nanoseconds: UInt64(sleepSec * 1_000_000_000))
            }
            self.currentSleep = task
            _ = try? await task.value    // wake() 取消时会抛 CancellationError，忽略
            self.currentSleep = nil
        }
        log("worker stopped")
    }

    private struct TickResult: Sendable {
        var acked: Int = 0
        var rejected: Int = 0
        var transient: Int = 0
        var anyTransient: Bool { transient > 0 }
    }

    private func tick() async -> TickResult {
        var result = TickResult()
        let pending: [Item]
        do {
            pending = try await fetchPending()
        } catch {
            log("fetch pending failed: \(error)")
            return result
        }
        if pending.isEmpty { return result }

        for item in pending {
            if Task.isCancelled { break }

            // 图片 / 文件类 item：先把 blob 推上去再 /ingest。
            // 顺序很重要——反过来会让 primary 出现悬空 blob_sha256 引用。
            if let sha = item.blobSha256, !sha.isEmpty {
                let blobOutcome = await pushBlob(sha256: sha)
                switch blobOutcome {
                case .acked:
                    break  // 继续到 ingest
                case .rejected(let reason):
                    do {
                        try await markFailed(id: item.id, reason: "blob rejected: \(reason)")
                        result.rejected += 1
                        log("blob rejected for \(item.id): \(reason)")
                    } catch {
                        log("mark blob-rejected failed for \(item.id): \(error)")
                    }
                    continue
                case .transient(let reason):
                    do {
                        let attempts = try await bumpAttempt(id: item.id, reason: "blob: \(reason)")
                        if attempts >= config.maxAttempts {
                            try await markFailed(id: item.id, reason: "blob max attempts: \(reason)")
                            result.rejected += 1
                        } else {
                            result.transient += 1
                        }
                    } catch {
                        log("bump blob-transient failed for \(item.id): \(error)")
                    }
                    continue
                }
            }

            let req = Self.makeRequest(from: item)
            let outcome = (try? await transport.ingest(req).outcome)
                ?? .transient(reason: "transport threw")
            switch outcome {
            case .acked(let ingestedAtNs, _):
                do {
                    try await markAcked(id: item.id, ingestedAtNs: ingestedAtNs)
                    result.acked += 1
                } catch {
                    log("mark acked failed for \(item.id): \(error)")
                }
            case .rejected(let reason):
                do {
                    try await markFailed(id: item.id, reason: "rejected: \(reason)")
                    result.rejected += 1
                    log("rejected \(item.id): \(reason)")
                } catch {
                    log("mark rejected failed for \(item.id): \(error)")
                }
            case .transient(let reason):
                do {
                    let attempts = try await bumpAttempt(id: item.id, reason: reason)
                    if attempts >= config.maxAttempts {
                        try await markFailed(id: item.id, reason: "max attempts (\(attempts)): \(reason)")
                        result.rejected += 1
                        log("giving up on \(item.id) after \(attempts) attempts")
                    } else {
                        result.transient += 1
                    }
                } catch {
                    log("bump attempt failed for \(item.id): \(error)")
                }
            }
        }
        if result.transient > 0 {
            consecutiveTransientFailures += 1
        } else if result.acked > 0 {
            consecutiveTransientFailures = 0
        }
        if result.acked + result.rejected + result.transient > 0 {
            log("tick acked=\(result.acked) rejected=\(result.rejected) transient=\(result.transient)")
        }
        return result
    }

    private func fetchPending() async throws -> [Item] {
        let limit = config.batchSize
        let device = originDevice
        return try await database.pool.read { db in
            try Item
                .filter(Column("push_state") == PushState.pending.rawValue)
                .filter(Column("origin_device") == device)
                .order(Column("captured_at_ns").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    private func markAcked(id: String, ingestedAtNs: Int64?) async throws {
        try await database.pool.write { db in
            try db.execute(sql: """
                UPDATE item
                SET push_state = ?,
                    ingested_at_ns = COALESCE(?, ingested_at_ns),
                    last_push_error = NULL,
                    push_attempts = push_attempts + 1
                WHERE id = ?
            """, arguments: [PushState.acked.rawValue, ingestedAtNs, id])
        }
    }

    private func markFailed(id: String, reason: String) async throws {
        try await database.pool.write { db in
            try db.execute(sql: """
                UPDATE item
                SET push_state = ?,
                    last_push_error = ?,
                    push_attempts = push_attempts + 1
                WHERE id = ?
            """, arguments: [PushState.failed.rawValue, reason, id])
        }
    }

    private func bumpAttempt(id: String, reason: String) async throws -> Int {
        try await database.pool.write { db in
            try db.execute(sql: """
                UPDATE item
                SET push_attempts = push_attempts + 1,
                    last_push_error = ?
                WHERE id = ?
            """, arguments: [reason, id])
            return try Int.fetchOne(db,
                sql: "SELECT push_attempts FROM item WHERE id = ?",
                arguments: [id]) ?? 0
        }
    }

    private func pushBlob(sha256: String) async -> IngestResult.Outcome {
        // 本地读 blob bytes
        let data: Data?
        do {
            data = try blobs.read(sha256: sha256)
        } catch {
            // 读盘错（IO 损坏）→ 当 transient，等盘可能恢复；不直接 reject
            return .transient(reason: "local blob read: \(error.localizedDescription)")
        }
        guard let data else {
            // blob 在 DB 里有引用但本地文件不见了 —— 数据不一致，重试无意义
            return .rejected(reason: "local blob missing for sha256=\(sha256)")
        }
        let res = (try? await transport.putBlob(sha256: sha256, data: data))
            ?? IngestResult(outcome: .transient(reason: "putBlob threw"))
        return res.outcome
    }

    static func makeRequest(from item: Item) -> IngestRequest {
        IngestRequest(
            id: item.id,
            originDevice: item.originDevice,
            capturedAtNs: item.capturedAtNs,
            kind: item.kind,
            sourceApp: item.sourceApp,
            sourceAppName: item.sourceAppName,
            preview: item.preview,
            textFull: item.textFull,
            blobSha256: item.blobSha256,
            blobSize: item.blobSize,
            blobMime: item.blobMime,
            pinned: item.pinned,
            deletedAtNs: item.deletedAtNs
        )
    }
}

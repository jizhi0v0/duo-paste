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
        /// 跨设备 Continuity dedup 时间窗（纳秒）。0 = 关闭这个 dedup 层。
        /// 配合 RemoteIngester 的同名字段，PullWorker 写 item_mirror 前查本机 item 表
        /// 有无 origin=self 同内容在窗口内已存——命中则 skip mirror 入库，UI union
        /// 看到的就是单条 own。Universal Clipboard 同步通常 < 1s，5s buffer 充足。
        public var crossDeviceDedupWindowNs: Int64
        /// 时钟偏移告警阈值（毫秒）。|primary.now_ms - local.now_ms| 超过这个值 →
        /// log warn + 通过 MirrorStatus 暴露给 UI banner。
        ///
        /// HMAC 签名容忍 ±5 分钟 skew（300_000 ms），所以 30s 是"健康但要注意"的早期信号。
        /// 用户场景：mini 长期休眠 / 路由器走不同 NTP 源 / 虚机时钟漂移；这些都不至于
        /// 立刻 401，但快到边界就该提醒了。
        public var clockSkewWarnMs: Int64

        /// `pull.eager_blobs=true` 时 PullWorker 拉完一页 metadata 后顺路 GET 这一页里
        /// 本机 BlobStore 没字节的 blob_sha256（去重）。失败不抛、不阻塞 cursor 推进——
        /// 下次 tick 拉同样的 sha 再试。**默认 false**（lazy 路径覆盖 paste-back 即可，
        /// eager 是图片密集 + 大盘场景的可选优化）
        public var eagerBlobs: Bool

        public init(
            intervalSec: TimeInterval = 30,
            batchLimit: Int = 500,
            initialBackoffSec: TimeInterval = 2,
            maxBackoffSec: TimeInterval = 120,
            crossDeviceDedupWindowNs: Int64 = 5_000_000_000,
            clockSkewWarnMs: Int64 = 30_000,
            eagerBlobs: Bool = false
        ) {
            self.intervalSec = intervalSec
            self.batchLimit = batchLimit
            self.initialBackoffSec = initialBackoffSec
            self.maxBackoffSec = maxBackoffSec
            self.crossDeviceDedupWindowNs = crossDeviceDedupWindowNs
            self.clockSkewWarnMs = clockSkewWarnMs
            self.eagerBlobs = eagerBlobs
        }

        public static let `default` = Config()
    }

    private let database: DuoPasteCore.Database
    private let transport: SinceTransport
    private let selfDeviceID: String
    private let mirrorStatus: MirrorStatus
    /// 跨设备 paste-echo 抑制：本机 pasteBack 写 NSPasteboard 后通过 Continuity 反弹到对端
    /// 又被对端 watcher capture 推回来时，PullWorker 在 applyPage 里查这个 set，命中 skip。
    /// nil = 抑制功能未启用（standalone / 测试不传）。
    private let pasteSuppressions: PasteSuppressionSet?
    /// eager_blobs=true 时用于拉 blob 字节。nil → 即使 config.eagerBlobs=true 也 no-op
    /// （让测试可以独立控制；生产 AppDelegate 始终注入 HTTPIngestClient）
    private let blobFetcher: BlobFetcher?
    /// eager_blobs=true 时把拉回的字节写入这里。nil → 同 blobFetcher
    private let blobs: BlobStore?
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
        pasteSuppressions: PasteSuppressionSet? = nil,
        blobFetcher: BlobFetcher? = nil,
        blobs: BlobStore? = nil,
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
        self.pasteSuppressions = pasteSuppressions
        self.blobFetcher = blobFetcher
        self.blobs = blobs
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

            if r.applied > 0 || r.skippedDedup > 0 || r.skippedPasteEcho > 0 || r.hadTransient {
                log("tick applied=\(r.applied) dedup-skip=\(r.skippedDedup) paste-echo-skip=\(r.skippedPasteEcho) hasMore=\(r.hasMore) transient=\(r.hadTransient) sleep=\(sleepSec)")
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
        var applied: Int = 0    // 实际写入 item_mirror 的行数（已扣除 origin=self + 跨设备 dedup skip + paste-echo skip）
        var skippedDedup: Int = 0  // 跨设备 Continuity dedup skip 数（诊断用，本机已有同内容 own item）
        var skippedPasteEcho: Int = 0  // PasteSuppressionSet 命中 skip 数（本机刚 paste 过，对端 Continuity 反弹回来）
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
        let primaryNowMs: Int64
        switch healthRes.outcome {
        case .ok(let id, let nowMs):
            // 拒绝空 device_id：会污染 pull_cursor.primary_id 主键 + 在 reconcile 里假阳性触发
            // mirror 清空。理论上 server 永远不会返回空（DeviceID.loadOrCreate 保证），
            // 但万一旧版 / 篡改 / 网络中间件改包，guard 在这里。
            guard !id.isEmpty else {
                log("health 返回空 device_id，当 transient 跳过")
                result.hadTransient = true
                return result
            }
            currentPrimaryID = id
            primaryNowMs = nowMs
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

        // 1b. 时钟偏移 sanity check。primary now_ms vs local wall-clock，单位毫秒（signed）。
        // 用本地 wall-clock（nowNs / 1e6）跟 primary now_ms 比；rountrip 半程当 0，对 30s 阈值
        // 影响 < 100ms 量级可忽略。
        let localNowMs = nowNs() / 1_000_000
        let skew = primaryNowMs - localNowMs
        mirrorStatus.setClockSkewMs(skew)
        if abs(skew) >= config.clockSkewWarnMs {
            log("clock skew warn: primary=\(primaryNowMs)ms local=\(localNowMs)ms diff=\(skew)ms (threshold=\(config.clockSkewWarnMs)ms)")
        }

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
                let applied = try await applyPage(page, primaryID: currentPrimaryID)
                result.applied = applied.written
                result.skippedDedup = applied.dedupSkipped
                result.skippedPasteEcho = applied.pasteEchoSkipped
                result.hasMore = page.hasMore
                // eager_blobs 路径：tx 已提交、cursor 已推进，eager 失败不回滚 mirror。
                // 顺序故意——blob 字节是"用户体验加速"，不是 mirror 正确性的一部分
                await fetchBlobsEager(applied.mirroredShas)
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

    /// 比对 persisted peer_device_id 跟新探测到的 currentPrimaryID。不一致 → 清非 self origin
    /// 行 + cursor 重拉。
    ///
    /// 合表（v7）后 item_mirror 没了，peer 行直接落 item 表；切 peer 时不能整表清，要保留本机
    /// own-origin 行（origin=self），只删 origin != self 的 peer 行。PR 1 单 peer 部署下"非 self
    /// origin"就等于"当前 peer 的行"；PR 2 多 peer 后这条 SQL 会演化（按具体被换的 peer_id 过滤）。
    private func reconcilePrimary(currentPrimaryID: String) async throws {
        let persisted = try await database.pool.read { db -> String? in
            try String.fetchOne(db, sql: "SELECT peer_device_id FROM pull_cursor LIMIT 1")
        }
        guard let persisted else { return }   // 首次启动 / 已被清空 → 啥也不做
        if persisted == currentPrimaryID { return }
        log("peer device changed (\(persisted) → \(currentPrimaryID))，重置 peer 行 + cursor")
        let selfID = selfDeviceID
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM item WHERE origin_device != ?",
                arguments: [selfID]
            )
            try db.execute(sql: "DELETE FROM pull_cursor")
        }
    }

    private func loadCursor(primaryID: String) async throws -> SinceCursor {
        try await database.pool.read { db -> SinceCursor in
            let row = try Row.fetchOne(db, sql: """
                SELECT cursor_ns, cursor_id FROM pull_cursor WHERE peer_device_id = ?
            """, arguments: [primaryID])
            guard let row else { return .zero }
            let ns: Int64 = row["cursor_ns"] ?? 0
            let id: String = row["cursor_id"] ?? ""
            return SinceCursor(ingestedAtNs: ns, id: id)
        }
    }

    private struct ApplyOutcome {
        var written: Int
        var dedupSkipped: Int
        var pasteEchoSkipped: Int
        /// 这一页实际写入 mirror 的行里**有 blob 字节需求**的 sha 集合（去重）。
        /// 包含：deleted_at_ns IS NULL（tombstone 不需要字节）+ blob_sha256 非空 +
        /// item.kind 含 image/file（其它 kind 即使 sha 非空也不该有 blob 上传过）。
        /// 不在 writer tx 内做 BlobStore.exists 检查——那是 IO，应当留到 eager 阶段
        var mirroredShas: Set<String>
    }

    /// 写 item（合表后从 item_mirror 改成 item）+ 更新 pull_cursor，单事务。
    /// 返回实际入表行数（扣除 origin=self + 跨设备 dedup skip + paste-echo skip）。
    ///
    /// v7 合表后 peer 行直接落 item 表。强制写 push_state='acked'：mirror 来源行已经在 peer 上
    /// ingest 完成，PR 1 期间 push_state 列仍存在，必须给它有效终态值避免被 PushWorker 误推。
    private func applyPage(_ page: SincePageWire, primaryID: String) async throws -> ApplyOutcome {
        let device = selfDeviceID
        let now = nowNs()
        let windowNs = config.crossDeviceDedupWindowNs
        let suppressions = pasteSuppressions
        return try await database.pool.write { db -> ApplyOutcome in
            var written = 0
            var dedupSkipped = 0
            var pasteEchoSkipped = 0
            var mirroredShas: Set<String> = []
            for item in page.items {
                // 跳过自家 origin —— 本机 own 行已在 item 表，回推会被 INSERT OR IGNORE 兜底但
                // 防御性 early continue 节省一次查询
                if item.originDevice == device { continue }
                // Paste-echo 抑制（PasteSuppressionSet）：本机刚 pasteBack 写过的内容，被对端通过
                // Universal Clipboard 同步走 + 对端 watcher capture，再通过 /since 推回来。
                // 这条理应不入表（避免历史里出现一条"我刚 paste 的副本"）。
                // 跟下面的 crossDeviceDedup 路径正交：dedup 需要本机有 own item 当锚点；
                // paste 路径不写 own item，所以只能靠这个内存 set。
                //
                // 跟 dedup 一样：只对**首次入表** 生效。已存在的 peer-origin id 是 state update
                // （软删 / pin 变更回放），必须放过。
                let alreadyMirrored: Bool = try {
                    try Int.fetchOne(db, sql: "SELECT 1 FROM item WHERE id = ?", arguments: [item.id]) != nil
                }()
                // 候选 capturedAtNs 必须传给 suppression：shouldSuppress 还要求 capturedAt
                // 在 record 时刻之后（容 5s skew），否则 catch-up 时同内容的历史行会被
                // 永久误杀（cursor 已推进，再也拉不回来）。这是 P2 review fix。
                if !alreadyMirrored, let suppressions,
                   let fp = PasteSuppressionSet.fingerprint(forItem: item),
                   suppressions.shouldSuppress(
                       fingerprint: fp,
                       candidateCapturedAtNs: item.capturedAtNs
                   )
                {
                    pasteEchoSkipped += 1
                    continue
                }
                // 跨设备 Continuity dedup：本机 origin=self 同内容在 ±window 内已存 →
                // 这次拉来的是 Universal Clipboard 副本，skip 不入表，UI 只显单条 own。
                // windowNs=0 关闭这层；本设备没装 Continuity 或没开 Universal Clipboard 时
                // findNearbyOwnContent 永远命中不了，开销几乎为零（走 captured_at_ns 索引）。
                if windowNs > 0, !alreadyMirrored,
                   try DuoPasteCore.Database.findNearbyOwnContent(
                       db,
                       kind: item.kind,
                       textFull: item.textFull,
                       blobSha256: item.blobSha256,
                       ownDeviceID: device,
                       capturedAtNs: item.capturedAtNs,
                       windowNs: windowNs
                   ) != nil
                {
                    dedupSkipped += 1
                    continue
                }
                // INSERT OR REPLACE 让 state update（pin / 软删 / ingested_at_ns bump）回放；
                // peer 行强制 push_state='acked' 防误推。PR 1 期间 push_* 列仍存在，PR 4 才清。
                try db.execute(sql: """
                    INSERT OR REPLACE INTO item
                      (id, origin_device, captured_at_ns, ingested_at_ns, kind,
                       source_app, source_app_name, preview, text_full,
                       blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
                       push_state, push_attempts, last_push_error, ocr_state)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'acked', 0, NULL, ?)
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
                    item.ocrState?.rawValue,
                ])
                written += 1
                // 收集本页 blob 需求集合（eager 阶段后处理）。kind=image/file 才有意义；
                // 软删行（tombstone）跳过——它代表"peer 上已删"，没字节也合理
                if let sha = item.blobSha256, item.deletedAtNs == nil,
                   item.kind == .image || item.kind == .file {
                    mirroredShas.insert(sha)
                }
            }
            // UPSERT cursor。SQLite 3.24+ ON CONFLICT 语法，macOS 14 自带 SQLite > 3.24 OK。
            try db.execute(sql: """
                INSERT INTO pull_cursor (peer_device_id, cursor_ns, cursor_id, updated_at_ns)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(peer_device_id) DO UPDATE SET
                    cursor_ns = excluded.cursor_ns,
                    cursor_id = excluded.cursor_id,
                    updated_at_ns = excluded.updated_at_ns
            """, arguments: [primaryID, page.nextCursor.ingestedAtNs, page.nextCursor.id, now])
            return ApplyOutcome(
                written: written,
                dedupSkipped: dedupSkipped,
                pasteEchoSkipped: pasteEchoSkipped,
                mirroredShas: mirroredShas
            )
        }
    }

    /// eager_blobs 路径：拉这一页 mirror 行涉及的 blob 字节到本机 BlobStore。
    /// **best-effort**：任何 sha 失败 only log，不 throw、不影响 cursor 推进（cursor 已经
    /// 在 applyPage tx 内 commit）。下次 tick 这些 sha 仍 missing 会再次尝试——指数 backoff
    /// 由整体 tick 层接管（transient 失败时整体 tick 标 hadTransient），eager 阶段不自己重试
    private func fetchBlobsEager(_ shas: Set<String>) async {
        guard config.eagerBlobs,
              let fetcher = blobFetcher,
              let store = blobs,
              !shas.isEmpty else {
            return
        }
        var fetched = 0
        var skipped = 0
        var failed = 0
        for sha in shas {
            if Task.isCancelled { break }
            // 本机已有字节 → 跳过（PullWorker 多 tick 间幂等的关键 short-circuit）
            if store.exists(sha256: sha) {
                skipped += 1
                continue
            }
            do {
                let outcome = try await fetcher.getBlob(sha256: sha)
                switch outcome {
                case .found(let data):
                    do {
                        _ = try store.putVerified(data, expectedSha256: sha)
                        fetched += 1
                    } catch {
                        log("eager blob put failed sha=\(sha): \(error)")
                        failed += 1
                    }
                case .notFound:
                    // primary 也没字节——promote-to-primary 缺 blob 场景下的合法情况
                    log("eager blob notFound on primary sha=\(sha)")
                    failed += 1
                }
            } catch {
                log("eager blob fetch failed sha=\(sha): \(error)")
                failed += 1
            }
        }
        if fetched + failed > 0 {
            log("eager blobs fetched=\(fetched) skipped=\(skipped) failed=\(failed)")
        }
    }
}

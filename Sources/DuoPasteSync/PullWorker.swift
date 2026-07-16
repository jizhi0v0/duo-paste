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
        /// 跨设备 Continuity dedup 时间窗（纳秒）。**default 0 = 关闭这层 dedup**
        /// （plan hashed-allen §D）。
        ///
        /// 历史 default 是 5_000_000_000 (5s)：PullWorker 写 item_mirror 前查本机
        /// item 表有无 origin=self 同内容在窗口内已存——命中则 skip mirror 入库，
        /// UI union 看到的就是单条 own。
        ///
        /// 但这破坏了两台 Mac 的行集合对称性（mini 上有 mirror、MBP 上没有 mirror），
        /// cascade 删除依赖对称性才能找到 sibling tombstone。所以 default 翻 0
        /// 让 cross-device 副本老实进 mirror，UI 靠内容 fold 兜底
        /// 不影响显示（fold 跨 origin 同 text 折一条）。
        ///
        /// 非 0 = 紧急回滚口（单台机器临时回退 5_000_000_000 恢复历史行为）。
        public var crossDeviceDedupWindowNs: Int64
        /// 时钟偏移告警阈值（毫秒）。|primary.now_ms - local.now_ms| 超过这个值 →
        /// log warn + 通过 MirrorStatus 暴露给 UI banner。
        ///
        /// HMAC 签名容忍 ±5 分钟 skew（300_000 ms），所以 30s 是"健康但要注意"的早期信号。
        /// 用户场景：mini 长期休眠 / 路由器走不同 NTP 源 / 虚机时钟漂移；这些都不至于
        /// 立刻 401，但快到边界就该提醒了。
        public var clockSkewWarnMs: Int64

        /// `.full`（默认）= PullWorker 拉完一页 metadata 顺路 GET 这一页里本机 BlobStore
        /// 没字节的 blob_sha256（去重）做完整 mirror。`.optimized` = 不拉字节，UI 按需走
        /// lazy 路径（缩略图 / 预览 / paste）。失败不抛、不阻塞 cursor 推进——下次 tick
        /// 拉同样的 sha 再试。
        ///
        /// 替代老 `eagerBlobs: Bool` 字段(plan cloudy-mirroring-walnut)——默认翻成
        /// 「完整 mirror」对齐 mesh 字面语义;想节省存储的设备显式配 .optimized opt-in
        public var storageMode: StorageMode

        /// 连续 transient tick 失败几次后认为"chosen URL 烂了"触发 supervisor reconcile。
        /// <= 0 = 禁用。默认 3:跟 backoff 序列 2+4+8=14s 对齐,既不太敏感(单次抖动不触发)
        /// 又不太迟(周期 reconcile 5min 之外的快速自愈)。触发只发一次(==threshold 时),
        /// 下次 .ok reset 计数后再积累到 threshold 才再次触发,避免连续狂触发
        public var reconcileFailureThreshold: Int

        public init(
            intervalSec: TimeInterval = 30,
            batchLimit: Int = 500,
            initialBackoffSec: TimeInterval = 2,
            maxBackoffSec: TimeInterval = 120,
            crossDeviceDedupWindowNs: Int64 = 0,
            clockSkewWarnMs: Int64 = 30_000,
            storageMode: StorageMode = .default,
            reconcileFailureThreshold: Int = 3
        ) {
            self.intervalSec = intervalSec
            self.batchLimit = batchLimit
            self.initialBackoffSec = initialBackoffSec
            self.maxBackoffSec = maxBackoffSec
            self.crossDeviceDedupWindowNs = crossDeviceDedupWindowNs
            self.clockSkewWarnMs = clockSkewWarnMs
            self.storageMode = storageMode
            self.reconcileFailureThreshold = reconcileFailureThreshold
        }

        public static let `default` = Config()
    }

    private let database: DuoPasteCore.Database
    private let transport: SinceTransport
    private let selfDeviceID: String
    /// 期望的 peer device_id。nil → 首次启动学习模式（用 /health 返回的 device_id 当 cursor PK）；
    /// 非 nil → 严格模式（/health 返回的 device_id 跟它对不上立刻 transient skip，
    ///   防止 peer URL 配错指到另一台机器而污染本机数据）。
    /// PR 2 阶段 MeshSupervisor 从 PeerSpec.deviceID 透传过来：手填 ID 走严格，nil 走学习。
    private let expectedPeerDeviceID: String?
    private let meshStatus: MeshStatus
    /// 跨设备 paste-echo 抑制：本机 pasteBack 写 NSPasteboard 后通过 Continuity 反弹到对端
    /// 又被对端 watcher capture 推回来时，PullWorker 在 applyPage 里查这个 set，命中 skip。
    /// nil = 抑制功能未启用（standalone / 测试不传）。
    private let pasteSuppressions: PasteSuppressionSet?
    /// `storage_mode=.full` 时用于拉 blob 字节。nil → 即使 config.storageMode=.full 也 no-op
    /// （让测试可以独立控制；生产 AppDelegate 始终注入 HTTPPeerClient）
    private let blobFetcher: BlobFetcher?
    /// `storage_mode=.full` 时把拉回的字节写入这里。nil → 同 blobFetcher
    private let blobs: BlobStore?
    /// ENOSPC 时调本回调释放空间。nil = 不做 LRU 驱逐，fetchBlobsFull 失败只 log
    /// （行为不变）。生产路径 AppDelegate 注入 `BlobEvictor.evictOneOldest`
    private let evictOnFull: (@Sendable () throws -> Bool)?
    private let config: Config
    private let nowNs: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    /// 每次 /health 探测完调一次。`>= 0` = 当前 transport 真正可拉同步(. ok 响应);`-1` =
    /// 任何失败(网络层 throw / `.unreachable` / `.rejected` / 空 device_id / 严格模式
    /// expected mismatch)——UI 视角这些都意味着"这个 chosen URL 不能用",对齐 SmartTransport
    /// `isReachable` 的"只有 .ok 算 reachable"语义。
    /// nil = 没接 callback(测试 / 单独跑 PullWorker 模式),no-op。生产路径由 PeerBuilder
    /// 注入 → AppDelegate hop @MainActor 写 AppState 让 Settings UI 反映 runtime 健康度
    private let onHealthProbed: (@Sendable (Int64) -> Void)?
    /// 连续 transient 失败达到 `config.reconcileFailureThreshold` 时调一次。生产路径 =
    /// PeerBuilder 注入 → MeshSupervisor.reconcileTransports()(自带 ReconcileGate 防 storm),
    /// 让 chosen URL 烂掉时 quick recovery 不必等周期 5min reconcile。nil = 不接 → no-op
    private let onChosenLikelyDown: (@Sendable () -> Void)?

    private var runTask: Task<Void, Never>?
    private var currentSleep: Task<Void, Error>?
    private var consecutiveTransientFailures = 0
    /// 当前 tick 锚定的 peer device_id。reconcilePeer 学到 / 严格模式从 init 注入。
    /// 用于 setLastPullNs / setClockSkewMs 等 MeshStatus per-peer 调用。
    private var currentPeerDeviceID: String?

    public init(
        database: DuoPasteCore.Database,
        transport: SinceTransport,
        selfDeviceID: String,
        expectedPeerDeviceID: String? = nil,
        meshStatus: MeshStatus,
        pasteSuppressions: PasteSuppressionSet? = nil,
        blobFetcher: BlobFetcher? = nil,
        blobs: BlobStore? = nil,
        evictOnFull: (@Sendable () throws -> Bool)? = nil,
        config: Config = .default,
        nowNs: @escaping @Sendable () -> Int64 = { Clock.nowNs() },
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("pull: \(msg)\n".utf8))
        },
        onHealthProbed: (@Sendable (Int64) -> Void)? = nil,
        onChosenLikelyDown: (@Sendable () -> Void)? = nil
    ) {
        self.database = database
        self.transport = transport
        self.selfDeviceID = selfDeviceID
        self.expectedPeerDeviceID = expectedPeerDeviceID
        self.meshStatus = meshStatus
        self.pasteSuppressions = pasteSuppressions
        self.blobFetcher = blobFetcher
        self.blobs = blobs
        self.evictOnFull = evictOnFull
        self.config = config
        self.nowNs = nowNs
        self.log = log
        self.onHealthProbed = onHealthProbed
        self.onChosenLikelyDown = onChosenLikelyDown
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
        let peerSuffix = expectedPeerDeviceID.map { " · peer=\($0)" } ?? ""
        log("worker started · self=\(selfDeviceID)\(peerSuffix) · interval=\(Int(config.intervalSec))s")
        while !Task.isCancelled {
            let r = await tick()

            // 标 lastPullNs 的语义：「mirror 已严格追平该 peer」——only when has_more=false 且无 transient
            // 若 has_more=true（中途）或有 transient，保持原值，SearchProvider 仍可看到旧 lastPullNs。
            // currentPeerDeviceID 由 tick 内 reconcilePeer 设置（首次或换号时），nil 时跳过——
            // 等同 transient（没拿到 peer id 不能标"已追平"）。
            if !r.hadTransient && !r.hasMore, let pid = currentPeerDeviceID {
                meshStatus.setLastPullNs(peerDeviceID: pid, nowNs())
            }

            if r.hadTransient {
                consecutiveTransientFailures += 1
                // ==threshold 时触发一次,跨过去继续失败不再触发(防 callback 风暴)。
                // .ok 把 consecutiveTransientFailures reset 到 0,下次再积累到 threshold 才再触发
                if config.reconcileFailureThreshold > 0,
                   consecutiveTransientFailures == config.reconcileFailureThreshold {
                    log("consecutive transient failures hit \(consecutiveTransientFailures),trigger reconcile")
                    onChosenLikelyDown?()
                }
            } else {
                consecutiveTransientFailures = 0
            }
            if let pid = currentPeerDeviceID {
                meshStatus.setConsecutiveFailures(peerDeviceID: pid, consecutiveTransientFailures)
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

        // 1. /health:拿当前 peer device_id + 测 RTT 回调给 UI
        // RTT 用 Date() wall-clock 跟 SmartTransport.defaultProbe 对齐(对齐口径让初始
        // discover 数字和 runtime 数字直接可比)。任何失败 → callback 收 -1 让 UI 立刻反映
        let healthStart = Date()
        let healthRes: PrimaryHealthResult
        do {
            healthRes = try await transport.fetchPrimaryHealth()
        } catch is CancellationError {
            // 取消不算"探测到不可达"——不打 callback,让 UI 保持上次状态
            return result
        } catch {
            log("health threw: \(error)")
            onHealthProbed?(-1)
            result.hadTransient = true
            return result
        }
        let currentPeerID: String
        let peerNowMs: Int64
        switch healthRes.outcome {
        case .ok(let id, let nowMs, _):
            // 第三个位置参数是 ponteHost,PullWorker 不消费——SmartTransport 在 reconcile 时单独 discover
            // 拒绝空 device_id:会污染 pull_cursor.peer_device_id 主键 + 在 reconcile 里假阳性
            // 触发清行。理论上 server 永远不会返回空(DeviceID.loadOrCreate 保证),但万一旧版
            // / 篡改 / 网络中间件改包,guard 在这里。
            guard !id.isEmpty else {
                log("health 返回空 device_id,当 transient 跳过")
                onHealthProbed?(-1)
                result.hadTransient = true
                return result
            }
            // 严格模式:expectedPeerDeviceID 非 nil 时校验。对不上 = 配置错(peer URL 指错机器
            // / DNS 漂移指到别人 mesh),不该写本机 DB——transient skip 让 backoff 上去
            if let expected = expectedPeerDeviceID, expected != id {
                log("expected peer=\(expected) but /health returned \(id),transient skip")
                onHealthProbed?(-1)
                result.hadTransient = true
                return result
            }
            let rttMs = Int64(Date().timeIntervalSince(healthStart) * 1000)
            onHealthProbed?(rttMs)
            currentPeerID = id
            peerNowMs = nowMs
        case .unreachable(let r):
            log("health unreachable: \(r)")
            onHealthProbed?(-1)
            result.hadTransient = true
            return result
        case .rejected(let r):
            log("health rejected: \(r)")
            onHealthProbed?(-1)
            result.hadTransient = true
            return result
        }
        // 锚定本 tick 的 peer ID（用于 runLoop 末尾的 setLastPullNs / setConsecutiveFailures）
        self.currentPeerDeviceID = currentPeerID

        // 1b. 时钟偏移 sanity check。peer now_ms vs local wall-clock，单位毫秒（signed）。
        // 用本地 wall-clock（nowNs / 1e6）跟 peer now_ms 比；rountrip 半程当 0，对 30s 阈值
        // 影响 < 100ms 量级可忽略。
        let localNowMs = nowNs() / 1_000_000
        let skew = peerNowMs - localNowMs
        meshStatus.setClockSkewMs(peerDeviceID: currentPeerID, skew)
        if abs(skew) >= config.clockSkewWarnMs {
            log("clock skew warn: peer=\(peerNowMs)ms local=\(localNowMs)ms diff=\(skew)ms (threshold=\(config.clockSkewWarnMs)ms)")
        }

        // 2. 检测 peer 换了 device_id → 精确清该 peer 的旧行 + cursor 重拉
        do {
            try await reconcilePeer(currentPeerID: currentPeerID)
        } catch {
            log("reconcile peer failed: \(error)")
            result.hadTransient = true
            return result
        }

        // 3. 读 cursor
        let cursor: SinceCursor
        do {
            cursor = try await loadCursor(peerID: currentPeerID)
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
                let applied = try await applyPage(page, peerID: currentPeerID)
                result.applied = applied.written
                result.skippedDedup = applied.dedupSkipped
                result.skippedPasteEcho = applied.pasteEchoSkipped
                result.hasMore = page.hasMore
                // storage_mode=.full 路径：tx 已提交、cursor 已推进，full 失败不回滚 mirror。
                // 顺序故意——blob 字节是"用户体验加速"，不是 mirror 正确性的一部分。
                // .optimized 模式 fetchBlobsFull 内部 guard short-circuit return no-op
                await fetchBlobsFull(applied.mirroredShas)
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

    /// 比对该 peer 在 pull_cursor 里的 persisted device_id 跟新探测到的 currentPeerID。
    /// 不一致 → 精确删 origin=persisted 的所有行 + 删该行 cursor。
    ///
    /// 多 peer 拓扑下精度要求：pull_cursor 是 (peer_device_id) PK，每个 peer 一行；切 peer 时
    /// 只删该 peer 自己的行（origin_device = persisted），**不动**本机 own（origin=self）也
    /// **不动**其他 peer 的行。MeshStatus 同步移除该 peer 状态防 oldestLastPullNs 用错值。
    ///
    /// **怎么知道哪个 pull_cursor 行属于当前这个 PullWorker？**
    /// - 严格模式（expectedPeerDeviceID 非 nil）：persisted = pull_cursor WHERE peer_device_id =
    ///   expected。reconcile 检查 currentPeerID == expected（tick 入口已 guard），所以这里
    ///   persisted 就是 expected 本身——纯启动后老 device_id 行（如果 expected 换了）由
    ///   MeshSupervisor 配置切换路径清理，不在 reconcilePeer 范围。
    /// - 学习模式（expectedPeerDeviceID nil）：peer 唯一识别符是 URL，但 pull_cursor 没存 URL。
    ///   学习模式只能存最近一次 /health 学到的 device_id；persisted 就是上次学到的 ID。如果
    ///   /health 这次返回新 ID（peer 重装），删旧 persisted 的行 + cursor 行。
    ///
    /// PR 2 单 peer 部署语义：跟 PR 1 reconcilePrimary 等价；多 peer 部署各自走自己 cursor 行。
    private func reconcilePeer(currentPeerID: String) async throws {
        // 学习模式 + 严格模式都从 pull_cursor 行学 persisted。但严格模式下 pull_cursor 行的
        // peer_device_id 跟 expected 一致，currentPeerID == expected（前面 guard 保证），
        // 所以 persisted == currentPeerID，reconcile 是 no-op。
        //
        // 学习模式才真有可能 persisted != currentPeerID（peer 重装 / device-id 重置）。
        // 单 peer 部署历史只有一行 pull_cursor，LIMIT 1 拿出来；多 peer 部署用 expected 精确查。
        let persisted: String?
        if let expected = expectedPeerDeviceID {
            // 严格模式：精准查 expected 那一行。学习模式不走这里。
            persisted = try await database.pool.read { db -> String? in
                try String.fetchOne(db, sql: """
                    SELECT peer_device_id FROM pull_cursor WHERE peer_device_id = ?
                """, arguments: [expected])
            }
        } else {
            // 学习模式：只有单 peer 部署可能走这条路径（多 peer 必须传 expectedPeerDeviceID
            // 避免多个学习 worker 抢同一行 cursor）。先 COUNT(*) 做安全闸：超过 1 行说明
            // pull_cursor 表已经被多 peer 用过，LIMIT 1 拿到的行可能不属于当前 worker，
            // 后续 DELETE 会清掉别人的 cursor + origin 行——直接 skip + log，等运维补上
            // expectedPeerDeviceID 再进 reconcile
            let rowCount = try await database.pool.read { db -> Int in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_cursor") ?? 0
            }
            if rowCount > 1 {
                log("learning-mode reconcilePeer skipped: pull_cursor has \(rowCount) rows but expectedPeerDeviceID is nil — multi-peer deployment must pass expected device_id explicitly")
                return
            }
            persisted = try await database.pool.read { db -> String? in
                try String.fetchOne(db, sql: "SELECT peer_device_id FROM pull_cursor LIMIT 1")
            }
        }
        guard let persisted else { return }   // 首次启动 / 已被清空 → 啥也不做
        if persisted == currentPeerID { return }
        log("peer device changed (\(persisted) → \(currentPeerID))，重置 peer 行 + cursor")
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM item WHERE origin_device = ?",
                arguments: [persisted]
            )
            try db.execute(
                sql: "DELETE FROM pull_cursor WHERE peer_device_id = ?",
                arguments: [persisted]
            )
        }
        // 同步清 MeshStatus 里 persisted 那个 peer 的状态，防 oldestLastPullNs 还用着旧值
        meshStatus.removePeer(persisted)
    }

    private func loadCursor(peerID: String) async throws -> SinceCursor {
        try await database.pool.read { db -> SinceCursor in
            let row = try Row.fetchOne(db, sql: """
                SELECT cursor_ns, cursor_id FROM pull_cursor WHERE peer_device_id = ?
            """, arguments: [peerID])
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
    private func applyPage(_ page: SincePageWire, peerID: String) async throws -> ApplyOutcome {
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
                // 防御性 early continue 节省一次查询。
                //
                // **例外:incoming own tombstone**(plan hashed-allen §B)。
                // softDelete cascade 在另一台 Mac 触发会 tombstone 本机 own 行的 mirror →
                // 通过 /since 推回自家 → 必须能写入本机 own 行,否则三端不一致。
                // 仅 incoming=tombstone + local=active + ingested 严格单增才 UPDATE;
                // 不动 captured_at_ns / 内容字段;不进 INSERT OR REPLACE 主路径
                if item.originDevice == device {
                    if let deletedAt = item.deletedAtNs,
                       let incomingIngest = item.ingestedAtNs,
                       let local = try Item.filter(Column("id") == item.id).fetchOne(db),
                       local.deletedAtNs == nil,
                       incomingIngest > (local.ingestedAtNs ?? 0)
                    {
                        try db.execute(sql: """
                            UPDATE item SET deleted_at_ns = ?, ingested_at_ns = ?
                            WHERE id = ?
                        """, arguments: [deletedAt, incomingIngest, item.id])
                        written += 1
                        // 观测性 log:扩大了信任面(任意 HMAC-authed peer 现在可 tombstone
                        // 本机 own 行)。mesh-doctor / 异常溯源时通过 stderr 知道哪条 own
                        // 行被 peer cascade 删了
                        FileHandle.standardError.write(Data(
                            "PullWorker.applyPage: accepted own-origin tombstone from peer=\(peerID) id=\(item.id) ingested=\(incomingIngest)\n".utf8
                        ))
                    }
                    continue
                }
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
                // INSERT OR REPLACE 让 state update（pin / 软删 / ingested_at_ns bump /
                // OCR done 回放 extracted_text）。PR 4 已删 push_state / push_attempts /
                // last_push_error 列。v9 加 extracted_text + extracted_text_source 两列。
                try db.execute(sql: """
                    INSERT OR REPLACE INTO item
                      (id, origin_device, captured_at_ns, ingested_at_ns, kind,
                       source_app, source_app_name, preview, text_full,
                       blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
                       ocr_state, extracted_text, extracted_text_source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    item.extractedText,
                    item.extractedTextSource?.rawValue,
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
            """, arguments: [peerID, page.nextCursor.ingestedAtNs, page.nextCursor.id, now])
            return ApplyOutcome(
                written: written,
                dedupSkipped: dedupSkipped,
                pasteEchoSkipped: pasteEchoSkipped,
                mirroredShas: mirroredShas
            )
        }
    }

    /// `storage_mode=.full` 路径：拉这一页 mirror 行涉及的 blob 字节到本机 BlobStore。
    /// **best-effort**：任何 sha 失败 only log，不 throw、不影响 cursor 推进（cursor 已经
    /// 在 applyPage tx 内 commit）。下次 tick 这些 sha 仍 missing 会再次尝试——指数 backoff
    /// 由整体 tick 层接管（transient 失败时整体 tick 标 hadTransient），full 阶段不自己重试。
    /// `.optimized` 模式 short-circuit return——UI 按需走 lazy 路径
    private func fetchBlobsFull(_ shas: Set<String>) async {
        guard config.storageMode == .full,
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
                        if let evictor = evictOnFull {
                            _ = try store.putVerifiedRetryingOnFull(
                                data, expectedSha256: sha, evictor: evictor
                            )
                        } else {
                            _ = try store.putVerified(data, expectedSha256: sha)
                        }
                        fetched += 1
                    } catch {
                        log("full mirror blob put failed sha=\(sha): \(error)")
                        failed += 1
                    }
                case .notFound:
                    // peer 也没字节——promote-to-primary 缺 blob 场景下的合法情况
                    log("full mirror blob notFound on peer sha=\(sha)")
                    failed += 1
                }
            } catch {
                log("full mirror blob fetch failed sha=\(sha): \(error)")
                failed += 1
            }
        }
        if fetched + failed > 0 {
            log("full mirror blobs fetched=\(fetched) skipped=\(skipped) failed=\(failed)")
        }
    }
}

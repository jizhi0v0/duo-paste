import Foundation
import GRDB

/// 本地 OCR 调度器。仿 PushWorker 单 actor 串行 tick + `wake()` 缩短延迟。
///
/// **职责**：扫本机 `origin = self` + `ocr_state = 'pending'` 且 kind 满足 (image OR
/// file+image-blob) 的行，调 OCRRecognizer 拿文本写回 `extracted_text` +
/// `extracted_text_source='ocr'` + `ocr_state = 'done'`，FTS5 trigger 自动刷新索引让
/// 图里中英文进搜索。
///
/// **扫描条件扩 file kind**（v9 之后）：用户从 Finder / IDE / Slack 复制 .png 文件路径
/// 走 PasteboardWatcher "文件 URL" 分支落 kind=.file，但单文件 image-like 路径会**额外**
/// 把字节读进 BlobStore 做 mirror。这类行 blob_mime='image/*' + blob_sha256 非空，
/// OCR 可见的字节就绪——所以 OCR 也应该扫这些行。判别用 blob_mime（不用路径后缀）
/// 因为 mime 是 CaptureService 读字节成功才设置的，等价于"OCR 必需的字节就绪"。
///
/// **不变量**（详 plan vivid-scanning-vellum.md §关键不变量）：
/// 1. 只扫 origin=self，不跨 origin（破"PullWorker 跳过 own-origin"前提；Phase 2 加
///    /update endpoint 再放）
/// 2. 写回 own-origin 行时 bump `ingested_at_ns`（Database.nextIngestNs），让
///    audit-push / 未来跨设备同步看到更新
/// 3. text_full 空字符串归一化为 nil（FTS5 zero-length match 有 corner case）
/// 4. 不动 preview（preview = capture 时定的视觉摘要；OCR 文本是搜索维度）
/// 5. markDone 即便 text 为空（避免每 tick 重扫这条永不收敛）
/// 6. `failed` 不自动重试（actor 内存 attempts 计数 → 达上限 → DB 标 failed，需要
///    用户跑 retry-failed-ocr 重置）
///
/// **调度**：
/// - 单 actor 串行处理一个 batch（默认 20 张）
/// - 每张之间 sleep `perItemPauseMs`（默认 100ms）让前台不卡
/// - 空 batch → sleep `idleIntervalSec`（默认 300s）
/// - `wake()` 由 AppDelegate.captureCallback 在 image 入库后调，取消当前 sleep 提前 tick
public actor OCRWorker {
    public struct Config: Sendable {
        /// 空 batch 后 sleep 时长。默认 300s（5min 兜底）；wake() 让新 image 不必等满
        public var idleIntervalSec: TimeInterval
        /// 同一 batch 内每张 OCR 后 sleep 的间隔。让前台 UI 不卡（Vision .accurate 单
        /// 图峰值 50-100% 单核 1-3s，间歇 100ms 给前台 task 机会）
        public var perItemPauseMs: Int
        /// transient 错误连续达到此值 → 标 failed 不再扫
        public var maxAttempts: Int
        /// 一个 tick 处理多少行
        public var batchSize: Int
        /// blob 字节超过此值 → 标 skipped 不喂 Vision。理由：Vision 解大图内存峰值高，
        /// 而且 4K+ 长截图 OCR 性价比低（用户大概率是误捕获，已被 capture 阶段
        /// max_blob_mb=32 挡过一次，本 cap 是 OCR 自己的更紧上限）
        public var maxBlobBytes: Int
        /// Vision recognitionLanguages hint。按优先级排序，accurate 模式下作语言模型
        /// 选择依据；macOS 13+ automaticallyDetectsLanguage 再补一道
        public var languages: [String]

        public init(
            idleIntervalSec: TimeInterval = 300,
            perItemPauseMs: Int = 100,
            maxAttempts: Int = 5,
            batchSize: Int = 20,
            maxBlobBytes: Int = 16 * 1024 * 1024,
            languages: [String] = ["zh-Hans", "en-US"]
        ) {
            self.idleIntervalSec = idleIntervalSec
            self.perItemPauseMs = perItemPauseMs
            self.maxAttempts = maxAttempts
            self.batchSize = batchSize
            self.maxBlobBytes = maxBlobBytes
            self.languages = languages
        }

        public static let `default` = Config()
    }

    private let database: DuoPasteCore.Database
    private let blobs: BlobStore
    private let recognizer: OCRRecognizer
    private let originDevice: String
    private let config: Config
    private let log: @Sendable (String) -> Void
    /// OCR Phase 2：markDone 后调用让 server 端 WSBroadcaster fan-out cursor_advanced 帧——
    /// 对端 PullWorker 收到立即拉一页拿到新 ocr_state + text_full，跨设备 OCR 结果 < 1s 推送。
    /// 不接（默认 no-op）→ 对端要等 30s 周期 pull tick 才同步到 OCR 结果（也 acceptable）。
    /// 跟 CaptureService.onCursorAdvanced 同款 hook 模式
    private let onCursorAdvanced: @Sendable (Int64) -> Void

    private var runTask: Task<Void, Never>?
    private var currentSleep: Task<Void, Error>?
    /// 内存 attempts 计数：id → attempts。`failed` 不持久化原因详 plan §决策——
    /// daemon 重启 = 全部 pending 重新扫一遍（OCR 失败大多是图本身坏 / Vision 系统 bug，
    /// 跨重启重试不算大代价）。`failed` 终态需用户 retry-failed-ocr 重置
    private var attemptCounts: [String: Int] = [:]

    public init(
        database: DuoPasteCore.Database,
        blobs: BlobStore,
        recognizer: OCRRecognizer,
        originDevice: String,
        config: Config = .default,
        onCursorAdvanced: @escaping @Sendable (Int64) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("ocr: \(msg)\n".utf8))
        }
    ) {
        self.database = database
        self.blobs = blobs
        self.recognizer = recognizer
        self.originDevice = originDevice
        self.config = config
        self.onCursorAdvanced = onCursorAdvanced
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

    /// 外部（AppDelegate.captureCallback 在 image 入库后）通知：可能有新 pending。
    /// 实现仿 PushWorker.wake：取消当前 sleep 让 runLoop 提前进入下一 tick。
    public nonisolated func wake() {
        Task { await self.cancelCurrentSleep() }
    }

    private func cancelCurrentSleep() {
        currentSleep?.cancel()
    }

    /// 主循环：tick → 算 sleep → 进入可中断 sleep → 再 tick。
    /// drained.processed == 0（空 batch）→ idleIntervalSec；非空 → 0（立即下一 tick
    /// 把 backlog 清空，wake() 路径不必等满 idle 周期）
    private func runLoop() async {
        log("worker started · originDevice=\(originDevice) · langs=\(config.languages.joined(separator: ","))")
        while !Task.isCancelled {
            let drained = await tick()
            let sleepSec: TimeInterval = drained.processed == 0 ? config.idleIntervalSec : 0
            if sleepSec > 0 {
                let task = Task {
                    try await Task.sleep(nanoseconds: UInt64(sleepSec * 1_000_000_000))
                }
                self.currentSleep = task
                _ = try? await task.value    // wake() 取消 → 抛 CancellationError，忽略
                self.currentSleep = nil
            }
        }
        log("worker stopped")
    }

    struct TickResult: Sendable, Equatable {
        var processed: Int = 0
        var done: Int = 0
        var skipped: Int = 0
        var failed: Int = 0
        var transient: Int = 0
    }

    /// 单 tick：捞一批 pending → 顺序逐张处理 → 返回统计。
    /// `internal` 而非 `public`——测试用 `@testable import` 拿到访问权，
    /// 外部生产代码（AppDelegate）不应直接调 tick 跟内部 runLoop 抢资源
    @discardableResult
    func tick() async -> TickResult {
        var result = TickResult()
        let pending: [Item]
        do {
            pending = try fetchPending()
        } catch {
            log("fetch pending failed: \(error)")
            return result
        }
        if pending.isEmpty { return result }

        for item in pending {
            if Task.isCancelled { break }
            let outcome = await processOne(item)
            result.processed += 1
            switch outcome {
            case .done:       result.done += 1
            case .skipped:    result.skipped += 1
            case .failedTerm: result.failed += 1
            case .transient:  result.transient += 1
            }
            // perItemPauseMs > 0 才 sleep，避免测试场景多余开销
            if config.perItemPauseMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(config.perItemPauseMs) * 1_000_000)
            }
        }
        if result.processed > 0 {
            log("tick processed=\(result.processed) done=\(result.done) skipped=\(result.skipped) failed=\(result.failed) transient=\(result.transient)")
        }
        return result
    }

    private enum ProcessOutcome: Sendable {
        case done
        case skipped
        case failedTerm
        case transient
    }

    private func processOne(_ item: Item) async -> ProcessOutcome {
        guard let sha = item.blobSha256, !sha.isEmpty else {
            await markSkipped(id: item.id, reason: "no blob sha")
            return .skipped
        }
        guard let url = blobs.locate(sha256: sha) else {
            await markSkipped(id: item.id, reason: "blob missing")
            return .skipped
        }
        // 守门：blob 字节超 cap → 跳过。读 attribute 失败不阻塞——按存量大小 0 处理
        let bytes: Int
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            await markSkipped(id: item.id, reason: "stat failed: \(error)")
            return .skipped
        }
        if bytes > config.maxBlobBytes {
            await markSkipped(id: item.id, reason: "blob too large: \(bytes) > \(config.maxBlobBytes)")
            return .skipped
        }

        do {
            let r = try await recognizer.recognize(imageURL: url, languages: config.languages)
            // recognize 是耗时 async 调用（Vision 0.5-3s）。等回来后 stop() 可能已经
            // 把 runTask cancel 过——此时不应再写 DB，让 ocr_state 保留 pending 等下次
            // 重启后重扫。匹配 `catch is CancellationError` 分支的"不动 DB 状态"语义
            if Task.isCancelled { return .transient }
            await markDone(id: item.id, text: r.text)
            attemptCounts.removeValue(forKey: item.id)
            return .done
        } catch let e as OCRRecognizeError {
            switch e {
            case .imageLoadFailed, .unsupportedFormat, .visionPermanent:
                await markSkipped(id: item.id, reason: "\(e)")
                attemptCounts.removeValue(forKey: item.id)
                return .skipped
            case .visionTransient:
                let next = (attemptCounts[item.id] ?? 0) + 1
                attemptCounts[item.id] = next
                if next >= config.maxAttempts {
                    await markFailed(id: item.id, reason: "max attempts (\(next)): \(e)")
                    attemptCounts.removeValue(forKey: item.id)
                    return .failedTerm
                }
                return .transient
            }
        } catch is CancellationError {
            // 关 worker 时 task cancel；不动 DB 状态，下次重启再扫
            return .transient
        } catch {
            // 非 typed error 当 transient：bump 内存 attempts 走同样路径
            let next = (attemptCounts[item.id] ?? 0) + 1
            attemptCounts[item.id] = next
            if next >= config.maxAttempts {
                await markFailed(id: item.id, reason: "max attempts (\(next)): \(error)")
                attemptCounts.removeValue(forKey: item.id)
                return .failedTerm
            }
            return .transient
        }
    }

    /// SQL：`origin_device = self AND ocr_state = 'pending' AND deleted_at_ns IS NULL`
    /// AND (`kind = 'image'` **OR** `kind = 'file' AND blob_mime LIKE 'image/%' AND
    /// blob_sha256 IS NOT NULL`) 按 captured_at_ns ASC 取 batchSize 条。
    /// ASC 让 backfill 老历史按时间顺序清，新捕获走 wake 进 batch 顺序无所谓。
    ///
    /// **不过滤 image kind 的 blob_sha256 IS NOT NULL**：legacy/corrupt/backfill 出来的
    /// image 行可能 sha 缺失。让它们进 batch，processOne 第一行 `guard let sha` 把它们
    /// 标 skipped 收敛——否则永远卡 pending，"no blob sha" 这条 markSkipped 分支也不可达。
    /// file 分支要求 blob_sha256 IS NOT NULL 是因为：file kind 多数行（path-only）没 blob,
    /// 进 batch 也只能立刻 skipped 空跑——不如在 SQL 层就过滤。
    ///
    /// 用 GRDB SQLLiteral 而非 QueryInterface 是因为 file 分支的 OR + blob_mime LIKE
    /// 复合谓词 query builder 表达起来不如手写 SQL 清楚
    private func fetchPending() throws -> [Item] {
        let limit = config.batchSize
        let device = originDevice
        return try database.pool.read { db in
            try Item.fetchAll(db, sql: """
                SELECT * FROM item
                WHERE origin_device = ?
                  AND ocr_state = ?
                  AND deleted_at_ns IS NULL
                  AND (
                        kind = 'image'
                     OR (kind = 'file' AND blob_mime LIKE 'image/%' AND blob_sha256 IS NOT NULL)
                  )
                ORDER BY captured_at_ns ASC
                LIMIT ?
            """, arguments: [device, OCRState.pending.rawValue, limit])
        }
    }

    /// 写回成功 OCR 结果。**关键**：
    /// - 写 `extracted_text` + `extracted_text_source = 'ocr'`（v9 之后）。**不**动 `text_full`
    ///   ——它装的是"原始可粘贴文本"，OCR 不属于这一类。两列语义切干净
    /// - bump `ingested_at_ns` 让 audit-push / 未来同步看到更新（plan §不变量 #2）
    /// - text 空字符串 → nil（plan §不变量 #3）
    /// - 不动 preview / captured_at_ns（OCR 不是新 capture，也不影响推送）
    /// - `AND deleted_at_ns IS NULL` 守护：fetchPending → processOne 之间用户可能软删
    ///   该 item。把 OCR 结果写进 tombstone 不破坏 search（已 exclude），但会通过 /since
    ///   把"软删 image 又被 OCR 了"无谓下发给 mirror clients
    private func markDone(id: String, text: String) async {
        let normalized: String? = text.isEmpty ? nil : text
        let now = Clock.nowNs()
        var stampedNs: Int64? = nil
        do {
            stampedNs = try await database.pool.write { db -> Int64 in
                let stamp = try DuoPasteCore.Database.nextIngestNs(db, now: now)
                // ocr_state = 'pending' guard：user 通过 Admin.abortOCRQueue 把队列翻成
                // 'skipped' 之后,worker 内存里那批已 fetch 的 batch 可能仍跑完 markDone——
                // 不加 guard 会把刚 abort 掉的行又改回 'done',让"中止当前队列"不可靠
                try db.execute(sql: """
                    UPDATE item
                    SET extracted_text = ?,
                        extracted_text_source = 'ocr',
                        ocr_state = 'done',
                        ingested_at_ns = ?
                    WHERE id = ?
                      AND ocr_state = 'pending'
                      AND deleted_at_ns IS NULL
                """, arguments: [normalized, stamp, id])
                return stamp
            }
        } catch {
            log("markDone failed for \(id): \(error)")
        }
        // OCR Phase 2：commit 后触发 cursor_advanced 让对端 < 1s 拿到 OCR 结果。
        // tombstone 路径（UPDATE 0 行）也会 stamp + broadcast——浪费 1 个空 tick 不致命，
        // PullWorker /since 拉到的也是空更新（id 已被自家 dedup / 软删），无害
        if let ns = stampedNs {
            onCursorAdvanced(ns)
        }
    }

    /// 标 skipped。**不** bump ingested_at_ns —— skipped 是终态，没必要让下游再拉一遍
    /// 把"图里没字"这件事广播出去（item 行实质内容未变）。
    ///
    /// **PR 4 之前**这里还往 `last_push_error` 列写 reason；该列随 push 链路一起被 v8
    /// migration 删了，操作员排错只能看 stderr `ocr:` 日志（reason 仍 log 出去）。
    /// `deleted_at_ns IS NULL` guard 让 fetchPending→processOne 之间被软删的行 0 行影响
    private func markSkipped(id: String, reason: String) async {
        do {
            try await database.pool.write { db in
                // `ocr_state = 'pending'` guard 同 markDone:abort 已经把行翻成 'skipped'
                // 时,worker 后续 markSkipped 是 no-op。markFailed 同理(不让 worker 把
                // abort 后的 'skipped' 覆写成 'failed')
                try db.execute(sql: """
                    UPDATE item
                    SET ocr_state = 'skipped'
                    WHERE id = ?
                      AND ocr_state = 'pending'
                      AND deleted_at_ns IS NULL
                """, arguments: [id])
            }
            log("skipped \(id): \(reason)")
        } catch {
            log("markSkipped failed for \(id): \(error)")
        }
    }

    /// 标 failed。同 skipped 不 bump ingested_at_ns；用户 retry-failed-ocr 翻回
    /// pending 时再让 worker 处理。reason 仅 log，不落 DB（同 markSkipped 注释）
    private func markFailed(id: String, reason: String) async {
        do {
            try await database.pool.write { db in
                try db.execute(sql: """
                    UPDATE item
                    SET ocr_state = 'failed'
                    WHERE id = ?
                      AND ocr_state = 'pending'
                      AND deleted_at_ns IS NULL
                """, arguments: [id])
            }
            log("failed \(id): \(reason)")
        } catch {
            log("markFailed failed for \(id): \(error)")
        }
    }
}

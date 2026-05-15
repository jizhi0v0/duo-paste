import Foundation
import CryptoKit
import GRDB

public struct CaptureResult: Sendable {
    public enum Outcome: Sendable, Equatable {
        case inserted
        case mergedWithPrevious   // 与最近一条同内容近时间重复，仅刷新 captured_at
        case skippedEmpty
        /// 超过 CaptureLimits 上限：意外捕获巨型对象（4K 长截图 / Cmd+A 大日志等）。
        /// `bytes` 是观察到的实际大小，`limit` 是当时生效的阈值，`kind` 区分 text/blob。
        /// macOS pasteboard 自身**不**受影响，Cmd+V 仍可正常粘贴——只是不进 duo-paste 历史。
        case skippedTooLarge(kind: SkipKind, bytes: Int, limit: Int)
    }

    public enum SkipKind: Sendable, Equatable {
        case text
        case blob
    }

    public let outcome: Outcome
    public let item: Item?
}

public actor CaptureService {
    public let database: Database
    public let blobs: BlobStore
    public let deviceID: String
    /// Blob 路径合并窗口（纳秒）。默认从 limits.mergeWindowSec 推导（300s）。
    /// 显式参数仅用于测试覆盖：生产路径走 config.capture.merge_window_sec。
    public let mergeWindowNs: Int64
    /// Text 路径合并窗口（纳秒）。`nil` = 永久 dedup（无时间限制）；
    /// 非 nil 表示 N 纳秒内同 kind+text_full 合并。从 limits.textMergeWindowSec 推导：
    /// nil → nil；0 → 0（完全禁用合并）；N>0 → N * 1e9。
    public let textMergeWindowNs: Int64?
    /// 捕获字节守门 + 合并窗口配置源。
    public let limits: Config.CaptureLimits
    /// PR 3 mesh 通知钩子。primary 路径 / merge bump-ingestNs 路径 commit 后触发，
    /// 闭包参数 = 这次刷新的 ingested_at_ns。生产 AppDelegate 注入"投递到 WSBroadcaster"
    /// 闭包；standalone / client / 测试默认 no-op。
    ///
    /// **闭包必须 Sendable + 不能 throw**——CaptureService 是 actor，writer tx 已 commit
    /// 后再调；闭包出错应该 log 不影响业务路径。
    private let onCursorAdvanced: @Sendable (Int64) -> Void

    public init(
        database: Database,
        blobs: BlobStore,
        deviceID: String,
        mergeWindowNs: Int64? = nil,
        textMergeWindowNs: Int64?? = nil,
        limits: Config.CaptureLimits = .default,
        onCursorAdvanced: @escaping @Sendable (Int64) -> Void = { _ in }
    ) {
        self.database = database
        self.blobs = blobs
        self.deviceID = deviceID
        // 显式 mergeWindowNs 用于测试；生产从 limits.mergeWindowSec 推导。
        self.mergeWindowNs = mergeWindowNs ?? Int64(limits.mergeWindowSec) * 1_000_000_000
        // textMergeWindowNs 是 Int64?? —— 外层 nil 表示"用 limits 推导"，外层非 nil 表示
        // 显式注入（包括 .some(nil) 表示永久 dedup）。生产代码不会传它，limits 决定。
        if case .some(let explicit) = textMergeWindowNs {
            self.textMergeWindowNs = explicit
        } else if let sec = limits.textMergeWindowSec {
            self.textMergeWindowNs = Int64(sec) * 1_000_000_000
        } else {
            self.textMergeWindowNs = nil  // 永久 dedup
        }
        self.limits = limits
        self.onCursorAdvanced = onCursorAdvanced
    }

    @discardableResult
    public func ingest(_ captured: CapturedPasteboard) throws -> CaptureResult {
        // M1 阶段：.file 只记录文件路径（文本形式），不读文件字节。
        // 真正读取并存为 blob 留到 M2/3 视体积策略再做。
        if captured.blob != nil {
            guard let blob = captured.blob, !blob.isEmpty else {
                return CaptureResult(outcome: .skippedEmpty, item: nil)
            }
            // 守门：blob 字节 > limit → 跳过。
            // 重要：限的是从 NSPasteboard 读出的字节，不影响 NSPasteboard 自身——
            // 用户 Cmd+V 仍可立即粘贴这个 80MB 截图，只是它不进 ⌥⌘V 历史。
            if blob.count > limits.maxBlobBytes {
                return CaptureResult(
                    outcome: .skippedTooLarge(kind: .blob, bytes: blob.count, limit: limits.maxBlobBytes),
                    item: nil
                )
            }
            return try ingestBlob(captured, blob: blob)
        }
        guard let text = captured.text, !text.isEmpty else {
            return CaptureResult(outcome: .skippedEmpty, item: nil)
        }
        // 守门：text UTF-8 字节 > limit → 跳过。`.file` kind 走的也是这条，
        // 但文件路径字符串永远 < 1KB，512KB 默认 cap 0 风险误伤。
        let textBytes = text.utf8.count
        if textBytes > limits.maxTextBytes {
            return CaptureResult(
                outcome: .skippedTooLarge(kind: .text, bytes: textBytes, limit: limits.maxTextBytes),
                item: nil
            )
        }
        return try ingestText(captured, text: text)
    }

    private func ingestText(_ c: CapturedPasteboard, text: String) throws -> CaptureResult {
        let preview = makePreview(text)
        let now = c.capturedAtNs

        let result: CaptureResult = try database.pool.write { db -> CaptureResult in
            // 查最近一条候选 dedup（同 kind + 同内容 + 未删行）。
            // textMergeWindowNs == nil → 永久 dedup，跨任意时间合并（剪贴板心智里
            //   重复文本不像重复图片需要时间线，bump 一条最旧的让它浮顶即可）。
            // textMergeWindowNs == 0 → 完全禁用合并（每次都插新行）。
            // textMergeWindowNs > 0 → N 纳秒内合并，跟旧 mergeWindowNs 行为兼容。
            //
            // **mesh 拓扑下 dedup 必须限定 origin=self**：合表后 item 表含 peer 行，
            // 不加 origin 过滤会命中并 bump peer 行的 captured_at_ns，等于本机改了
            // 别人的数据（peer 视角看是漂移）。详 plan §"CaptureService 改动" 第 3 条
            let mergeCandidate: Item?
            if textMergeWindowNs == 0 {
                mergeCandidate = nil
            } else {
                var query = Item
                    .filter(Column("kind") == c.kind.rawValue)
                    .filter(Column("text_full") == text)
                    .filter(Column("origin_device") == deviceID)
                    .filter(Column("deleted_at_ns") == nil)
                if let windowNs = textMergeWindowNs {
                    let mergeFloor = now - windowNs
                    query = query.filter(Column("captured_at_ns") >= mergeFloor)
                }
                mergeCandidate = try query
                    .order(Column("captured_at_ns").desc)
                    .fetchOne(db)
            }
            if let last = mergeCandidate {
                var updated = last
                updated.capturedAtNs = now
                if updated.sourceApp == nil { updated.sourceApp = c.sourceAppBundleID }
                if updated.sourceAppName == nil { updated.sourceAppName = c.sourceAppName }
                // mesh 路径永远 stamp ingested_at_ns，让 peers 通过 /since 看到这次刷新
                updated.ingestedAtNs = try DuoPasteCore.Database.nextIngestNs(db, now: now)
                try updated.update(db)
                return CaptureResult(outcome: .mergedWithPrevious, item: updated)
            }

            // 走 nextIngestNs 保证 commit 顺序 = ingested_at_ns 顺序，/since cursor
            // 才不会漏行（详见 Database.nextIngestNs 注释）
            let ingestNs = try DuoPasteCore.Database.nextIngestNs(db, now: now)
            let item = Item(
                id: UUIDv7.generateString(),
                originDevice: deviceID,
                capturedAtNs: now,
                ingestedAtNs: ingestNs,
                kind: c.kind,
                sourceApp: c.sourceAppBundleID,
                sourceAppName: c.sourceAppName,
                preview: preview,
                textFull: text
            )
            try item.insert(db)
            return CaptureResult(outcome: .inserted, item: item)
        }
        broadcastIfAdvanced(item: result.item, outcome: result.outcome)
        return result
    }

    private func ingestBlob(_ c: CapturedPasteboard, blob: Data) throws -> CaptureResult {
        // 先内容寻址写盘，得到 sha256
        let info = try blobs.put(blob, ext: c.blobExt)
        let preview = c.fileName ?? "[\(c.kind.rawValue) \(humanSize(info.size))]"
        let now = c.capturedAtNs
        let mergeFloor = now - mergeWindowNs

        let result: CaptureResult = try database.pool.write { db -> CaptureResult in
            // 同 ingestText：blob 合并候选必须限定 origin=self，避免 bump peer 行
            if let last = try Item
                .filter(Column("kind") == c.kind.rawValue)
                .filter(Column("blob_sha256") == info.sha256)
                .filter(Column("origin_device") == deviceID)
                .filter(Column("captured_at_ns") >= mergeFloor)
                .filter(Column("deleted_at_ns") == nil)
                .order(Column("captured_at_ns").desc)
                .fetchOne(db)
            {
                var updated = last
                updated.capturedAtNs = now
                if updated.sourceApp == nil { updated.sourceApp = c.sourceAppBundleID }
                if updated.sourceAppName == nil { updated.sourceAppName = c.sourceAppName }
                updated.ingestedAtNs = try DuoPasteCore.Database.nextIngestNs(db, now: now)
                try updated.update(db)
                return CaptureResult(outcome: .mergedWithPrevious, item: updated)
            }

            let ingestNs = try DuoPasteCore.Database.nextIngestNs(db, now: now)
            // 入库即标 ocr_state=pending 让 OCR worker 扫到。范围：
            //   - kind=image：所有 image kind 行（一向如此）
            //   - kind=file + blob_mime=image/*：PasteboardWatcher 给单 .png 文件路径
            //     额外读了字节进 BlobStore 做 mirror（c.blob 非 nil 走到本路径 →
            //     blob_mime 已被设成 image/<ext>）。这类行 OCRWorker 也能扫
            // 其它 kind（file path-only / non-image blob）不标。判别用 blob_mime 不用
            // 路径后缀启发（mime 是 capture 时读字节成功才设的，等价于"OCR 可用字节就绪"）
            let isImageBlob = (c.kind == .image)
                || (c.kind == .file && (c.blobMime?.hasPrefix("image/") == true))
            let ocrState: OCRState? = isImageBlob ? .pending : nil
            // text_full 契约（v9 之后）：
            //   - file kind：路径列表（Cmd+V 时写回 NSPasteboard 当 file URL）。c.text 是
            //     PasteboardWatcher \n-join 的多路径串；单文件无 c.text 时用 fileName 兜底
            //   - image kind：永远 nil。image 的"可粘贴主体"是字节，fileName 不参与 paste
            //     路径（Copyback.copy .image 直接 setData），装 textFull 只污染 FTS5 索引
            //   - 其他 blob kind：暂用 fileName（沿用旧行为）
            // v9 migration step 3 已把历史 image kind text_full 清 NULL，新数据按此契约统一
            let resolvedTextFull: String?
            switch c.kind {
            case .file:
                resolvedTextFull = c.text ?? c.fileName
            case .image:
                resolvedTextFull = nil
            default:
                resolvedTextFull = c.fileName
            }
            let item = Item(
                id: UUIDv7.generateString(),
                originDevice: deviceID,
                capturedAtNs: now,
                ingestedAtNs: ingestNs,
                kind: c.kind,
                sourceApp: c.sourceAppBundleID,
                sourceAppName: c.sourceAppName,
                preview: preview,
                textFull: resolvedTextFull,
                blobSha256: info.sha256,
                blobSize: info.size,
                blobMime: c.blobMime,
                ocrState: ocrState
            )
            try item.insert(db)
            return CaptureResult(outcome: .inserted, item: item)
        }
        broadcastIfAdvanced(item: result.item, outcome: result.outcome)
        return result
    }

    /// commit 后回调钩子：item.ingested_at_ns 非 nil → 这次 capture/merge 推进了 cursor，
    /// 触发 onCursorAdvanced 让 server 端 broadcaster fan-out cursor_advanced 帧给 peers。
    /// skipped 路径不触发（没有 item）。mesh 拓扑下每台机都是 peer，不再有 client 跳过条件
    private func broadcastIfAdvanced(item: Item?, outcome: CaptureResult.Outcome) {
        guard let item, let ns = item.ingestedAtNs else { return }
        switch outcome {
        case .inserted, .mergedWithPrevious:
            onCursorAdvanced(ns)
        case .skippedEmpty, .skippedTooLarge:
            return
        }
    }

    private func makePreview(_ text: String, max: Int = 280) -> String {
        if text.count <= max { return text }
        let prefix = text.prefix(max)
        return String(prefix) + "…"
    }

    private func humanSize(_ size: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var s = Double(size)
        var i = 0
        while s >= 1024 && i < units.count - 1 {
            s /= 1024
            i += 1
        }
        return String(format: "%.1f %@", s, units[i])
    }
}

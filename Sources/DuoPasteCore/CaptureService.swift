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
    /// 同内容合并窗口（纳秒）。默认从 limits.mergeWindowSec 推导（300s）。
    /// 显式参数仅用于测试覆盖：生产路径走 config.capture.merge_window_sec。
    public let mergeWindowNs: Int64
    /// 捕获字节守门 + 合并窗口配置源。
    public let limits: Config.CaptureLimits

    public init(
        database: Database,
        blobs: BlobStore,
        deviceID: String,
        mergeWindowNs: Int64? = nil,
        limits: Config.CaptureLimits = .default
    ) {
        self.database = database
        self.blobs = blobs
        self.deviceID = deviceID
        // 显式 mergeWindowNs 用于测试；生产从 limits.mergeWindowSec 推导。
        self.mergeWindowNs = mergeWindowNs ?? Int64(limits.mergeWindowSec) * 1_000_000_000
        self.limits = limits
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
        let role = database.role
        let now = c.capturedAtNs
        let mergeFloor = now - mergeWindowNs

        return try database.pool.write { db -> CaptureResult in
            // 查最近一条候选 dedup（同 kind + 同内容 + 在窗口内）
            if let last = try Item
                .filter(Column("kind") == c.kind.rawValue)
                .filter(Column("text_full") == text)
                .filter(Column("captured_at_ns") >= mergeFloor)
                .filter(Column("deleted_at_ns") == nil)
                .order(Column("captured_at_ns").desc)
                .fetchOne(db)
            {
                var updated = last
                updated.capturedAtNs = now
                if updated.sourceApp == nil { updated.sourceApp = c.sourceAppBundleID }
                if updated.sourceAppName == nil { updated.sourceAppName = c.sourceAppName }
                if role == .client {
                    // 客户端模式下重置推送状态，让 push worker 把"刷新时间"也同步过去
                    updated.pushState = .pending
                    updated.pushAttempts = 0
                    updated.lastPushError = nil
                } else {
                    // primary 上 merge 也要 bump ingested_at_ns，否则 mirror clients
                    // 已经把这行 cursor 推进过去后再也看不到这次 capturedAt 刷新——
                    // 见 plan moonlit-wave.md "primary 在 /since 里也回放"
                    updated.ingestedAtNs = try DuoPasteCore.Database.nextIngestNs(db, now: now)
                }
                try updated.update(db)
                return CaptureResult(outcome: .mergedWithPrevious, item: updated)
            }

            // primary 路径走 nextIngestNs 保证 commit 顺序 = ingested_at_ns 顺序，
            // /since cursor 才不会漏行（详见 Database.nextIngestNs 注释）。
            // client 路径 ingested_at_ns 永远 nil——primary 收到 push 时再打。
            let ingestNs: Int64? = role == .primary
                ? try DuoPasteCore.Database.nextIngestNs(db, now: now)
                : nil
            let item = Item(
                id: UUIDv7.generateString(),
                originDevice: deviceID,
                capturedAtNs: now,
                ingestedAtNs: ingestNs,
                kind: c.kind,
                sourceApp: c.sourceAppBundleID,
                sourceAppName: c.sourceAppName,
                preview: preview,
                textFull: text,
                pushState: role == .primary ? .acked : .pending
            )
            try item.insert(db)
            return CaptureResult(outcome: .inserted, item: item)
        }
    }

    private func ingestBlob(_ c: CapturedPasteboard, blob: Data) throws -> CaptureResult {
        // 先内容寻址写盘，得到 sha256
        let info = try blobs.put(blob, ext: c.blobExt)
        let preview = c.fileName ?? "[\(c.kind.rawValue) \(humanSize(info.size))]"
        let role = database.role
        let now = c.capturedAtNs
        let mergeFloor = now - mergeWindowNs

        return try database.pool.write { db -> CaptureResult in
            if let last = try Item
                .filter(Column("kind") == c.kind.rawValue)
                .filter(Column("blob_sha256") == info.sha256)
                .filter(Column("captured_at_ns") >= mergeFloor)
                .filter(Column("deleted_at_ns") == nil)
                .order(Column("captured_at_ns").desc)
                .fetchOne(db)
            {
                var updated = last
                updated.capturedAtNs = now
                if updated.sourceApp == nil { updated.sourceApp = c.sourceAppBundleID }
                if updated.sourceAppName == nil { updated.sourceAppName = c.sourceAppName }
                if role == .client {
                    updated.pushState = .pending
                    updated.pushAttempts = 0
                    updated.lastPushError = nil
                } else {
                    // 同 ingestText 注释：primary merge 要 bump ingested_at_ns 让 mirror 看见
                    updated.ingestedAtNs = try DuoPasteCore.Database.nextIngestNs(db, now: now)
                }
                try updated.update(db)
                return CaptureResult(outcome: .mergedWithPrevious, item: updated)
            }

            let ingestNs: Int64? = role == .primary
                ? try DuoPasteCore.Database.nextIngestNs(db, now: now)
                : nil
            // image kind 入库即标 ocr_state=pending，让未来 OCR worker 扫到。
            // file kind 也是 blob 但不走 OCR（文件路径是字符串，BlobStore 里没字节）。
            // client 模式下也写 pending —— push 给 primary 时 ocr_state 不上 wire，
            // primary 收到后 IngestRequest.toItem 会重新按 kind 设 pending。本机这一列
            // 在 promote-to-primary 时会被本地 OCR worker 接管
            let ocrState: OCRState? = c.kind == .image ? .pending : nil
            let item = Item(
                id: UUIDv7.generateString(),
                originDevice: deviceID,
                capturedAtNs: now,
                ingestedAtNs: ingestNs,
                kind: c.kind,
                sourceApp: c.sourceAppBundleID,
                sourceAppName: c.sourceAppName,
                preview: preview,
                // file kind 保留完整路径供 Finder reveal + FTS 搜索；image/其他 kind 用 fileName
                textFull: c.kind == .file ? (c.text ?? c.fileName) : c.fileName,
                blobSha256: info.sha256,
                blobSize: info.size,
                blobMime: c.blobMime,
                pushState: role == .primary ? .acked : .pending,
                ocrState: ocrState
            )
            try item.insert(db)
            return CaptureResult(outcome: .inserted, item: item)
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

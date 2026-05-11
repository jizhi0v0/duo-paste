import Foundation
import CryptoKit
import GRDB

public struct CaptureResult: Sendable {
    public enum Outcome: Sendable {
        case inserted
        case mergedWithPrevious   // 与最近一条同内容近时间重复，仅刷新 captured_at
        case skippedEmpty
    }
    public let outcome: Outcome
    public let item: Item?
}

public actor CaptureService {
    public let database: Database
    public let blobs: BlobStore
    public let deviceID: String
    /// 同内容合并窗口（纳秒）。默认 2s。
    public let mergeWindowNs: Int64

    public init(
        database: Database,
        blobs: BlobStore,
        deviceID: String,
        mergeWindowNs: Int64 = 2 * 1_000_000_000
    ) {
        self.database = database
        self.blobs = blobs
        self.deviceID = deviceID
        self.mergeWindowNs = mergeWindowNs
    }

    @discardableResult
    public func ingest(_ captured: CapturedPasteboard) throws -> CaptureResult {
        // M1 阶段：.file 只记录文件路径（文本形式），不读文件字节。
        // 真正读取并存为 blob 留到 M2/3 视体积策略再做。
        if captured.blob != nil {
            guard let blob = captured.blob, !blob.isEmpty else {
                return CaptureResult(outcome: .skippedEmpty, item: nil)
            }
            return try ingestBlob(captured, blob: blob)
        }
        guard let text = captured.text, !text.isEmpty else {
            return CaptureResult(outcome: .skippedEmpty, item: nil)
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
                // 客户端模式下重置推送状态，让 push worker 把"刷新时间"也同步过去
                if role == .client {
                    updated.pushState = .pending
                    updated.pushAttempts = 0
                    updated.lastPushError = nil
                }
                try updated.update(db)
                return CaptureResult(outcome: .mergedWithPrevious, item: updated)
            }

            let item = Item(
                id: UUIDv7.generateString(),
                originDevice: deviceID,
                capturedAtNs: now,
                ingestedAtNs: role == .primary ? now : nil,
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
                }
                try updated.update(db)
                return CaptureResult(outcome: .mergedWithPrevious, item: updated)
            }

            let item = Item(
                id: UUIDv7.generateString(),
                originDevice: deviceID,
                capturedAtNs: now,
                ingestedAtNs: role == .primary ? now : nil,
                kind: c.kind,
                sourceApp: c.sourceAppBundleID,
                sourceAppName: c.sourceAppName,
                preview: preview,
                textFull: c.fileName,
                blobSha256: info.sha256,
                blobSize: info.size,
                blobMime: c.blobMime,
                pushState: role == .primary ? .acked : .pending
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

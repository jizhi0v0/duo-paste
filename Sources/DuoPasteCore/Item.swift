import Foundation
import GRDB

public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case rtf
    case html
    case url
    case image
    case file
}

/// 图片 OCR 状态机。NULL = 非 image kind / 无需 OCR。
/// 区分 "没扫过 vs 扫过但无文字" / "失败 vs 成功无文本"——OCR worker 调度依据。
/// 用 String raw + Codable 让 wire 上是 plain string；老 peer 不发该字段时
/// `Item.ocrState` decode 成 nil 兼容
public enum OCRState: String, Codable, Sendable {
    case pending
    case done
    case failed
    case skipped
}

public struct Item: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item"

    public var id: String
    public var originDevice: String
    public var capturedAtNs: Int64
    public var ingestedAtNs: Int64?
    public var kind: ItemKind
    public var sourceApp: String?
    public var sourceAppName: String?
    public var preview: String?
    public var textFull: String?
    public var blobSha256: String?
    public var blobSize: Int64?
    public var blobMime: String?
    public var pinned: Bool
    public var deletedAtNs: Int64?
    public var ocrState: OCRState?

    public init(
        id: String,
        originDevice: String,
        capturedAtNs: Int64,
        ingestedAtNs: Int64? = nil,
        kind: ItemKind,
        sourceApp: String? = nil,
        sourceAppName: String? = nil,
        preview: String? = nil,
        textFull: String? = nil,
        blobSha256: String? = nil,
        blobSize: Int64? = nil,
        blobMime: String? = nil,
        pinned: Bool = false,
        deletedAtNs: Int64? = nil,
        ocrState: OCRState? = nil
    ) {
        self.id = id
        self.originDevice = originDevice
        self.capturedAtNs = capturedAtNs
        self.ingestedAtNs = ingestedAtNs
        self.kind = kind
        self.sourceApp = sourceApp
        self.sourceAppName = sourceAppName
        self.preview = preview
        self.textFull = textFull
        self.blobSha256 = blobSha256
        self.blobSize = blobSize
        self.blobMime = blobMime
        self.pinned = pinned
        self.deletedAtNs = deletedAtNs
        self.ocrState = ocrState
    }

    /// sourceApp 用的 sentinel：表示"本机 duo-paste 内 Cmd+C"。watcher 在 self
    /// frontmost 时注入；UI 据此显示自定义 icon 而非 LaunchServices 查不到时的通用
    /// kind fallback。duo-paste 是 LSUIElement SwiftPM 二进制，frontApp.bundleIdentifier
    /// 多半返回 nil，靠 sentinel 把"self capture"语义显式落到 DB 里
    public static let selfSourceAppSentinel = "io.duopaste.self"

    public var isSelfCapture: Bool { sourceApp == Self.selfSourceAppSentinel }

    enum CodingKeys: String, CodingKey {
        case id
        case originDevice = "origin_device"
        case capturedAtNs = "captured_at_ns"
        case ingestedAtNs = "ingested_at_ns"
        case kind
        case sourceApp = "source_app"
        case sourceAppName = "source_app_name"
        case preview
        case textFull = "text_full"
        case blobSha256 = "blob_sha256"
        case blobSize = "blob_size"
        case blobMime = "blob_mime"
        case pinned
        case deletedAtNs = "deleted_at_ns"
        case ocrState = "ocr_state"
    }
}

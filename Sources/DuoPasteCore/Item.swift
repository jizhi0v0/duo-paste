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

/// `extracted_text` 来源标记——这段辅助索引文本是从什么 extractor 提取出来的。
/// 当前只有 OCR；未来加视频字幕提取/PDF 文字层抽取/语音转写时复用同一列、加 case。
/// 用 String raw + Codable 让 wire 上是 plain string；老 peer 不发字段时 decode 成 nil
public enum ExtractedTextSource: String, Codable, Sendable {
    case ocr
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
    /// 从 blob 内容派生的辅助索引文本——OCR/字幕/PDF 文字层/未来 ASR。FTS5 索引列之一。
    /// `text_full` 永远装"原始可粘贴文本"，本列装"从二进制提取出来的可搜文本"——
    /// 两列语义切干净，不再 kind-dependent 混用（v9 migration 拆出来）
    public var extractedText: String?
    /// `extracted_text` 是哪种 extractor 写入的。nil 表示该行没有 extracted text
    /// （或老 peer 没发字段）；非 nil 时 `.ocr` 是当前唯一来源
    public var extractedTextSource: ExtractedTextSource?

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
        ocrState: OCRState? = nil,
        extractedText: String? = nil,
        extractedTextSource: ExtractedTextSource? = nil
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
        self.extractedText = extractedText
        self.extractedTextSource = extractedTextSource
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
        case extractedText = "extracted_text"
        case extractedTextSource = "extracted_text_source"
    }
}

extension Item {
    /// 卡片/历史列表 cell 用的文本源——**textFull 优先**,preview 只作为 nil 兜底。
    ///
    /// preview 字段是 `CaptureService.makePreview` 截到 280 字符 + `…` 的网络传输短预览
    /// (给 server-client 列表渲染省 payload 用)。daemon 跟 macOS SearchView 同进程读
    /// SQLite,直接拿完整的 textFull;iOS 通过 /since 也会拿到完整 textFull,只有 textFull
    /// 全部为 nil 时才退回到截过的 preview。
    ///
    /// 错误用 preview 会导致卡片末尾出现 server 加的 `…` 截断符,且文本仅 280 字符
    /// 长度时填不满卡片的 `lineLimit` 留大块空白(2026-05-20 已踩过)。
    ///
    /// - Parameter maxChars: 输出上限。SwiftUI Text + lineLimit 自身会按行 truncate,
    ///   这里只做"O(n) attribute apply 防御性截断",传入应远大于卡片可视行数 × 每行字符。
    ///   macOS 卡片 240×204 frame ≈ 11 行 × 15 字符 = 165 字符,默认 512 给 3 倍缓冲。
    /// - Returns: 适合喂给 Text/NSAttributedString 的字符串;item 没任何文本时返回空串。
    public func cardPreviewSource(maxChars: Int = 512) -> String {
        if let t = textFull, !t.isEmpty {
            return t.count <= maxChars ? t : String(t.prefix(maxChars))
        }
        if let p = preview, !p.isEmpty {
            return p
        }
        return ""
    }
}

extension Item {
    /// 跨 origin 同 `text_full` fold——剪贴板"文本永久 dedup"的单点契约定义。
    ///
    /// 在 Mac + iOS UI 显示之前都走这条逻辑：Continuity / ToDesk / 跨 peer pull 等链路
    /// 会把同文本以不同 `origin_device` 重复落库，UI 展示时折叠回一条让"同内容"心智成立。
    ///
    /// **契约（必须与 Mac `Search.fetchHitsFolded` / iOS HistoryStore.filtered 同源）**：
    /// - **Tombstone 永远跳过**（`deletedAtNs != nil`）——softDelete 不动 `textFull`(只动
    ///   `deletedAtNs + ingestedAtNs`)，wire 上 tombstone 仍带原 textFull；若不防御 skip，
    ///   tombstone 可能因 `capturedAtNs` 大于活的 sibling 成为 winner，UI 看到被删除内容。
    ///   Mac 端走 SQL `WHERE deleted_at_ns IS NULL` 在 fold 前过滤，iOS HistoryStore.merge
    ///   也已剔除——本函数作为 public API 不依赖 caller 记忆，自带这层兜底
    /// - 参与：仅 `blob_sha256 == nil` 且 `text_full` 非空的行（text / url / rtf / html /
    ///   file 文本路径都按 byte-equal 等同处理）；blob kind（image）**不**参与——同 sha
    ///   多次复制可能是用户故意保留时间线
    /// - Key：`text_full` 原值，大小写敏感、不 trim、不归一化空白
    /// - Winner：`max(capturedAtNs)`；同 ns 时保留先入的（与 dict 语义一致）
    /// - Pinned：参与行 `pinned` OR 聚合赋给 winner——"pin 是对内容的属性而非具体 row"
    /// - **不排序**：fold 后顺序未定义，调用方自行 sort（Mac 走 prefix24h 三层契约，
    ///   iOS 默认 list 走 pinned + captured_at_ns DESC）
    /// - **不做 kind 白名单 / pinnedOnly 过滤**：query 维度的过滤由调用方在 fold 前/后处理
    ///
    /// Mac 的 `fetchHitsFolded` 因为要同时持有 FTS5 snippet，内部走自己的 tuple-aware fold
    /// 副本——契约必须与本函数对齐，行为分叉是 bug。回归测试 `ItemFoldTests.swift`
    /// + Mac 路径 `SearchFoldV7Tests.swift`。
    ///
    /// - Parameter items: 待 fold 的行列表（tombstone 由本函数 skip，caller 无需预过滤）
    /// - Returns: fold 后的行列表（不含 tombstone），顺序未定义
    public static func foldByTextFull(_ items: [Item]) -> [Item] {
        var byText: [String: Item] = [:]
        var nonText: [Item] = []
        nonText.reserveCapacity(items.count)
        for it in items {
            if it.deletedAtNs != nil { continue }
            if it.blobSha256 == nil, let tf = it.textFull, !tf.isEmpty {
                if let existing = byText[tf] {
                    var winner = it.capturedAtNs > existing.capturedAtNs ? it : existing
                    winner.pinned = it.pinned || existing.pinned
                    byText[tf] = winner
                } else {
                    byText[tf] = it
                }
            } else {
                nonText.append(it)
            }
        }
        return Array(byText.values) + nonText
    }
}

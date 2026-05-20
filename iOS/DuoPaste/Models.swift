import Foundation
import DuoPasteCore

/// View 端用的小工具——把 DuoPasteCore.Item 上的字段转成 SwiftUI 直接消费的形态。
/// 不另起 view model wrapper,Item 已经是 Codable / Sendable / Identifiable / Hashable,
/// 直接喂进 List / NavigationLink(value:) 即可。
extension Item {
    var capturedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(capturedAtNs) / 1_000_000_000)
    }

    /// UI 卡片用预览。走 `Item.cardPreviewSource` (textFull 优先,见该函数 doc 说明
    /// preview 为何不能直接用作卡片源)。HistoryCellView lineLimit(5) ≈ 95 中文字符,
    /// maxChars=300 给 3 倍缓冲让 SwiftUI 行数控制截断而非 server 字符控制。
    /// image/file kind textFull 为空时退占位符。
    var displayPreview: String {
        let src = cardPreviewSource(maxChars: 300)
        if !src.isEmpty { return src }
        switch kind {
        case .image: return "[image]"
        case .file:  return "[file]"
        default:     return "(空)"
        }
    }

    /// 详情页用——优先 textFull 完整内容,退到 preview。
    var displayFull: String {
        textFull ?? preview ?? displayPreview
    }

    var kindIconName: String {
        switch kind {
        case .text:  return "text.alignleft"
        case .url:   return "link"
        case .file:  return "doc"
        case .image: return "photo"
        case .rtf:   return "doc.richtext"
        case .html:  return "globe"
        }
    }

    var isTombstone: Bool {
        deletedAtNs != nil
    }
}

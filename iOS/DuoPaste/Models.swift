import Foundation
import DuoPasteCore

/// View 端用的小工具——把 DuoPasteCore.Item 上的字段转成 SwiftUI 直接消费的形态。
/// 不另起 view model wrapper,Item 已经是 Codable / Sendable / Identifiable / Hashable,
/// 直接喂进 List / NavigationLink(value:) 即可。
extension Item {
    var capturedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(capturedAtNs) / 1_000_000_000)
    }

    /// UI 单行预览。preview 优先(server 端已 truncate),退到 textFull 前 200 字,
    /// 再退到占位符。
    var displayPreview: String {
        if let p = preview, !p.isEmpty { return p }
        if let t = textFull, !t.isEmpty {
            return String(t.prefix(200))
        }
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

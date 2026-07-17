import Foundation

/// “粘贴为纯文本”的纯函数契约。
///
/// Core 不依赖 AppKit，因此 RTF / HTML 的实际解析由调用方注入。这里负责把 kind 白名单、
/// decoder 路由和多选 all-or-nothing 语义钉在一个跨 UI 可单测的位置。
public enum PlainTextPaste {
    public typealias Decoder = (_ raw: String) -> String?

    /// 第一版只支持真正的文本/富文本 payload。URL 虽然也有字符串 representation，
    /// 但 roadmap 明确限定 text/rtf/html，避免把“普通粘贴 URL”重复做成第二个菜单动作。
    public static func supports(_ kind: ItemKind) -> Bool {
        switch kind {
        case .text, .rtf, .html:
            return true
        case .url, .image, .file:
            return false
        }
    }

    /// 单项解析。RTF/HTML decoder 失败时返回 nil，绝不把 raw markup 当成 plain fallback。
    public static func text(
        for item: Item,
        decodeRTF: Decoder,
        decodeHTML: Decoder
    ) -> String? {
        guard supports(item.kind), let raw = item.textFull, !raw.isEmpty else { return nil }

        let resolved: String?
        switch item.kind {
        case .text:
            resolved = raw
        case .rtf:
            resolved = decodeRTF(raw)
        case .html:
            resolved = decodeHTML(raw)
        case .url, .image, .file:
            return nil
        }
        guard let resolved, !resolved.isEmpty else { return nil }
        return resolved
    }

    /// 多选保持 selection 顺序，以换行拼接；任何一项不支持/解码失败都整体拒绝，
    /// 避免用户选了 N 项却静默只粘 N-1 项。
    public static func joinedText(
        for items: [Item],
        separator: String = "\n",
        decodeRTF: Decoder,
        decodeHTML: Decoder
    ) -> String? {
        guard !items.isEmpty else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(items.count)
        for item in items {
            guard let part = text(for: item, decodeRTF: decodeRTF, decodeHTML: decodeHTML) else {
                return nil
            }
            parts.append(part)
        }
        return parts.joined(separator: separator)
    }
}

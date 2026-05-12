import Foundation

/// 判别 HTML payload 是否来自 WebKit / Chromium 系（浏览器、Electron、
/// Codex / ChatGPT desktop、Claude Desktop 等内嵌 web view 的 app）。
///
/// 这些 app 写剪贴板时系统会在 HTML 前面注入 `<meta charset='utf-8'>`，
/// 后面跟着带 inline style 和 `data-*` 属性的一坨 markup。三个验证过的样本：
///
///   - Codex overlay: `<meta charset='utf-8'><div data-selected-text-overlay-target=...`
///   - Chrome Google AI Overview: `<meta charset='utf-8'><span data-subtree=...`
///   - Claude Desktop: `<meta charset='utf-8'><p class="font-claude-response-body...`
///
/// 原生富文本 app（Pages / Keynote / Mail / Notes）写 HTML 不带这个前缀。
///
/// 命中 → PasteboardWatcher 视作 web view selection，降级到 `.string` plain text 入库。
/// 行为对齐 Paste.app：列表干净 + FTS 命中关键词 + 粘回到任意目标都是 plain。
public func looksLikeWebViewHTML(_ html: String) -> Bool {
    // trim 前导空白后判前缀，case-insensitive，允许单引号或双引号
    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    return lower.hasPrefix("<meta charset='utf-8'>")
        || lower.hasPrefix("<meta charset=\"utf-8\">")
}

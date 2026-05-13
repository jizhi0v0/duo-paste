import Foundation

/// 判别 HTML payload 是否来自 WebKit / Chromium 系（浏览器、Electron、
/// Codex / ChatGPT desktop、Claude Desktop、DingTalk 等内嵌 web view 的 app）。
///
/// 这些 app 写剪贴板时系统会在 HTML 前面注入 utf-8 charset 声明，
/// 后面跟着带 inline style 和 `data-*` 属性的一坨 markup。验证过的样本：
///
///   - Codex overlay: `<meta charset='utf-8'><div data-selected-text-overlay-target=...`
///   - Chrome Google AI Overview: `<meta charset='utf-8'><span data-subtree=...`
///   - Claude Desktop: `<meta charset='utf-8'><p class="font-claude-response-body...`
///   - DingTalk 文档: `<head><meta charset="UTF-8"></head><table id="zongheng-ccp-host" data-ctx=...`
///
/// 原生富文本 app（Pages / Keynote / Mail / Notes）写 HTML 不带这个前缀。
///
/// 命中 → PasteboardWatcher 视作 web view selection，降级到 `.string` plain text 入库。
/// 行为对齐 Paste.app：列表干净 + FTS 命中关键词 + 粘回到任意目标都是 plain。
public func looksLikeWebViewHTML(_ html: String) -> Bool {
    // trim 前导空白后判前缀，case-insensitive，允许单引号或双引号
    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.hasPrefix("<meta charset='utf-8'>")
        || lower.hasPrefix("<meta charset=\"utf-8\">")
    {
        return true
    }
    // <head><meta charset='utf-8'></head> 包裹变体（DingTalk 等 Electron 文档编辑器）。
    // 限定 head 段内出现 utf-8 charset meta，且 head 块在合理位置（≤ 256 个 UTF-8 字节）
    // 关闭，避免误伤把 head 当结构性元素塞了一堆 meta/link 的完整 HTML 文档。
    // 用 utf8.count 而不是字符距离——前者跟字节预算对齐，head 里塞 CJK 时不会被低估。
    if lower.hasPrefix("<head>"),
       let headEnd = lower.range(of: "</head>"),
       lower[lower.startIndex..<headEnd.lowerBound].utf8.count <= 256
    {
        let headStart = lower.index(lower.startIndex, offsetBy: "<head>".count)
        let headBody = lower[headStart..<headEnd.lowerBound]
        if headBody.contains("<meta charset='utf-8'>")
            || headBody.contains("<meta charset=\"utf-8\">")
        {
            return true
        }
    }
    return false
}

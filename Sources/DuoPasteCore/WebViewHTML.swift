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

/// 判别一段 HTML payload 是否"只是 plain text 的样式封装"——即 strip 标签 + 反转义
/// entity 后逐行等价于 pasteboard 的 `.string`，不携带 plain 没有的语义（链接 href /
/// 图片 / 表格结构）。命中 → PasteboardWatcher 降级到 plain 入库。
///
/// `looksLikeWebViewHTML` 的前缀白名单是按"已知 app 长什么样"匹配，覆盖不到终端这类
/// 不写 `<meta charset>` 前缀的来源（ghostty / kitty 把选区导成
/// `<div style="font-family: monospace; white-space: pre;">…</div>`，内容里
/// `< > & " '` 全部转义成 `&lt; &gt; &amp; &quot; &#39;`）。本函数换一个维度：不看
/// html 长什么样，看它 strip 后还剩不剩 plain 没有的信息。
///
/// 关键反例 · 在 vim/less 里复制 **HTML 源码文本** `<div>foo</div>`：plain 就是该源码，
/// 终端写的 html 是 `<div style="…">&lt;div&gt;foo&lt;/div&gt;</div>`，strip 外层标签 +
/// 反转义 → `<div>foo</div>` == plain → 判等价 → 降级，源码完整保留在 plain（零丢失）。
/// 反之富文本（带 href / 结构）strip 后 ≠ plain → 返回 false，保留 html。
///
/// `maxBytes` 守门：strip + 反转义跑在 @MainActor 200ms 轮询路径上，超限直接返回 false
/// 让调用方保留 html，不让大 payload 拖垮轮询（对齐 RTF 路径的 maxRawRTFBytes）。
///
/// fail-safe 方向：strip + 反转义后只要跟 plain 不逐行等价就返回 false 保留 html——宁可
/// 漏判（该降的没降）也绝不误降级丢语义。已知会落到"保留 html"分支的形态：`<br>` 换行
/// （`stripHTMLTags` 把 `<br>` 整个删掉、行间不补 `\n`，跟 plain 的真实 `\n` 不等）、
/// `<style>` / HTML 注释（strip 后多出 CSS / 注释体）、含 href / 图片 / 表格等额外结构的
/// 真富文本。ghostty / kitty 实测用真实 `\n` 不走 `<br>`，故不受影响。
public func htmlIsPlainTextWrapper(_ html: String, plain: String, maxBytes: Int) -> Bool {
    guard html.utf8.count <= maxBytes else { return false }
    let stripped = decodeBasicHTMLEntities(stripHTMLTags(html))
    return normalizeForPlainCompare(stripped) == normalizeForPlainCompare(plain)
}

/// 去掉所有 `<…>` 标签。终端导出的 html 内容字符已 entity 转义（裸 `<` 不出现），
/// 故贪婪去标签安全；残留 entity 交给 `decodeBasicHTMLEntities`。
///
/// 限制：greedy `<[^>]*>` 对**属性值含裸 `>`** 的标签（如 `<a data-x="a>b">`，浏览器/
/// Electron 合法 html 可能出现）会切到第一个 `>` 留下属性尾部 junk。但这只让 strip 结果跟
/// plain 不等价 → 走保留 html 分支，是 fail-safe 方向，不丢数据（回归测试
/// `attributeWithAngleBracketKeepsHTML`）。
///
/// 这里用 `.regularExpression` 不跟 `normalizeForPlainCompare` 的"不走正则"自相矛盾：本函数
/// 是**整段单次** regex 调用（编译一次），跟 normalize 那种每行可能重跑的代价模型不同，叠加
/// 512KB 字节守门兜底，单次编译开销可接受。
func stripHTMLTags(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
}

/// 一次遍历反转义常见 HTML entity（具名 lt/gt/amp/quot/apos/nbsp + 十进制 `&#NN;` +
/// 十六进制 `&#xNN;`）。整体扫描而非逐 entity replace，`&amp;` 不会被二次解码。
/// 每个 `&` 只向后看 ≤10 字符找 `;`，保证 O(n)，不退化成 O(n²)。
func decodeBasicHTMLEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var out = ""
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "&" {
            var j = s.index(after: i)
            var steps = 0
            var semi: String.Index? = nil
            while j < s.endIndex, steps < 10 {
                if s[j] == ";" { semi = j; break }
                j = s.index(after: j)
                steps += 1
            }
            if let semi, let decoded = decodeEntityBody(s[s.index(after: i)..<semi]) {
                out.append(decoded)
                i = s.index(after: semi)
                continue
            }
        }
        out.append(c)
        i = s.index(after: i)
    }
    return out
}

/// 解析 `&` 与 `;` 之间的 entity body（不含两端符号）。无法识别返回 nil（保留原样）。
private func decodeEntityBody(_ body: Substring) -> Character? {
    switch body {
    case "lt": return "<"
    case "gt": return ">"
    case "amp": return "&"
    case "quot": return "\""
    case "apos": return "'"
    case "nbsp": return "\u{00A0}"
    default: break
    }
    guard body.hasPrefix("#") else { return nil }
    let num = body.dropFirst()
    if num.first == "x" || num.first == "X" {
        guard let code = UInt32(num.dropFirst(), radix: 16),
              let scalar = Unicode.Scalar(code) else { return nil }
        return Character(scalar)
    }
    guard let code = UInt32(num), let scalar = Unicode.Scalar(code) else { return nil }
    return Character(scalar)
}

/// 等价比较的归一化：nbsp 归普通空格 + 去每行尾随空白 + 整体 trim。终端 GPU 渲染常把
/// 网格行右 padding 到终端宽度，行尾空白不携带语义，归一掉避免假"不等价"。
///
/// 去尾用手工反向扫描而非 `[ \t]+$` 正则——Foundation 正则无 pattern cache，每次调用重新
/// 编译（单次 ~100μs），而本函数一次判别要在 stripped + plain 上各跑一遍、每行一次。512KB
/// worst-case（用户 `less` 大日志）可达 6.5k 行 × 2 路，正则编译开销会让 @MainActor 200ms
/// tick 出现秒级纯 CPU 阻塞。手工去尾是 O(n) 无编译开销（对齐 RTF 路径不在 main actor 裸跑
/// 重活的原则）。
///
/// 已知不归一 `\r`：只按 `\n` 分行、只去尾部 space/tab，CRLF 来源的行末残留 `\r` 会跟 LF
/// 形态的 plain 不等价 → 保留 html。macOS terminal 实测全 LF 不触发，且方向 fail-safe，
/// 跟 `<br>` / `<style>` 等 known-non-downgrade 形态并列。
func normalizeForPlainCompare(_ s: String) -> String {
    var lines: [String] = []
    for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
        var t = line.replacingOccurrences(of: "\u{00A0}", with: " ")
        while let last = t.last, last == " " || last == "\t" { t.removeLast() }
        lines.append(t)
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

import Testing
import Foundation
@testable import DuoPasteCore

@Test func detectsCodexOverlayPayload() {
    let html = "<meta charset='utf-8'><div data-selected-text-overlay-target=\"_r_1gh_\">x</div>"
    #expect(looksLikeWebViewHTML(html))
}

@Test func detectsChromeWebCopy() {
    let html = "<meta charset='utf-8'><span data-subtree=\"aimfl,mfl\">跨平台技术</span>"
    #expect(looksLikeWebViewHTML(html))
}

@Test func detectsClaudeDesktopPayload() {
    let html = "<meta charset='utf-8'><p class=\"font-claude-response-body\">都不要</p>"
    #expect(looksLikeWebViewHTML(html))
}

@Test func detectsDoubleQuoteVariant() {
    let html = "<meta charset=\"utf-8\"><div>hello</div>"
    #expect(looksLikeWebViewHTML(html))
}

@Test func detectsCaseInsensitive() {
    let html = "<META CHARSET='UTF-8'><div>hello</div>"
    #expect(looksLikeWebViewHTML(html))
}

@Test func ignoresNativeRichHTML() {
    // Pages / Keynote 写 HTML 不带 charset meta，通常裸 fragment 或完整 <html>
    #expect(!looksLikeWebViewHTML("<p style=\"color: red;\">hello</p>"))
    #expect(!looksLikeWebViewHTML("<html><body><p>hello</p></body></html>"))
    #expect(!looksLikeWebViewHTML("<!DOCTYPE html><html><body>x</body></html>"))
}

@Test func ignoresPlainText() {
    #expect(!looksLikeWebViewHTML("just plain text"))
    #expect(!looksLikeWebViewHTML(""))
}

@Test func ignoresOtherMetaCharset() {
    // 不是 utf-8 的 charset meta（极少见但 fingerprint 应当严格）
    #expect(!looksLikeWebViewHTML("<meta charset='iso-8859-1'><div>x</div>"))
}

@Test func handlesLeadingWhitespace() {
    let html = "  \n  <meta charset='utf-8'><div>x</div>"
    #expect(looksLikeWebViewHTML(html))
}

@Test func detectsDingTalkHeadWrappedMeta() {
    // DingTalk 文档复制实际样本：<head> 包住 meta charset，后面接 table markup
    let html = """
    <head><meta charset="UTF-8"></head><table id="zongheng-ccp-host" \
    data-ctx="{&quot;cid&quot;:&quot;3b70c775&quot;}" cellspacing="0">\
    <tbody><tr><td>ip地址</td></tr></tbody></table>
    """
    #expect(looksLikeWebViewHTML(html))
}

@Test func detectsHeadWrappedMetaSingleQuote() {
    let html = "<head><meta charset='utf-8'></head><div>x</div>"
    #expect(looksLikeWebViewHTML(html))
}

@Test func detectsHeadWrappedMetaWithLeadingWhitespace() {
    let html = "  \n<head><meta charset=\"UTF-8\"></head><table><tr><td>x</td></tr></table>"
    #expect(looksLikeWebViewHTML(html))
}

@Test func ignoresFullHTMLDocumentWithUTF8Meta() {
    // 完整 HTML 文档（含 <html><head>...）不算 web view selection——
    // 比如本地 .html 文件被读出来塞剪贴板时这种结构很常见，markup 本身就是用户要的内容。
    let html = "<html><head><meta charset=\"utf-8\"></head><body><p>x</p></body></html>"
    #expect(!looksLikeWebViewHTML(html))
}

@Test func ignoresHeadWithoutUTF8Meta() {
    #expect(!looksLikeWebViewHTML("<head><title>x</title></head><div>y</div>"))
    #expect(!looksLikeWebViewHTML("<head><meta charset='gbk'></head><div>y</div>"))
}

@Test func acceptsHeadSegmentAtByteLimit() {
    // head 段恰好 256 字节边界正面：<head>(6) + <meta charset="utf-8">(22) + 228 个 a = 256
    let html = "<head><meta charset=\"utf-8\">\(String(repeating: "a", count: 228))</head><div>x</div>"
    let headRange = html.range(of: "</head>")!
    #expect(html[html.startIndex..<headRange.lowerBound].utf8.count == 256)
    #expect(looksLikeWebViewHTML(html))
}

@Test func ignoresHeadSegmentJustBeyondByteLimit() {
    // head 段 257 字节：刚跨过阈值就应当拒绝——锁住精确边界，
    // 阈值若被悄悄改大（哪怕只到 257）就让这条变红。
    let html = "<head><meta charset=\"utf-8\">\(String(repeating: "a", count: 229))</head><div>x</div>"
    let headRange = html.range(of: "</head>")!
    #expect(html[html.startIndex..<headRange.lowerBound].utf8.count == 257)
    #expect(!looksLikeWebViewHTML(html))
}

@Test func ignoresCJKHeadBeyondByteBudgetWhileWithinCharBudget() {
    // 76 个"中"(228 字节) + 1 个 ASCII = 229 字节 head 内容，head 段总 257 字节超阈值。
    // 字符数 6+22+76+1 = 105 远低于 256——这条会在阈值被改回 String.distance（字符数）
    // 时假命中，专门锁住 utf8.count 语义。
    let html = "<head><meta charset=\"utf-8\">\(String(repeating: "中", count: 76))a</head><div>x</div>"
    let headRange = html.range(of: "</head>")!
    #expect(html[html.startIndex..<headRange.lowerBound].utf8.count == 257)
    #expect(html[html.startIndex..<headRange.lowerBound].count == 105)
    #expect(!looksLikeWebViewHTML(html))
}

// MARK: - htmlIsPlainTextWrapper（终端 GPU 渲染 selection 降级）

private let bigCap = 512 * 1024

@Test func ghosttySingleDivWrapsPlainText() {
    // ghostty 复制终端文本：单 div + monospace + 内容里 ' " 已转义。
    let plain = "bobby@localhost % pgrep -fl \"pmset -g pslog\"\n65891 pmset -g pslog"
    let html = "<div style=\"font-family: monospace; white-space: pre;\">bobby@localhost % pgrep -fl &quot;pmset -g pslog&quot;\n65891 pmset -g pslog</div>"
    #expect(htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func vimCopyingHTMLSourceDowngradesWithoutLoss() {
    // 关键反例：在 vim/less 里复制 HTML 源码。plain 就是源码本身；终端把尖括号转义后
    // 再包 div。strip 外层 + 反转义 == plain → 判等价 → 降级，源码完整保留在 plain。
    let plain = "<div class=\"x\">foo & bar</div>"
    let html = "<div style=\"font-family: monospace; white-space: pre;\">&lt;div class=&quot;x&quot;&gt;foo &amp; bar&lt;/div&gt;</div>"
    #expect(htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func decimalAndHexEntitiesDecode() {
    // ghostty 用 &#39; 表示单引号；额外覆盖十六进制 &#x27;。
    let plain = "it's a 'test'"
    let html = "<div style=\"x\">it&#39;s a &#x27;test&#x27;</div>"
    #expect(htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func trailingPaddingPerLineIsNormalized() {
    // 终端把网格行右 padding 到终端宽度，行尾空白不携带语义 → 归一后仍等价。
    let plain = "line one\nline two"
    let html = "<div style=\"white-space: pre;\">line one      \nline two   </div>"
    #expect(htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func htmlCarryingHrefIsNotAWrapper() {
    // 真富文本：html 的 <a href> 携带 plain 没有的 url。strip 后文本 = "click here"
    // 跟 plain 一致，但这里 plain 额外含裸 url（部分 app 把链接 url 也塞进 .string）→
    // strip 后 ≠ plain → 返回 false，保留 html 不丢链接语义。
    let plain = "click here (https://example.com/page)"
    let html = "<div><a href=\"https://example.com/page\">click here</a></div>"
    #expect(!htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func richTextWithExtraStructureIsNotAWrapper() {
    // Notes/Pages 等原生富文本：html 含列表结构文本，strip 后比 plain 多内容 → 保留。
    let plain = "shopping"
    let html = "<div><h1>shopping</h1><ul><li>milk</li><li>eggs</li></ul></div>"
    #expect(!htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func oversizedHTMLBypassesWrapperCheck() {
    // 超 maxBytes 守门：哪怕等价也直接返回 false，让调用方保留 html 不在轮询路径上
    // 做大 payload 的 strip + 反转义（对齐 RTF maxRawRTFBytes）。
    let body = String(repeating: "a", count: 2000)
    let html = "<div>\(body)</div>"
    #expect(!htmlIsPlainTextWrapper(html, plain: body, maxBytes: 1024))
    // 同一份内容放宽上限即等价——证明拒绝纯粹来自字节守门而非内容不匹配。
    #expect(htmlIsPlainTextWrapper(html, plain: body, maxBytes: bigCap))
}

@Test func ampEntityNotDoubleDecoded() {
    // &amp;lt; 的本意是字面 "&lt;"（用户真在打 entity 文本）；整体扫描不二次解码。
    let plain = "&lt;"
    let html = "<div>&amp;lt;</div>"
    #expect(htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func nestedTagsWithEntitiesStripAndDecode() {
    // 嵌套标签 + entity 混合：stripHTMLTags 去掉所有层级标签，decode 还原 entity。
    let plain = "<a href=\"x\">"
    let html = "<div><span>&lt;a href=&quot;x&quot;&gt;</span></div>"
    #expect(htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func emptyHTMLWithNonEmptyPlainIsNotAWrapper() {
    // 空 html strip 后为空，跟非空 plain 不等 → 不降级（fail-safe，守住边界不误降级）。
    #expect(!htmlIsPlainTextWrapper("", plain: "hi", maxBytes: 100))
}

@Test func outOfRangeNumericEntityKeptVerbatim() {
    // &#x110000; 超 Unicode 上限（max 0x10FFFF），decodeEntityBody 返 nil → entity 原样
    // 保留 → strip 后 "&#x110000;" 跟正常 plain 不等价 → 不降级（fail-safe）。
    let plain = "A"
    let html = "<div>&#x110000;</div>"
    #expect(!htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func brTagPreservedNotDowngraded() {
    // <br> 在 stripHTMLTags 里被整个删掉、不补 \n，strip 后两行粘连，跟 plain 真实换行
    // 不等价 → 不降级。锁住 docstring 契约：防后人加 "<br>→\n 优化" 把降级面变激进。
    let plain = "line one\nline two"
    let html = "<div>line one<br>line two</div>"
    #expect(!htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

@Test func styleTagBodyKeepsHTMLFromDowngrading() {
    // <style> 标签被 strip 掉但 CSS body 留下来，跟 plain 不等价 → 保留 html（fail-safe）。
    let plain = "hello"
    let html = "<style>body{color:red}</style><p>hello</p>"
    #expect(!htmlIsPlainTextWrapper(html, plain: plain, maxBytes: bigCap))
}

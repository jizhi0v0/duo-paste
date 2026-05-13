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

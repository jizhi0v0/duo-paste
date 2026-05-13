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

@Test func ignoresHeadSegmentBeyondByteLimit() {
    // head 段塞够多 meta 让 </head> 超过 256 字节预算时不命中——锁住阈值，
    // 防止 head 当结构性元素的完整 HTML 文档巧合含 charset=utf-8 被误判。
    let filler = String(repeating: "<meta name=\"x\" content=\"y\">", count: 20)
    let html = "<head><meta charset=\"utf-8\">\(filler)</head><div>x</div>"
    #expect(html.utf8.count > 256)
    #expect(!looksLikeWebViewHTML(html))
}

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

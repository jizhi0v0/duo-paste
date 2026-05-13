import Testing
import Foundation
@testable import DuoPasteCore

@Test func acceptsHttpURL() {
    #expect(looksLikeURL("http://example.com"))
    #expect(looksLikeURL("http://example.com/path?q=1"))
}

@Test func acceptsHttpsURL() {
    #expect(looksLikeURL("https://example.com"))
    #expect(looksLikeURL("https://github.com/owner/repo/pull/123"))
}

@Test func acceptsHttpsWithFragmentAndQuery() {
    #expect(looksLikeURL("https://www.hannahhearth.com/posts/tools?ref=x#section"))
}

@Test func trimsLeadingTrailingWhitespace() {
    #expect(looksLikeURL("  https://example.com  "))
    #expect(looksLikeURL("\thttps://example.com\n"))
}

@Test func rejectsBareHostWithoutScheme() {
    // 用户决策：严格 http(s):// 起头。"github.com/foo" 不识别为 URL
    #expect(!looksLikeURL("github.com"))
    #expect(!looksLikeURL("www.example.com"))
    #expect(!looksLikeURL("example.com/path"))
}

@Test func rejectsNonHttpSchemes() {
    // ftp/ssh/git/mailto/file/custom 都不算 URL（避免误判）
    #expect(!looksLikeURL("ftp://example.com/file.zip"))
    #expect(!looksLikeURL("ssh://git@github.com:owner/repo.git"))
    #expect(!looksLikeURL("mailto:foo@example.com"))
    #expect(!looksLikeURL("file:///Users/bobby/x.txt"))
    #expect(!looksLikeURL("vscode://open?file=/x"))
}

@Test func rejectsMultilineEvenIfStartsWithHttps() {
    // "https://example.com\n说明文字" 是"链接 + 描述文字"，不算单一 URL
    #expect(!looksLikeURL("https://example.com\n描述"))
    #expect(!looksLikeURL("https://a.com\r\nhttps://b.com"))
}

@Test func rejectsRawSpaceInURL() {
    // URL 里 space 必须 %20 编码。裸 space 通常是"URL + 后接文字"
    #expect(!looksLikeURL("https://example.com path"))
    #expect(!looksLikeURL("https://example.com /path"))
}

@Test func rejectsPlainText() {
    #expect(!looksLikeURL(""))
    #expect(!looksLikeURL("just plain text"))
    #expect(!looksLikeURL("12345"))
}

@Test func rejectsHttpsButNoHost() {
    // "https://" 后什么都没有，URL.host 解析出 nil
    #expect(!looksLikeURL("https://"))
    #expect(!looksLikeURL("http://"))
}

@Test func caseInsensitiveScheme() {
    // Browser 不太可能写出 HTTPS 大写，但 URL spec 允许，启发上接受
    #expect(looksLikeURL("HTTPS://example.com"))
    #expect(looksLikeURL("Http://example.com"))
}

@Test func rejectsEmptyHost() {
    // codex review round 1 P1 #1：'https:///path' GLOB 接受但 URL.host=nil
    // looksLikeURL 必须拒，否则 v6 backfill 会把此类畸形 text 永久重分类为 url
    #expect(!looksLikeURL("https:///path"))
    #expect(!looksLikeURL("http:///"))
}

@Test func rejectsTabInsideURL() {
    // 跟 SQL backfill 端 NOT LIKE '% %' 对齐：raw whitespace（含 \t）= "URL + 后接文字"
    #expect(!looksLikeURL("https://example.com\tnote"))
    #expect(!looksLikeURL("https://x.com\u{00A0}foo"))  // non-breaking space
}

@Test func rejectsMalformedHosts() {
    // codex review round 1 P2 #4：URL.host 非空校验太松，下列形态都得拒
    #expect(!looksLikeURL("http://_.com"))         // 下划线非合法 host 字符
    #expect(!looksLikeURL("http://.com"))          // 起首 '.'
    #expect(!looksLikeURL("http://example..com"))  // 连续 '..'
}

import Testing
import Foundation
@testable import DuoPasteCore

/// `QueryQualifier.matches` 的契约测试——iOS 内存 filter 路径专用,跟 Mac SQL `SearchAPI`
/// 路径同语义。回归测试守住:
/// - OR 语义(任一 qualifier 命中即过)
/// - `imageMerged` 同时匹配 image kind + imageFile subkind
/// - `textSuffix` 走 textFull 末尾 lowercased LIKE
/// - 空 qualifier list 等于不过滤
@Suite("QueryQualifier.matches")
struct QueryQualifierMatchesTests {
    private func textItem(_ id: String, _ kind: ItemKind, textFull: String? = nil) -> Item {
        Item(
            id: id,
            originDevice: "test-device",
            capturedAtNs: 1,
            kind: kind,
            textFull: textFull
        )
    }

    private func fileItem(_ id: String, mime: String? = nil, textFull: String? = nil) -> Item {
        Item(
            id: id,
            originDevice: "test-device",
            capturedAtNs: 1,
            kind: .file,
            textFull: textFull,
            blobMime: mime
        )
    }

    @Test("空 qualifier 集合 → 任何 item 都过")
    func emptyAlwaysMatches() {
        let it = textItem("1", .text, textFull: "hello")
        #expect(QueryQualifier.matches(it, qualifiers: []) == true)
    }

    @Test(".kind 直接比 item.kind")
    func kindMatch() {
        let url = textItem("u", .url, textFull: "https://example.com")
        #expect(QueryQualifier.matches(url, qualifiers: [.kind(.url)]) == true)
        #expect(QueryQualifier.matches(url, qualifiers: [.kind(.text)]) == false)
    }

    @Test(".fileSubKind 走 ItemClassifier")
    func subKindMatch() {
        let pdf = fileItem("p", mime: "application/pdf")
        #expect(QueryQualifier.matches(pdf, qualifiers: [.fileSubKind(.pdf)]) == true)
        #expect(QueryQualifier.matches(pdf, qualifiers: [.fileSubKind(.video)]) == false)

        // text item 不算 file subkind
        let plain = textItem("t", .text, textFull: "x")
        #expect(QueryQualifier.matches(plain, qualifiers: [.fileSubKind(.pdf)]) == false)
    }

    @Test("imageMerged: kind=.image OR subkind=imageFile 两路径都过")
    func imageMergedMatchesBothPaths() {
        let nativeImage = textItem("i", .image)
        #expect(QueryQualifier.matches(nativeImage, qualifiers: [.imageMerged]) == true)

        let pngFile = fileItem("png", mime: "image/png")
        #expect(QueryQualifier.matches(pngFile, qualifiers: [.imageMerged]) == true)

        // 非图: text / 视频 file / url 都不过
        let plain = textItem("t", .text, textFull: "x")
        #expect(QueryQualifier.matches(plain, qualifiers: [.imageMerged]) == false)
        let mp4 = fileItem("mp4", mime: "video/mp4")
        #expect(QueryQualifier.matches(mp4, qualifiers: [.imageMerged]) == false)
    }

    @Test("textSuffix 走 textFull 末尾 LIKE")
    func textSuffixMatch() {
        let code = textItem("c", .text, textFull: "package main\n\nfunc main() {}\n// hello.go")
        #expect(QueryQualifier.matches(code, qualifiers: [.textSuffix(".go")]) == true)

        // 大小写不敏感
        let upper = textItem("u", .text, textFull: "x.JAVA")
        #expect(QueryQualifier.matches(upper, qualifiers: [.textSuffix(".java")]) == true)

        let other = textItem("o", .text, textFull: "x.py")
        #expect(QueryQualifier.matches(other, qualifiers: [.textSuffix(".go")]) == false)

        // textFull nil 不崩,直接 false
        let noText = textItem("n", .image, textFull: nil)
        #expect(QueryQualifier.matches(noText, qualifiers: [.textSuffix(".go")]) == false)
    }

    @Test("OR 语义:任一命中即过")
    func orSemanticsAcrossQualifiers() {
        let url = textItem("u", .url, textFull: "https://example.com")
        // url 不是 image,但 .kind(.url) 仍命中
        #expect(QueryQualifier.matches(url, qualifiers: [.imageMerged, .kind(.url)]) == true)
    }

    @Test("混合 kind + subKind + suffix 多类型 qualifier")
    func mixedQualifierTypes() {
        let pdf = fileItem("p", mime: "application/pdf")
        let qs: [QueryQualifier] = [.kind(.text), .fileSubKind(.pdf), .textSuffix(".java")]
        #expect(QueryQualifier.matches(pdf, qualifiers: qs) == true)

        let plain = textItem("t", .text, textFull: "x")
        #expect(QueryQualifier.matches(plain, qualifiers: qs) == true) // kind=.text 命中

        let url = textItem("u", .url, textFull: "https://example.com")
        #expect(QueryQualifier.matches(url, qualifiers: qs) == false) // 三项都不中
    }

    @Test("同一 qualifier 重复出现不影响结果")
    func dedupBehavior() {
        let pdf = fileItem("p", mime: "application/pdf")
        #expect(QueryQualifier.matches(pdf, qualifiers: [.fileSubKind(.pdf), .fileSubKind(.pdf)]) == true)
    }
}

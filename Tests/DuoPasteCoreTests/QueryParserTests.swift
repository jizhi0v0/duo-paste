import Testing
import Foundation
@testable import DuoPasteCore

@Suite("QueryParser")
struct QueryParserTests {
    @Test("纯文本不解析出 qualifier")
    func plainText() {
        let p = QueryParser.parse("hello world")
        #expect(p.text == "hello world")
        #expect(p.qualifiers.isEmpty)
    }

    @Test("空字符串")
    func empty() {
        let p = QueryParser.parse("")
        #expect(p.text == "")
        #expect(p.qualifiers.isEmpty)

        let p2 = QueryParser.parse("   ")
        #expect(p2.text == "")
        #expect(p2.qualifiers.isEmpty)
    }

    @Test("单 qualifier + 文本")
    func singleQualifier() {
        let p = QueryParser.parse("/pdf hello")
        #expect(p.text == "hello")
        #expect(p.qualifiers == [.fileSubKind(.pdf)])
    }

    @Test("多 qualifier 保留输入顺序")
    func multipleQualifiers() {
        let p = QueryParser.parse("/pdf /image hello world")
        #expect(p.text == "hello world")
        #expect(p.qualifiers == [.fileSubKind(.pdf), .imageMerged])
    }

    @Test("qualifier 在 text 中间任意位置")
    func qualifierInMiddle() {
        let p = QueryParser.parse("hello /pdf world")
        #expect(p.text == "hello world")
        #expect(p.qualifiers == [.fileSubKind(.pdf)])
    }

    @Test("ext alias 映射 — mp4 → video")
    func extAliasVideo() {
        let p = QueryParser.parse("/mp4")
        #expect(p.qualifiers == [.fileSubKind(.video)])
    }

    @Test("ext alias 映射 — mp3 → audio")
    func extAliasAudio() {
        let p = QueryParser.parse("/mp3")
        #expect(p.qualifiers == [.fileSubKind(.audio)])
    }

    @Test("ext alias 映射 — png/jpg → imageMerged")
    func extAliasImage() {
        let p = QueryParser.parse("/png")
        #expect(p.qualifiers == [.imageMerged])

        let p2 = QueryParser.parse("/jpg")
        #expect(p2.qualifiers == [.imageMerged])
    }

    @Test("/image 跟 /img 都映射 imageMerged")
    func imageAliasFamily() {
        for raw in ["/image", "/img", "/jpeg", "/gif", "/webp", "/heic"] {
            let p = QueryParser.parse(raw)
            #expect(p.qualifiers == [.imageMerged], "\(raw) 应该映射 imageMerged")
        }
    }

    @Test("/imagefile 精准映射 .imageFile（不等价 /image）")
    func imageFilePrecise() {
        let p = QueryParser.parse("/imagefile")
        #expect(p.qualifiers == [.fileSubKind(.imageFile)])

        let p2 = QueryParser.parse("/image-file")
        #expect(p2.qualifiers == [.fileSubKind(.imageFile)])
    }

    @Test("代码扩展名 → textSuffix")
    func codeExtSuffix() {
        let p = QueryParser.parse("/java foo")
        #expect(p.text == "foo")
        #expect(p.qualifiers == [.textSuffix(".java")])

        for ext in ["c", "cpp", "py", "swift", "go", "rs", "ts", "js", "rb"] {
            let p2 = QueryParser.parse("/" + ext)
            #expect(p2.qualifiers == [.textSuffix("." + ext)], "/\(ext) 应该映射 textSuffix")
        }
    }

    @Test("unknown qualifier 保留进 text 不丢")
    func unknownQualifier() {
        let p = QueryParser.parse("/imgae hello")
        #expect(p.text == "/imgae hello")
        #expect(p.qualifiers.isEmpty)
    }

    @Test("大小写不敏感")
    func caseInsensitive() {
        let pUpper = QueryParser.parse("/PDF")
        let pLower = QueryParser.parse("/pdf")
        #expect(pUpper.qualifiers == pLower.qualifiers)

        let pMix = QueryParser.parse("/Mp4")
        #expect(pMix.qualifiers == [.fileSubKind(.video)])
    }

    @Test("重复 qualifier 去重")
    func deduplication() {
        let p = QueryParser.parse("/pdf /pdf hello")
        #expect(p.qualifiers == [.fileSubKind(.pdf)])
        #expect(p.text == "hello")
    }

    @Test("混合多类 qualifier")
    func mixedQualifiers() {
        let p = QueryParser.parse("/text /image /pdf /java foo bar")
        #expect(p.text == "foo bar")
        #expect(p.qualifiers.count == 4)
        #expect(p.qualifiers.contains(.kind(.text)))
        #expect(p.qualifiers.contains(.imageMerged))
        #expect(p.qualifiers.contains(.fileSubKind(.pdf)))
        #expect(p.qualifiers.contains(.textSuffix(".java")))
    }

    @Test("render → parse round-trip 稳定")
    func renderRoundTrip() {
        let original = ParsedQuery(text: "hello", qualifiers: [.fileSubKind(.pdf), .imageMerged])
        let rendered = QueryParser.render(text: original.text, qualifiers: original.qualifiers)
        let reparsed = QueryParser.parse(rendered)
        #expect(reparsed.text == original.text)
        #expect(Set(reparsed.qualifiers) == Set(original.qualifiers))
    }

    @Test("render 空 qualifier 只剩 text")
    func renderEmpty() {
        let rendered = QueryParser.render(text: "hello", qualifiers: [])
        #expect(rendered == "hello")
    }

    @Test("render 只 qualifier 无 text")
    func renderOnlyQualifiers() {
        let rendered = QueryParser.render(text: "", qualifiers: [.fileSubKind(.pdf)])
        #expect(rendered == "/pdf")
    }

    @Test("suggestions 空 prefix 返回空")
    func suggestionsEmpty() {
        let s = QueryParser.suggestions(prefix: "")
        #expect(s.isEmpty)

        let s2 = QueryParser.suggestions(prefix: "hello")
        #expect(s2.isEmpty)
    }

    @Test("suggestions /im 应该列出多个候选")
    func suggestionsPrefix() {
        let s = QueryParser.suggestions(prefix: "/im")
        // /image /img /imagefile /image-file 都以 im 开头，去重 qualifier 后
        // 至少有 imageMerged + .fileSubKind(.imageFile) 两种
        let qualifiers = s.map { $0.qualifier }
        #expect(qualifiers.contains(.imageMerged))
        #expect(qualifiers.contains(.fileSubKind(.imageFile)))
    }

    @Test("suggestions /pd 单候选")
    func suggestionsSingle() {
        let s = QueryParser.suggestions(prefix: "/pd")
        let qualifiers = s.map { $0.qualifier }
        #expect(qualifiers == [.fileSubKind(.pdf)])
    }

    @Test("/ 单字符返回所有候选")
    func suggestionsAll() {
        let s = QueryParser.suggestions(prefix: "/")
        #expect(s.count > 5, "/ 应列出全部 qualifier")
    }

    // MARK: - extractCompleted

    @Test("extractCompleted: 末尾空格触发抽取")
    func extractTrailingSpace() {
        let (quals, remaining) = QueryParser.extractCompleted("/pdf ")
        #expect(quals == [.fileSubKind(.pdf)])
        #expect(remaining.trimmingCharacters(in: .whitespaces) == "")
    }

    @Test("extractCompleted: 末尾未闭合不抽")
    func extractTrailingUnclosed() {
        let (quals, remaining) = QueryParser.extractCompleted("/pdf")
        #expect(quals.isEmpty)
        #expect(remaining == "/pdf")
    }

    @Test("extractCompleted: 中间 /xxx 抽取,搜索文本保留")
    func extractMiddle() {
        let (quals, remaining) = QueryParser.extractCompleted("/pdf hello")
        #expect(quals == [.fileSubKind(.pdf)])
        #expect(remaining == "hello")
    }

    @Test("extractCompleted: 多个已闭合 + 末尾未闭合")
    func extractMixedClosedUnclosed() {
        let (quals, remaining) = QueryParser.extractCompleted("/pdf /image /im")
        #expect(quals == [.fileSubKind(.pdf), .imageMerged])
        #expect(remaining == "/im")
    }

    @Test("extractCompleted: unknown qualifier 不抽")
    func extractUnknown() {
        let (quals, remaining) = QueryParser.extractCompleted("/imgae hello")
        #expect(quals.isEmpty)
        #expect(remaining == "/imgae hello")
    }

    @Test("extractCompleted: 纯文本不抽")
    func extractPlainText() {
        let (quals, remaining) = QueryParser.extractCompleted("hello world")
        #expect(quals.isEmpty)
        #expect(remaining == "hello world")
    }

    @Test("extractCompleted: 大小写 / 别名归一")
    func extractAliasCase() {
        let (quals, remaining) = QueryParser.extractCompleted("/MP4 demo")
        #expect(quals == [.fileSubKind(.video)])
        #expect(remaining == "demo")
    }

    @Test("extractCompleted: 重复 qualifier 去重")
    func extractDedup() {
        let (quals, _) = QueryParser.extractCompleted("/pdf /pdf hello")
        #expect(quals == [.fileSubKind(.pdf)])
    }
}

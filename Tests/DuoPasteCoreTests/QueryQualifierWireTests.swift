import Testing
import Foundation
@testable import DuoPasteCore

/// `QueryQualifier.encodeToWire` 契约——server `/search` 透传 qualifier 的 client/server
/// 共享编码器(issue #41 消除 client-side filter pagination 盲区)。
///
/// iOS PeerClient + server `parseSearchQuery` 共享同一份 wire 编码,任何分叉=bug。
@Suite("QueryQualifier wire encoding")
struct QueryQualifierWireTests {
    @Test("空 list → 全 nil")
    func emptyList() {
        let wire = QueryQualifier.encodeToWire([])
        #expect(wire.kinds == nil)
        #expect(wire.fileSubKinds == nil)
        #expect(wire.textSuffixes == nil)
    }

    @Test("单 kind 走 kinds CSV")
    func singleKind() {
        let wire = QueryQualifier.encodeToWire([.kind(.text)])
        #expect(wire.kinds == "text")
        #expect(wire.fileSubKinds == nil)
        #expect(wire.textSuffixes == nil)
    }

    @Test("多 kind 按 allCases 顺序稳定")
    func kindOrderStable() {
        // 输入故意乱序,输出必须按 ItemKind.allCases 顺序(text/rtf/html/url/image/file)
        let wire = QueryQualifier.encodeToWire([.kind(.url), .kind(.text), .kind(.html)])
        #expect(wire.kinds == "text,html,url")
    }

    @Test("imageMerged 展开成 image kind + imageFile sub-kind")
    func imageMergedExpands() {
        let wire = QueryQualifier.encodeToWire([.imageMerged])
        #expect(wire.kinds == "image")
        #expect(wire.fileSubKinds == "imageFile")
        #expect(wire.textSuffixes == nil)
    }

    @Test("imageMerged 跟 kind(.image) 共存只输出一次")
    func imageMergedDedup() {
        let wire = QueryQualifier.encodeToWire([.imageMerged, .kind(.image)])
        #expect(wire.kinds == "image")
        #expect(wire.fileSubKinds == "imageFile")
    }

    @Test("file sub-kind CSV")
    func fileSubKindCSV() {
        let wire = QueryQualifier.encodeToWire([
            .fileSubKind(.pdf),
            .fileSubKind(.video),
        ])
        #expect(wire.kinds == nil)
        // FileSubKind.allCases 顺序:video / pdf / audio / imageFile
        #expect(wire.fileSubKinds == "video,pdf")
    }

    @Test("textSuffix 按输入顺序 + 去重 + 小写")
    func textSuffixOrder() {
        let wire = QueryQualifier.encodeToWire([
            .textSuffix(".Java"),
            .textSuffix(".py"),
            .textSuffix(".java"),  // dup of first (case-insensitive)
        ])
        #expect(wire.kinds == nil)
        #expect(wire.textSuffixes == ".java,.py")
    }

    @Test("混合 kind + sub-kind + suffix 都填")
    func mixed() {
        let wire = QueryQualifier.encodeToWire([
            .kind(.url),
            .fileSubKind(.pdf),
            .textSuffix(".swift"),
        ])
        #expect(wire.kinds == "url")
        #expect(wire.fileSubKinds == "pdf")
        #expect(wire.textSuffixes == ".swift")
    }

    @Test("空 textSuffix 不输出")
    func emptyTextSuffixSkipped() {
        let wire = QueryQualifier.encodeToWire([.textSuffix("")])
        #expect(wire.textSuffixes == nil)
    }
}

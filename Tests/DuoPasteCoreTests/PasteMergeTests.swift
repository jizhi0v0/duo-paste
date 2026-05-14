import Testing
import Foundation
@testable import DuoPasteCore

/// PasteMerge 是 SearchPanel 多选 paste 的合并策略 + 纯函数 helper。
/// 测两块:strategy 决策(用 kind 集合决定走哪条路径) + joinTextual/flattenFilePaths(顺序/边界)

private func makeItem(
    id: String,
    kind: ItemKind,
    textFull: String? = nil,
    preview: String? = nil,
    blobSha256: String? = nil,
    blobMime: String? = nil
) -> Item {
    Item(
        id: id,
        originDevice: "test",
        capturedAtNs: 0,
        kind: kind,
        preview: preview,
        textFull: textFull,
        blobSha256: blobSha256,
        blobMime: blobMime
    )
}

// MARK: - strategy

@Test func strategyEmptyArrayReturnsSingleItem() {
    #expect(PasteMerge.strategy(for: []) == .singleItem)
}

@Test func strategySingleItemReturnsSingleItem() {
    let it = makeItem(id: "a", kind: .text, textFull: "hello")
    #expect(PasteMerge.strategy(for: [it]) == .singleItem)
}

@Test func strategyMultipleTextReturnsMergedText() {
    let items = [
        makeItem(id: "1", kind: .text, textFull: "a"),
        makeItem(id: "2", kind: .text, textFull: "b"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedText)
}

@Test func strategyMultipleFileReturnsMergedFile() {
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/tmp/a"),
        makeItem(id: "2", kind: .file, textFull: "/tmp/b"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedFile)
}

@Test func strategyMultipleImageReturnsMergedImages() {
    // **设计变更**(2026-05-14 二修):原本多图 fallback 取首项,user 觉得太弱。改成
    // mergedImages 让多图也能落 temp 文件 + writeObjects 多 URL paste
    let items = [
        makeItem(id: "1", kind: .image),
        makeItem(id: "2", kind: .image),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedImages)
}

@Test func strategyCrossKindReturnsMergedText() {
    // 跨 kind(text + image)→ mergedText,image 在 joinTextual 用 preview 兜底。
    // **设计变更**:原版返回 fallbackToFirst,user 反馈"选了 4 文本+1 图,只粘 1 条"觉得是 bug
    let items = [
        makeItem(id: "1", kind: .text, textFull: "hi"),
        makeItem(id: "2", kind: .image, preview: "[image 4.5 MB]"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedText)
}

@Test func strategyCrossKindFilePlusText() {
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/tmp/a"),
        makeItem(id: "2", kind: .text, textFull: "b"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedText)
}

@Test func strategyFileImageMimePlusImageReturnsMergedImages() {
    // 2026-05-14 三修:微信/WeType 场景同一张图以 file URL+image bytes 同时入库,
    // 前几次 watcher 抓到 file URL 走 .file kind(blob_mime=image/png),后几次裸 image bytes 走 .image。
    // 用户多选这种"实际都是图"的混合时应走 mergedImages 让 4 张都粘成图,不是 mergedText 输出
    // 路径+占位
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/Users/bobby/foo.png",
                 blobSha256: "sha1", blobMime: "image/png"),
        makeItem(id: "2", kind: .file, textFull: "/Users/bobby/bar.heic",
                 blobSha256: "sha2", blobMime: "image/heic"),
        makeItem(id: "3", kind: .image, preview: "[image 130 KB]",
                 blobSha256: "sha3", blobMime: "image/png"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedImages)
}

@Test func strategyAllFileImageMimeReturnsMergedImages() {
    // 全 file 但 blob 都是 image MIME → 也算 image-like,走 mergedImages。
    // 代价:接收端拿到 temp 路径(sha 前 16 位.ext)而非原文件名;多图 paste 场景接受这权衡
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/Users/bobby/a.png",
                 blobSha256: "sha1", blobMime: "image/png"),
        makeItem(id: "2", kind: .file, textFull: "/Users/bobby/b.heic",
                 blobSha256: "sha2", blobMime: "image/heic"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedImages)
}

@Test func strategyFileNonImageMimePlusFileImageMimeStaysMergedFile() {
    // 1 个 file=image MIME + 1 个 file=PDF/zip 非 image MIME → 不全 image-like → mergedFile(原路径)。
    // 避免把 PDF 也错落 temp 当图粘
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/Users/bobby/a.png",
                 blobSha256: "sha1", blobMime: "image/png"),
        makeItem(id: "2", kind: .file, textFull: "/Users/bobby/b.pdf",
                 blobSha256: "sha2", blobMime: "application/pdf"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedFile)
}

@Test func strategyFileImageMimePlusTextStaysMergedText() {
    // file image-mime + text → 不全 image-like → mergedText
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/Users/bobby/a.png",
                 blobSha256: "sha1", blobMime: "image/png"),
        makeItem(id: "2", kind: .text, textFull: "hello"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedText)
}

@Test func isImageLikeIdentifiesFileWithImageMime() {
    #expect(PasteMerge.isImageLike(makeItem(id: "1", kind: .image)))
    #expect(PasteMerge.isImageLike(makeItem(id: "2", kind: .file, blobMime: "image/png")))
    #expect(PasteMerge.isImageLike(makeItem(id: "3", kind: .file, blobMime: "image/heic")))
    #expect(!PasteMerge.isImageLike(makeItem(id: "4", kind: .file, blobMime: "application/pdf")))
    #expect(!PasteMerge.isImageLike(makeItem(id: "5", kind: .file, blobMime: nil)))
    #expect(!PasteMerge.isImageLike(makeItem(id: "6", kind: .text)))
}

@Test func strategyMixedTextSubkindsAreMergedText() {
    // text/url/rtf/html 混合也走 mergedText(用 preview 兜底处理 textFull 为 nil 的项)
    let items = [
        makeItem(id: "1", kind: .text, textFull: "a"),
        makeItem(id: "2", kind: .url, textFull: "https://x"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedText)
}

@Test func strategyAllUrlReturnsMergedText() {
    let items = [
        makeItem(id: "1", kind: .url, textFull: "https://a"),
        makeItem(id: "2", kind: .url, textFull: "https://b"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedText)
}

@Test func strategyAllRTFReturnsMergedText() {
    let items = [
        makeItem(id: "1", kind: .rtf, textFull: "{\\rtf1 a}"),
        makeItem(id: "2", kind: .rtf, textFull: "{\\rtf1 b}"),
    ]
    #expect(PasteMerge.strategy(for: items) == .mergedText)
}

// MARK: - joinTextual

@Test func joinTextualPreservesOrder() {
    let items = [
        makeItem(id: "1", kind: .text, textFull: "first"),
        makeItem(id: "2", kind: .text, textFull: "second"),
        makeItem(id: "3", kind: .text, textFull: "third"),
    ]
    #expect(PasteMerge.joinTextual(items) == "first\nsecond\nthird")
}

@Test func joinTextualSkipsNilTextFull() {
    let items = [
        makeItem(id: "1", kind: .text, textFull: "a"),
        makeItem(id: "2", kind: .text, textFull: nil),
        makeItem(id: "3", kind: .text, textFull: "c"),
    ]
    #expect(PasteMerge.joinTextual(items) == "a\nc")
}

@Test func joinTextualReturnsNilWhenAllNil() {
    let items = [
        makeItem(id: "1", kind: .text, textFull: nil),
        makeItem(id: "2", kind: .text, textFull: nil),
    ]
    #expect(PasteMerge.joinTextual(items) == nil)
}

@Test func joinTextualReturnsNilForEmptyInput() {
    #expect(PasteMerge.joinTextual([]) == nil)
}

@Test func joinTextualFallsBackToPreviewWhenTextFullNil() {
    // image kind OCR 未跑时 textFull = nil,preview 是人类可读占位。
    // 跨 kind paste 时 image 必须能用 preview 进入拼接结果
    let items = [
        makeItem(id: "1", kind: .text, textFull: "hi"),
        makeItem(id: "2", kind: .image, textFull: nil, preview: "[image 4.5 MB]"),
        makeItem(id: "3", kind: .text, textFull: "bye"),
    ]
    #expect(PasteMerge.joinTextual(items) == "hi\n[image 4.5 MB]\nbye")
}

@Test func joinTextualImageKindUsesPreviewEvenWhenOCRFilledTextFull() {
    // 回归 2026-05-14 bug:用户多选 3 个 file kind + 1 个 image kind 一次 Enter
    // 合并 paste,image 的 textFull 经 OCR worker 写入是 OCR 文本
    // ("R\n臻选美式 巴厘岛..."),被错当 plain text 拼到结果里。
    // 修复:image kind 始终走 preview 占位,不读 textFull。
    // 期望:image 项的 OCR 文本不应出现在拼接输出
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/Users/bobby/Library/Caches/WeType/dsclp/mac_1.png"),
        makeItem(id: "2", kind: .file, textFull: "/Users/bobby/Library/Caches/WeType/dsclp/ios_1.heic"),
        makeItem(
            id: "3",
            kind: .image,
            textFull: "R\n臻选美式 巴厘岛 巴图尔火山\n中杯（355ml）",
            preview: "[image 130 KB]"
        ),
    ]
    let joined = PasteMerge.joinTextual(items)
    #expect(joined == "/Users/bobby/Library/Caches/WeType/dsclp/mac_1.png\n/Users/bobby/Library/Caches/WeType/dsclp/ios_1.heic\n[image 130 KB]")
    // 显式断言:OCR 文本不应泄漏到合并结果
    #expect(joined?.contains("臻选美式") == false)
    #expect(joined?.contains("R\n") == false)
}

@Test func joinTextualPrefersTextFullOverPreview() {
    // textFull 非 nil 时不应该退到 preview
    let items = [
        makeItem(id: "1", kind: .text, textFull: "full content", preview: "short"),
    ]
    #expect(PasteMerge.joinTextual(items) == "full content")
}

@Test func joinTextualCustomSeparator() {
    let items = [
        makeItem(id: "1", kind: .text, textFull: "a"),
        makeItem(id: "2", kind: .text, textFull: "b"),
    ]
    #expect(PasteMerge.joinTextual(items, separator: " | ") == "a | b")
}

// MARK: - flattenFilePaths

@Test func flattenFilePathsBasic() {
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/tmp/a"),
        makeItem(id: "2", kind: .file, textFull: "/tmp/b"),
    ]
    #expect(PasteMerge.flattenFilePaths(items) == ["/tmp/a", "/tmp/b"])
}

@Test func flattenFilePathsExpandsMultilineTextFull() {
    // 单个 file item 的 textFull 本身可以含多路径(\n 分隔)——Finder 一次复制多文件就这样
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/tmp/a\n/tmp/b"),
        makeItem(id: "2", kind: .file, textFull: "/tmp/c"),
    ]
    #expect(PasteMerge.flattenFilePaths(items) == ["/tmp/a", "/tmp/b", "/tmp/c"])
}

@Test func flattenFilePathsTrimsWhitespace() {
    let items = [
        makeItem(id: "1", kind: .file, textFull: "  /tmp/a  \n\t/tmp/b\t"),
    ]
    #expect(PasteMerge.flattenFilePaths(items) == ["/tmp/a", "/tmp/b"])
}

@Test func flattenFilePathsSkipsEmptyLines() {
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/tmp/a\n\n/tmp/b\n   \n/tmp/c"),
    ]
    #expect(PasteMerge.flattenFilePaths(items) == ["/tmp/a", "/tmp/b", "/tmp/c"])
}

@Test func flattenFilePathsSkipsNilTextFull() {
    let items = [
        makeItem(id: "1", kind: .file, textFull: nil),
        makeItem(id: "2", kind: .file, textFull: "/tmp/b"),
    ]
    #expect(PasteMerge.flattenFilePaths(items) == ["/tmp/b"])
}

@Test func flattenFilePathsReturnsEmptyForEmptyInput() {
    #expect(PasteMerge.flattenFilePaths([]) == [])
}

import Testing
import Foundation
@testable import DuoPasteCore

/// PasteMerge 是 SearchPanel 多选 paste 的合并策略 + 纯函数 helper。
/// 测两块:strategy 决策(用 kind 集合决定走哪条路径) + joinTextual/flattenFilePaths(顺序/边界)

private func makeItem(
    id: String,
    kind: ItemKind,
    textFull: String? = nil,
    preview: String? = nil
) -> Item {
    Item(
        id: id,
        originDevice: "test",
        capturedAtNs: 0,
        kind: kind,
        preview: preview,
        textFull: textFull
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
    // image kind 通常 textFull = nil(OCR 才填),preview 是人类可读占位。
    // 跨 kind paste 时 image 必须能用 preview 进入拼接结果
    let items = [
        makeItem(id: "1", kind: .text, textFull: "hi"),
        makeItem(id: "2", kind: .image, textFull: nil, preview: "[image 4.5 MB]"),
        makeItem(id: "3", kind: .text, textFull: "bye"),
    ]
    #expect(PasteMerge.joinTextual(items) == "hi\n[image 4.5 MB]\nbye")
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

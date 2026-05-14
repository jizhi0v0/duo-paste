import Testing
import Foundation
@testable import DuoPasteCore

/// PasteMerge 是 SearchPanel 多选 paste 的合并策略 + 纯函数 helper。
/// 测两块:strategy 决策(用 kind 集合决定走哪条路径) + joinTextual/flattenFilePaths(顺序/边界)

private func makeItem(
    id: String,
    kind: ItemKind,
    textFull: String? = nil
) -> Item {
    Item(
        id: id,
        originDevice: "test",
        capturedAtNs: 0,
        kind: kind,
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

@Test func strategyMultipleImageReturnsFallback() {
    let items = [
        makeItem(id: "1", kind: .image),
        makeItem(id: "2", kind: .image),
    ]
    #expect(PasteMerge.strategy(for: items) == .fallbackToFirst(reason: .multipleImages))
}

@Test func strategyCrossKindReturnsFallback() {
    // text + image
    let items = [
        makeItem(id: "1", kind: .text, textFull: "hi"),
        makeItem(id: "2", kind: .image),
    ]
    #expect(PasteMerge.strategy(for: items) == .fallbackToFirst(reason: .crossKind))
}

@Test func strategyCrossKindFilePlusText() {
    let items = [
        makeItem(id: "1", kind: .file, textFull: "/tmp/a"),
        makeItem(id: "2", kind: .text, textFull: "b"),
    ]
    #expect(PasteMerge.strategy(for: items) == .fallbackToFirst(reason: .crossKind))
}

@Test func strategyAllTextSubkindsAreMergedText() {
    // text/url/rtf/html 应该都被当文本类合并。混合 url+text+rtf+html 也走 mergedText
    // 注:strategy 看的是"全部都是文本系 kind"——按定义 kinds.count > 1 算 crossKind。
    // 这里钉死:同 kind 才合并,即使都是文本系也不混
    let items = [
        makeItem(id: "1", kind: .text, textFull: "a"),
        makeItem(id: "2", kind: .url, textFull: "https://x"),
    ]
    // text + url 是不同 kind → crossKind fallback
    #expect(PasteMerge.strategy(for: items) == .fallbackToFirst(reason: .crossKind))
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

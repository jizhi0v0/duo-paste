import Testing
import Foundation
@testable import DuoPasteCore

/// 覆盖 `Item.cardPreviewSource(maxChars:)` 的契约:
/// **textFull 优先,preview 是网络传输短预览不该被 UI 当卡片源**。
///
/// 不钉这个测试,下次某个 PR 把 SearchView/iOS Models 里
/// `item.cardPreviewSource()` 误回退到 `item.preview ??` 也能编译过、所有
/// 业务测试也照常绿——但卡片会重新出现 "server 端 280 字符截尾 + `…`"
/// 的视觉 bug。这是 2026-05-20 review 提出的"易回退隐式契约"补丁。
@Suite("Card preview source (textFull > preview)")
struct CardPreviewSourceTests {

    /// 主路径——textFull 非空时**必须**返回 textFull,无视 preview 字段。
    /// preview 比 textFull 短(server makePreview 截过)是常态;不能因为
    /// preview 非空就抢先返回它。
    @Test("textFull 优先 preview")
    func textFullWinsOverPreview() {
        let it = Item(
            id: "a",
            originDevice: "self",
            capturedAtNs: 1,
            kind: .text,
            preview: "短预览…",
            textFull: "完整原文比 preview 长得多 完整原文比 preview 长得多"
        )
        let src = it.cardPreviewSource()
        #expect(src == "完整原文比 preview 长得多 完整原文比 preview 长得多")
        #expect(!src.contains("短预览"))
    }

    /// textFull 缺失(nil 或空串)时,退到 preview——iOS 老 peer 不发 textFull
    /// 字段或 capture 异常时的兜底路径,不能直接返回空让卡片白屏。
    @Test("textFull 缺失退到 preview")
    func fallsBackToPreviewWhenTextFullMissing() {
        let nilTF = Item(
            id: "a", originDevice: "self", capturedAtNs: 1, kind: .text,
            preview: "兜底"
        )
        #expect(nilTF.cardPreviewSource() == "兜底")

        let emptyTF = Item(
            id: "b", originDevice: "self", capturedAtNs: 1, kind: .text,
            preview: "兜底", textFull: ""
        )
        #expect(emptyTF.cardPreviewSource() == "兜底")
    }

    /// textFull 和 preview 都空 → 空串,让调用方加占位符(iOS displayPreview
    /// 用 `[image]` / `[file]` / `(空)`)。
    @Test("都空返回空串")
    func returnsEmptyWhenBothMissing() {
        let it = Item(
            id: "a", originDevice: "self", capturedAtNs: 1, kind: .image
        )
        #expect(it.cardPreviewSource() == "")
    }

    /// maxChars 防 NSAttributedString.append O(n) 大字符串攻击——textFull 几 MB
    /// 时直接 prefix 截,SwiftUI lineLimit 在视觉层再 truncate 一次。
    /// 边界:textFull.count == maxChars 时不截;> maxChars 时截到 maxChars。
    @Test("maxChars prefix 截断")
    func prefixesAtMaxChars() {
        let long = String(repeating: "a", count: 1000)
        let it = Item(
            id: "a", originDevice: "self", capturedAtNs: 1, kind: .text,
            textFull: long
        )
        #expect(it.cardPreviewSource(maxChars: 100).count == 100)
        #expect(it.cardPreviewSource(maxChars: 1000).count == 1000)
        #expect(it.cardPreviewSource(maxChars: 1001).count == 1000)
    }

    /// preview 字段无视 maxChars 直接返回——preview 已是 server 280 字符截过的
    /// 短版,二次截无意义。这条契约让 maxChars 的语义清晰:只防御 textFull 极大值。
    @Test("preview 路径无视 maxChars")
    func previewPathIgnoresMaxChars() {
        let it = Item(
            id: "a", originDevice: "self", capturedAtNs: 1, kind: .text,
            preview: String(repeating: "p", count: 280)
        )
        #expect(it.cardPreviewSource(maxChars: 10).count == 280)
    }
}

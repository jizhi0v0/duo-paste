import Testing
@testable import DuoPasteCore

private func plainPasteItem(
    _ id: String,
    kind: ItemKind,
    text: String? = nil
) -> Item {
    Item(
        id: id,
        originDevice: "test",
        capturedAtNs: 0,
        kind: kind,
        textFull: text
    )
}

@Suite("R3.3 plain-text paste resolver")
struct PlainTextPasteTests {
    @Test("only text, RTF and HTML are eligible")
    func eligibilityIsExact() {
        #expect(PlainTextPaste.supports(.text))
        #expect(PlainTextPaste.supports(.rtf))
        #expect(PlainTextPaste.supports(.html))
        #expect(!PlainTextPaste.supports(.url))
        #expect(!PlainTextPaste.supports(.image))
        #expect(!PlainTextPaste.supports(.file))
    }

    @Test("text is preserved and rich kinds use only their decoder")
    func routesToTheRightDecoder() {
        let text = plainPasteItem("text", kind: .text, text: "  exact\ntext  ")
        let rtf = plainPasteItem("rtf", kind: .rtf, text: "{\\rtf1 raw}")
        let html = plainPasteItem("html", kind: .html, text: "<b>raw</b>")

        #expect(PlainTextPaste.text(
            for: text,
            decodeRTF: { _ in Issue.record("text must not invoke RTF decoder"); return nil },
            decodeHTML: { _ in Issue.record("text must not invoke HTML decoder"); return nil }
        ) == "  exact\ntext  ")
        #expect(PlainTextPaste.text(
            for: rtf,
            decodeRTF: { raw in raw == "{\\rtf1 raw}" ? "rich text" : nil },
            decodeHTML: { _ in Issue.record("RTF must not invoke HTML decoder"); return nil }
        ) == "rich text")
        #expect(PlainTextPaste.text(
            for: html,
            decodeRTF: { _ in Issue.record("HTML must not invoke RTF decoder"); return nil },
            decodeHTML: { raw in raw == "<b>raw</b>" ? "rich HTML" : nil }
        ) == "rich HTML")
    }

    @Test("decoder failure never leaks raw markup")
    func decoderFailureIsAllOrNothing() {
        let rtf = plainPasteItem("rtf", kind: .rtf, text: "{\\rtf1 secret markup}")
        let html = plainPasteItem("html", kind: .html, text: "<b>secret markup</b>")

        #expect(PlainTextPaste.text(for: rtf, decodeRTF: { _ in nil }, decodeHTML: { _ in nil }) == nil)
        #expect(PlainTextPaste.text(for: html, decodeRTF: { _ in nil }, decodeHTML: { _ in nil }) == nil)
    }

    @Test("unsupported or missing content is rejected")
    func rejectsUnsupportedAndMissingContent() {
        for kind in [ItemKind.url, .image, .file] {
            let item = plainPasteItem(kind.rawValue, kind: kind, text: "must not paste")
            #expect(PlainTextPaste.text(
                for: item,
                decodeRTF: { _ in Issue.record("unsupported kind invoked decoder"); return nil },
                decodeHTML: { _ in Issue.record("unsupported kind invoked decoder"); return nil }
            ) == nil)
        }
        #expect(PlainTextPaste.text(
            for: plainPasteItem("nil", kind: .text),
            decodeRTF: { _ in nil },
            decodeHTML: { _ in nil }
        ) == nil)
    }

    @Test("multi-selection preserves order and rejects mixed kinds")
    func joinsEligibleSelectionAllOrNothing() {
        let eligible = [
            plainPasteItem("1", kind: .text, text: "first"),
            plainPasteItem("2", kind: .rtf, text: "raw second"),
            plainPasteItem("3", kind: .html, text: "raw third"),
        ]
        #expect(PlainTextPaste.joinedText(
            for: eligible,
            decodeRTF: { $0 == "raw second" ? "second" : nil },
            decodeHTML: { $0 == "raw third" ? "third" : nil }
        ) == "first\nsecond\nthird")

        let mixed = eligible + [plainPasteItem("4", kind: .image, text: "image preview")]
        #expect(PlainTextPaste.joinedText(
            for: mixed,
            decodeRTF: { _ in "second" },
            decodeHTML: { _ in "third" }
        ) == nil)
        #expect(PlainTextPaste.joinedText(
            for: [],
            decodeRTF: { _ in nil },
            decodeHTML: { _ in nil }
        ) == nil)
    }
}

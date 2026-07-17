import Foundation
import Testing

private func r33Source(_ relativePath: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@Suite("R3.3 macOS plain-text paste source contract")
struct PlainTextPasteUIContractTests {
    @Test("context menu is eligibility-gated and exposes Shift-Command-V")
    func menuIsGatedAndDocumentsShortcut() throws {
        let view = try r33Source("Sources/duo-pasted/SearchView.swift")

        #expect(view.contains("PlainTextPaste.supports(item.kind)"))
        #expect(view.contains("Button(\"粘贴为纯文本\")"))
        #expect(view.contains("onPastePlainText([item])"))
        #expect(view.contains(".keyboardShortcut(\"v\", modifiers: [.command, .shift])"))
    }

    @Test("panel routes Shift-Command-V to a distinct eligible-selection callback")
    func panelRoutesShortcutWithoutOverloadingNormalPaste() throws {
        let panel = try r33Source("Sources/duo-pasted/SearchPanelController.swift")

        #expect(panel.contains("onPastePlainText"))
        #expect(panel.contains("keyCode == 9 && isCmd && isShift"))
        #expect(panel.contains("items.allSatisfy({ PlainTextPaste.supports($0.kind) })"))
        #expect(panel.contains("self.onPastePlainText(items)"))
    }

    @Test("AppDelegate reuses both local barrier and cross-device echo suppression")
    func appDelegateUsesSuppressionAndExistingPasteFinishPath() throws {
        let app = try r33Source("Sources/duo-pasted/AppDelegate.swift")
        let methodStart = try #require(app.range(of: "private func pasteBackPlainText"))
        let methodEnd = try #require(app.range(of: "private func pasteBackMergedImages", range: methodStart.upperBound..<app.endIndex))
        let method = String(app[methodStart.lowerBound..<methodEnd.lowerBound])

        #expect(method.contains("watcher.pasteBack"))
        #expect(method.contains("Copyback.writePlainText"))
        #expect(method.contains("PasteSuppressionSet.fingerprint(text: pastedText)"))
        #expect(method.contains("panel.hide(immediate: true)"))
        #expect(method.contains("PasteInjector.injectCmdV"))
        #expect(method.contains("bumpUsedItems(items)"))
    }

    @Test("Copyback writes resolved plain text as the only pasteboard flavor")
    func copybackWritesOnlyStringFlavor() throws {
        let copyback = try r33Source("Sources/duo-pasted/Copyback.swift")
        let methodStart = try #require(copyback.range(of: "static func writePlainText"))
        let methodEnd = try #require(copyback.range(of: "static func writeMerged", range: methodStart.upperBound..<copyback.endIndex))
        let method = String(copyback[methodStart.lowerBound..<methodEnd.lowerBound])

        #expect(method.contains("PlainTextPaste.joinedText"))
        #expect(method.contains("pb.clearContents()"))
        #expect(method.contains("pb.setString(pastedText, forType: .string)"))
        #expect(!method.contains("forType: .rtf"))
        #expect(!method.contains("forType: .html"))
    }
}

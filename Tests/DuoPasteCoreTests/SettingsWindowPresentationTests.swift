import Foundation
import Testing

private func settingsWindowSource(_ relativePath: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@Suite("macOS Settings window presentation contract")
struct SettingsWindowPresentationTests {
    @Test("AppDelegate uses an owned window instead of the unreliable Settings selector")
    func delegateOwnsPresenter() throws {
        let delegate = try settingsWindowSource("Sources/duo-pasted/AppDelegate.swift")
        let methodStart = try #require(delegate.range(of: "func showSettings()"))
        let methodEnd = try #require(
            delegate.range(of: "func toggleSearch()", range: methodStart.upperBound..<delegate.endIndex)
        )
        let method = String(delegate[methodStart.lowerBound..<methodEnd.lowerBound])

        #expect(delegate.contains("private lazy var settingsWindowPresenter = SettingsWindowPresenter()"))
        #expect(method.contains("settingsWindowPresenter.show()"))
        #expect(!method.contains("showSettingsWindow:"))
        #expect(!method.contains("NSApp.sendAction"))
    }

    @Test("presenter handles closed, minimized, background-app, and cross-Space windows")
    func presenterRaisesReusableWindow() throws {
        let presenter = try settingsWindowSource("Sources/duo-pasted/SettingsWindowPresenter.swift")

        #expect(presenter.contains("NSHostingController(rootView: SettingsView())"))
        #expect(presenter.contains("window.isReleasedWhenClosed = false"))
        #expect(presenter.contains("window.isMiniaturized"))
        #expect(presenter.contains("window.deminiaturize(nil)"))
        #expect(presenter.contains(".moveToActiveSpace"))
        // Deliberately `ignoringOtherApps: true`. Cooperative `NSApp.activate()` is documented as
        // "does not guarantee that the app will be activated at all" — it expects the active app
        // to `yieldActivation(to:)` first, which nothing does for a status-item click. Measured on
        // macOS 27.0: bare `activate()` → 5/5 opens `key=false`; `ignoringOtherApps: true` → 5/5
        // `key=true`, with the app never leaving `.accessory`.
        #expect(presenter.contains("NSApp.activate(ignoringOtherApps: true)"))
        #expect(presenter.contains("window.orderFrontRegardless()"))
        #expect(presenter.contains("window.makeKeyAndOrderFront(nil)"))
        #expect(presenter.contains("func windowWillClose"))
    }

    @Test("the app stays .accessory — no activation-policy dance, no floating fallback")
    func presenterNeverTogglesActivationPolicy() throws {
        let presenter = try settingsWindowSource("Sources/duo-pasted/SettingsWindowPresenter.swift")
        // Strip doc comments: the rationale for *not* doing these things necessarily names them.
        let code = presenter
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // `.accessory` apps can already be activated and hold key windows (AppKit's own header
        // for NSApplicationActivationPolicyAccessory). Promoting to `.regular` only adds a Dock
        // icon and an app menu — the visible flicker, and the menu-bar extras jumping — and the
        // restore-on-failure path actively hid the window we had just shown.
        #expect(!code.contains("setActivationPolicy"))
        // `-activate` documents that activation may never happen. Don't punish it by hiding or
        // floating the window. (Reading `NSApp.isActive` to *log* it is fine — retrying on it
        // is what was wrong — so this only bans the floating fallback.)
        #expect(!code.contains("window.level = .floating"))
    }

    /// Regression: a rigid view inside the bottom safe-area inset blows the whole window's layout.
    ///
    /// `ApplyBar` is `SettingsView.detail`'s `.safeAreaInset(edge: .bottom)` content, so it feeds the
    /// container's *minimum* height. `.fixedSize(vertical:)` makes a view rigid — ideal height
    /// becomes min AND max — and that rigidity propagates out: detail's minimum becomes
    /// "whole page + bar", and `.frame(maxHeight: .infinity)` caps the maximum but cannot push a
    /// minimum back down. Detail then ignores the window's 620 and resolves to its content height
    /// (measured: 1306 = OCR page 1232 + bar 74), overflows NSHostingView and is centre-clipped:
    /// the sidebar rows vanish, the page header collides with the window title, and the bar itself
    /// is cut off below. The bar is 74pt tall either way and the text wraps fully without it, so
    /// `fixedSize` bought nothing here. Full write-up in ApplyBar.swift's doc comment.
    ///
    /// Text assertion on purpose: this is only observable by rendering the window, which no unit
    /// test in this suite does. Pinning the modifier out of the file is the cheap guard that
    /// actually catches a re-add, since re-adding it looks like an obvious multi-line-text fix.
    @Test("ApplyBar keeps no rigid view inside the bottom safe-area inset")
    func applyBarHasNoFixedSize() throws {
        let applyBar = try settingsWindowSource("Sources/duo-pasted/Settings/ApplyBar.swift")

        // Strip comments: the doc comment above deliberately names the modifier to explain the ban.
        let code = applyBar
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains(".fixedSize"))
    }

    @Test("window fits the visible screen and keeps the sidebar below a standard titlebar")
    func windowUsesAdaptiveStandardFrame() throws {
        let presenter = try settingsWindowSource("Sources/duo-pasted/SettingsWindowPresenter.swift")
        let settings = try settingsWindowSource("Sources/duo-pasted/Settings/SettingsView.swift")

        #expect(presenter.contains("NSWindow(\n            contentRect:"))
        #expect(!presenter.contains("let window = NSWindow(contentViewController:"))
        #expect(presenter.contains("visibleFrame.insetBy(dx: margin, dy: margin)"))
        #expect(presenter.contains("NSWindow.contentRect("))
        #expect(presenter.contains("width: min(760, availableContent.width)"))
        #expect(presenter.contains("height: min(620, availableContent.height)"))
        #expect(!settings.contains(".frame(width: 760, height: 620)"))
        #expect(settings.contains("minWidth: 560"))
        #expect(settings.contains("maxWidth: .infinity"))
    }

    @Test("settings navigation uses a native sidebar instead of a segmented tab strip")
    func settingsUsesNativeSidebar() throws {
        let settings = try settingsWindowSource("Sources/duo-pasted/Settings/SettingsView.swift")

        #expect(settings.contains("NavigationSplitView"))
        #expect(settings.contains("List(SettingsPane.allCases, selection: $pane)"))
        #expect(settings.contains(".listStyle(.sidebar)"))
        // 列宽仍必须被约束（不能让侧边栏自由伸缩挤掉详情区），但具体数字不钉死：
        // 图标块比纯符号宽，行的理想宽度会随之调整。
        #expect(settings.contains(".navigationSplitViewColumnWidth(min:"))
        #expect(!settings.contains("TabView(selection:"))
        #expect(!settings.contains(".tabItem"))
    }

    @Test("the SwiftUI scene produces no window at all")
    func sceneIsPlaceholderOnly() throws {
        let app = try settingsWindowSource("Sources/duo-pasted/App.swift")
        let settings = try settingsWindowSource("Sources/duo-pasted/Settings/SettingsView.swift")

        // The placeholder must render nothing. A `Settings` scene is specifically banned:
        // even `Settings { EmptyView() }` is a restorable window, and with window restoration
        // on macOS reopens it every launch and gives it key focus — starving the presenter's
        // activation handshake until it falls back to `.accessory` and hides the real window.
        #expect(app.contains("isInserted: .constant(false)"))
        #expect(!app.contains("Settings {"))
        #expect(!app.contains("SettingsView()"))
        #expect(!settings.contains("SettingsWindowProbe"))
        #expect(!settings.contains("SettingsWindowBridge"))
    }

    @Test("status item preserves the click's cooperative activation grant")
    func statusItemDoesNotDeferSettingsAction() throws {
        let statusBar = try settingsWindowSource("Sources/duo-pasted/StatusBarController.swift")
        let methodStart = try #require(statusBar.range(of: "@objc private func openSettings()"))
        let methodEnd = try #require(
            statusBar.range(of: "@objc private func pauseFiveMinutes()", range: methodStart.upperBound..<statusBar.endIndex)
        )
        let method = String(statusBar[methodStart.lowerBound..<methodEnd.lowerBound])

        #expect(method.contains("AppDelegate.shared?.showSettings()"))
        #expect(!method.contains("DispatchQueue.main.async"))
    }
}

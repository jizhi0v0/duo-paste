import AppKit
import DuoPasteCore

/// AppKit status item controller.
///
/// `NSStatusItem.menu` lets AppKit anchor the menu to the status item's actual window for
/// both primary and secondary clicks. SwiftUI `MenuBarExtra(.menu)` on macOS 26 can route a
/// secondary click through a context-menu path whose anchor is stale after the item has been
/// repositioned, leaving the menu detached near the screen's trailing edge.
@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private var openMenuItem: NSMenuItem!
    private var savedViewsMenuItem: NSMenuItem!
    private var exportMenuItem: NSMenuItem!
    private var captureMenuItem: NSMenuItem!
    private var resumeCaptureMenuItem: NSMenuItem!

    init(hotkey: Config.HotkeyConfig, savedSearchViews: [SavedSearchView] = []) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupButton()
        setupMenu(hotkey: hotkey, savedSearchViews: savedSearchViews)
    }

    func updateOpenSearchHotkey(_ hotkey: Config.HotkeyConfig) {
        applyHotkey(hotkey, to: openMenuItem)
    }

    func updateSavedSearchViews(_ views: [SavedSearchView]) {
        let submenu = NSMenu()
        if views.isEmpty {
            let empty = NSMenuItem(title: "暂无保存视图", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for view in views {
                let entry = NSMenuItem(
                    title: view.name,
                    action: #selector(openSavedSearchView(_:)),
                    keyEquivalent: ""
                )
                entry.target = self
                entry.representedObject = view.id
                submenu.addItem(entry)
            }
        }
        savedViewsMenuItem.submenu = submenu
    }

    func setExportProgress(_ text: String?) {
        if let text {
            exportMenuItem.title = text
            exportMenuItem.action = #selector(cancelExport)
        } else {
            exportMenuItem.title = "导出…"
            exportMenuItem.action = #selector(exportData)
        }
    }

    func updateCapturePause(_ pause: CapturePause?, now: Date = Date()) {
        let active = pause?.isActive(at: now) == true
        if active, let pause {
            switch pause {
            case .until(let deadline):
                let minutes = max(1, Int(ceil(deadline.timeIntervalSince(now) / 60)))
                captureMenuItem.title = "捕获已暂停 · 约 \(minutes) 分钟"
            case .untilResumed:
                captureMenuItem.title = "捕获已暂停 · 等待手动恢复"
            }
        } else {
            captureMenuItem.title = "捕获中"
        }
        resumeCaptureMenuItem.isEnabled = active
        applyStatusIcon(paused: active)
    }

    private func setupButton() {
        applyStatusIcon(paused: false)
    }

    private func applyStatusIcon(paused: Bool) {
        guard let button = item.button else { return }
        button.image = NSImage(
            systemSymbolName: paused ? "pause.circle.fill" : "doc.on.clipboard",
            accessibilityDescription: paused ? "duo-paste 捕获已暂停" : "duo-paste 正在捕获"
        )
        button.image?.isTemplate = true
    }

    private func setupMenu(hotkey: Config.HotkeyConfig, savedSearchViews: [SavedSearchView]) {
        let menu = NSMenu()

        let open = NSMenuItem(
            title: "打开搜索",
            action: #selector(openSearch),
            keyEquivalent: ""
        )
        open.target = self
        applyHotkey(hotkey, to: open)
        menu.addItem(open)
        openMenuItem = open

        let savedViews = NSMenuItem(title: "保存的视图", action: nil, keyEquivalent: "")
        menu.addItem(savedViews)
        savedViewsMenuItem = savedViews
        updateSavedSearchViews(savedSearchViews)

        menu.addItem(.separator())

        let capture = NSMenuItem(title: "捕获中", action: nil, keyEquivalent: "")
        let captureMenu = NSMenu()

        let pause5 = NSMenuItem(title: "暂停 5 分钟", action: #selector(pauseFiveMinutes), keyEquivalent: "")
        pause5.target = self
        captureMenu.addItem(pause5)

        let pause30 = NSMenuItem(title: "暂停 30 分钟", action: #selector(pauseThirtyMinutes), keyEquivalent: "")
        pause30.target = self
        captureMenu.addItem(pause30)

        let pauseUntilResume = NSMenuItem(title: "暂停直到手动恢复", action: #selector(pauseUntilResumed), keyEquivalent: "")
        pauseUntilResume.target = self
        captureMenu.addItem(pauseUntilResume)
        captureMenu.addItem(.separator())

        let resume = NSMenuItem(title: "恢复捕获", action: #selector(resumeCapture), keyEquivalent: "")
        resume.target = self
        resume.isEnabled = false
        captureMenu.addItem(resume)

        capture.submenu = captureMenu
        menu.addItem(capture)
        captureMenuItem = capture
        resumeCaptureMenuItem = resume

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            let update = NSMenuItem(
                title: "检查更新…",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            update.target = self
            menu.addItem(update)
        }

        let export = NSMenuItem(
            title: "导出…",
            action: #selector(exportData),
            keyEquivalent: ""
        )
        export.target = self
        menu.addItem(export)
        exportMenuItem = export

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 duo-paste",
            action: #selector(confirmQuit),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    private func applyHotkey(_ hotkey: Config.HotkeyConfig, to menuItem: NSMenuItem) {
        menuItem.keyEquivalent = hotkey.key.lowercased()
        menuItem.keyEquivalentModifierMask = hotkey.modifiers.reduce(into: []) { result, modifier in
            switch modifier.lowercased() {
            case "cmd", "command": result.insert(.command)
            case "option", "alt": result.insert(.option)
            case "control", "ctrl": result.insert(.control)
            case "shift": result.insert(.shift)
            default: break
            }
        }
    }

    @objc private func openSearch() {
        AppDelegate.shared?.toggleSearch()
    }

    @objc private func openSavedSearchView(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AppDelegate.shared?.openSavedSearchView(id: id)
    }

    @objc private func openSettings() {
        // Return from AppKit's menu tracking loop before activating the Settings scene.
        DispatchQueue.main.async {
            AppDelegate.shared?.showSettings()
        }
    }

    @objc private func pauseFiveMinutes() {
        AppDelegate.shared?.pauseCapture(minutes: 5)
    }

    @objc private func pauseThirtyMinutes() {
        AppDelegate.shared?.pauseCapture(minutes: 30)
    }

    @objc private func pauseUntilResumed() {
        AppDelegate.shared?.pauseCaptureUntilResumed()
    }

    @objc private func resumeCapture() {
        AppDelegate.shared?.resumeCapture()
    }

    @objc private func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
    }

    @objc private func exportData() {
        AppDelegate.shared?.showExportDialog()
    }

    @objc private func cancelExport() {
        AppDelegate.shared?.cancelExport()
    }

    @objc private func confirmQuit() {
        AppDelegate.shared?.confirmQuit()
    }
}

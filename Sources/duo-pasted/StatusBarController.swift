import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let onOpenSearch: () -> Void

    init(onOpenSearch: @escaping () -> Void) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.onOpenSearch = onOpenSearch
        super.init()
        setupButton()
        setupMenu()
    }

    private func setupButton() {
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "duo-paste"
            )
            button.image?.isTemplate = true
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(
            title: "打开搜索",
            action: #selector(openSearch),
            keyEquivalent: "v"
        )
        open.keyEquivalentModifierMask = [.command, .option]
        open.target = self
        menu.addItem(open)

        menu.addItem(NSMenuItem.separator())

        // 设置窗口入口——走 SwiftUI Settings scene，macOS 14+ 用 showSettingsWindow:，
        // 老版本回退 showPreferencesWindow:（实际 macOS 25.4 全部用前者）
        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: "退出 duo-paste",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func openSettings() {
        // 直接调 AppDelegate 自管 Settings 窗口——accessory app 没 Dock + 无主菜单，
        // SwiftUI Settings scene 的 `showSettingsWindow:` selector chain 不响应
        AppDelegate.shared?.showSettings()
    }

    @objc private func openSearch() {
        onOpenSearch()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

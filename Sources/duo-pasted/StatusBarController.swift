import AppKit
import DuoPasteCore

@MainActor
final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let onOpenSearch: () -> Void
    private var openMenuItem: NSMenuItem!

    init(hotkey: Config.HotkeyConfig, onOpenSearch: @escaping () -> Void) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.onOpenSearch = onOpenSearch
        super.init()
        setupButton()
        setupMenu(hotkey: hotkey)
    }

    /// reloadHotkey 把 GlobalHotKey 重 register 之后调来同步状态栏菜单上"打开搜索"
    /// 那行的 ⌘⌥V 标记。仅刷 keyEquivalent / modifierMask，不重建 menu
    func updateOpenSearchHotkey(_ hotkey: Config.HotkeyConfig) {
        applyHotkey(hotkey, to: openMenuItem)
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

    private func setupMenu(hotkey: Config.HotkeyConfig) {
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

    private func applyHotkey(_ hotkey: Config.HotkeyConfig, to menuItem: NSMenuItem) {
        menuItem.keyEquivalent = hotkey.key.lowercased()
        menuItem.keyEquivalentModifierMask = Self.modifierFlags(from: hotkey.modifiers)
    }

    private static func modifierFlags(from modifiers: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for m in modifiers {
            switch m.lowercased() {
            case "cmd", "command":  flags.insert(.command)
            case "option", "alt":   flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            case "shift":           flags.insert(.shift)
            default: break
            }
        }
        return flags
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
        // NSApp.terminate 走 exit 0。plist KeepAlive={SuccessfulExit:false} 下 exit 0 不被
        // launchd 拉回——正是「退出」想要的：用户主动退就真的停掉。（旧 KeepAlive=true 时
        // 点退出会被立刻 respawn，是 bug；方案 A 的 gate 顺带修了它。）
        NSApp.terminate(nil)
    }
}

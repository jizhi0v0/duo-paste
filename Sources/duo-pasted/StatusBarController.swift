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

        // 「检查更新…」——仅当 bundle 嵌了 Sparkle（SUFeedURL 存在）才挂。DP_NO_SPARKLE
        // 本地构建不写 SU 键、不实例化 UpdaterController，挂了点也无 feed 可查，干脆不显。
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            let update = NSMenuItem(
                title: "检查更新…",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            update.target = self
            menu.addItem(update)
        }

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

    @objc private func checkForUpdates() {
        // SUFeedURL 存在才会挂这个 menu item，所以此处 UpdaterController 已在启动时实例化。
        UpdaterController.shared.checkForUpdates()
    }

    @objc private func quit() {
        // NSApp.terminate 走 exit 0。plist KeepAlive={SuccessfulExit:false} 下 exit 0 不被
        // launchd 拉回——daemon 真的停（剪贴板捕获/同步全停），当前 session 内只能手动
        // launchctl kickstart / install-agent.sh 才回来。所以先弹确认框把这个语义讲清楚，
        // 避免用户误以为「退出」只是关个窗口。（旧 KeepAlive=true 时点退出会被立刻 respawn，
        // 是 bug；方案 A 的 SuccessfulExit gate 顺带修了它。）
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出 duo-paste？"
        alert.informativeText = "退出后剪贴板捕获与跨设备同步会停止，直到下次开机自启，"
            + "或手动运行 install-agent.sh / launchctl kickstart 重新启动。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        // accessory app 没 Dock，runModal 前先 activate 让弹窗到前台拿焦点
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }
}

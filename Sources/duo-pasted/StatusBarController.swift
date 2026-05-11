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

        let quit = NSMenuItem(
            title: "退出 duo-paste",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func openSearch() {
        onOpenSearch()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

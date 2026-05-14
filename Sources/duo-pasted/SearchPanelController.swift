import AppKit
import SwiftUI
import DuoPasteCore

/// HUD 风格的 NSPanel，托管 SwiftUI SearchView。Spotlight 风格：
/// - 不抢前台 app 激活（.nonactivatingPanel）
/// - 所有 Space 可见
/// - 失去 key 状态自动隐藏（但用户主动 close 不抢焦点）
@MainActor
final class SearchPanelController: NSObject, NSWindowDelegate {
    private let state: AppState
    /// Enter / 双击触发。多选时按 selectedIDs 顺序传整个数组;空选 fallback 到 currentItem 单项。
    /// 多选合并 vs 降级首项的语义由 AppDelegate.pasteBack 决定
    private let onPaste: ([Item]) -> Void
    /// ⌘Return 时触发——file/image kind 且**单选**。AppDelegate 用它调 NSWorkspace reveal/open。
    /// 多选 reveal 语义不清,仅单选生效
    private let onReveal: ((Item) -> Void)?
    /// panel hide / dismiss 路径调用——AppDelegate 用它 cancel 进行中的 lazy paste
    /// task + 重置 state.pasteProgress。覆盖三条触发点：Esc 键 / windowDidResignKey
    /// （焦点切走）/ 主动调 hide() 的其它入口
    private let onDismiss: () -> Void
    private var panel: NSPanel?
    private var localKeyMonitor: Any?

    init(state: AppState, onPaste: @escaping ([Item]) -> Void,
         onReveal: ((Item) -> Void)? = nil,
         onDismiss: @escaping () -> Void = {}) {
        self.state = state
        self.onPaste = onPaste
        self.onReveal = onReveal
        self.onDismiss = onDismiss
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let p = ensurePanel()
        positionCenter(p)
        // 临时切到 regular 让 panel 能拿到 key 状态，显示完再切回去
        // 但因为我们已经是 .accessory 且 panel 是 nonactivating，需要手动 makeKey
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        // 触发 SearchView 重新抢焦点 + kick refresh（panel 被复用，onAppear 不再 fire）
        state.openPulse &+= 1
    }

    func hide() {
        panel?.orderOut(nil)
        removeKeyMonitor()
        // 调用方负责 cancel 进行中的 lazy paste task + 重置 pasteProgress 状态。
        // 不放在 hide 内部直接操作 state，让 controller 跟 paste 业务解耦
        onDismiss()
    }

    /// 装 NSEvent 本地监听器：箭头/Return/Esc 在 TextField 看到之前被截走，
    /// 不然搜索框会用这些键移动光标 / 换行，导航就废了。
    /// 其他按键正常透传给 SwiftUI。
    ///
    /// IME 例外：输入法 composing 时（marked text 非空），↑↓ 选候选页、Return 确认候选、
    /// Esc 取消候选——这些都必须交还给 IME，不能被我们当成列表导航/粘贴/关闭吞掉。
    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 监听回调在 main 线程触发；只取 Sendable 的 keyCode / modifier bool 进
            // MainActor 闭包，避免 NSEvent 非 Sendable 进入隔离边界。
            let keyCode = Int(event.keyCode)
            let isCmd = event.modifierFlags.contains(.command)
            let interceptCodes: Set<Int> = [126, 125, 36, 76, 53]
            // ⌘P (keyCode=35) = 切换选中行的 pinned。仅 Cmd 修饰键命中时截走；
            // 不带修饰键的 P 透传给 TextField 当作正常字符输入
            let isCmdP = (keyCode == 35 && isCmd)
            guard interceptCodes.contains(keyCode) || isCmdP else { return event }
            // SwiftUI TextField 编辑时 firstResponder = NSTextField 的 field editor（NSTextView）。
            // hasMarkedText() == true 代表 IME 正在 compose 候选词，所有键都让 IME 自己消费。
            if let tv = event.window?.firstResponder as? NSTextView, tv.hasMarkedText() {
                return event
            }
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isKeyWindow else { return }
                switch keyCode {
                case 126: self.state.navigate(by: -1)           // ↑
                case 125: self.state.navigate(by: 1)            // ↓
                case 36, 76:                                    // Return / Enter
                    // 多选时按 selectedIDs 顺序传整个数组;没显式多选 → 取 currentItem 兜底
                    let items: [Item]
                    if !self.state.selectedItems.isEmpty {
                        items = self.state.selectedItems
                    } else if let cur = self.state.currentItem {
                        items = [cur]
                    } else {
                        items = []
                    }
                    guard !items.isEmpty else { break }
                    // Cmd+Return reveal 仅对单选生效(多选 reveal 语义不清)
                    if isCmd && items.count == 1,
                       items[0].kind == .file || items[0].kind == .image {
                        self.onReveal?(items[0])
                    } else {
                        // 不在这里 hide——把"何时 hide"交给 onPaste 回调实现方。
                        // image kind + blob 缺字节走 lazy 拉路径时 panel 要保持可见显示
                        // spinner overlay；同步路径由 AppDelegate.pasteBack 拿 panel 引用自己关
                        self.onPaste(items)
                    }
                case 53: self.hide()                            // Esc
                case 35 where isCmd:                            // ⌘P = toggle pin
                    if let item = self.state.currentItem {
                        self.state.togglePin(item)
                    }
                default: break
                }
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let contentRect = NSRect(x: 0, y: 0, width: 760, height: 520)
        let p = HUDPanel(
            contentRect: contentRect,
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false   // 自己控制 hide
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovableByWindowBackground = true
        p.delegate = self
        // Spotlight-style 大圆角 + 透明 panel：让 SwiftUI .ultraThickMaterial 背景
        // 配 RoundedRectangle clipShape 自己控制形状；panel 自身透明只用来定位 + 投影。
        // hasShadow=true 时 AppKit 会沿 contentView layer.cornerRadius 形状画系统级 drop shadow。
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let root = SearchView(
            state: state,
            onPaste: { [weak self] items in
                guard let self else { return }
                // 同上：不在这里 hide；onPaste 回调实现方决定（lazy 路径要 keep panel
                // 显示 spinner，同步路径在完成后调 controller.hide）。
                // 双击行 → SearchView 传 [item] 单项;直接走 pasteBack 处理 single 路径
                self.onPaste(items)
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = contentRect
        hosting.autoresizingMask = [.width, .height]
        // 让系统 drop shadow 跟着圆角走（否则 panel rect 矩形阴影会从圆角外露出来）
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 22
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        p.contentView = hosting
        // wantsLayer/cornerRadius 后 invalidate 让 shadow 重新按 mask 计算
        p.invalidateShadow()

        panel = p
        return p
    }

    private func positionCenter(_ p: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let sFrame = screen.visibleFrame
        let pFrame = p.frame
        let x = sFrame.midX - pFrame.width / 2
        // 屏幕中线居中。原版用 0.62 偏上 1/3 模仿 Spotlight,user 反馈太偏所以撤掉
        let y = sFrame.midY - pFrame.height / 2
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // 用户切走了，自动隐藏
        hide()
    }
}

/// 默认 NSPanel 不接受 key/main 状态以便不抢焦点，但我们要让 TextField 能拿到键盘焦点，
/// 因此覆盖 canBecomeKey。
@MainActor
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

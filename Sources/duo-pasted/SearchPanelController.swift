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
    /// 多选 reveal 语义不清,仅单选生效。SearchView 右键 contextMenu "在 Finder 显示" 也走这里
    private let onReveal: ((Item) -> Void)?
    /// 右键 contextMenu "打开方式" 子菜单选中某 app 后触发。(item, app bundleURL)。
    /// AppDelegate 用 OpenWithStaging 物化 item → NSWorkspace 调起目标 app。
    /// nil 时 SearchView 不显示子菜单
    private let onOpenWith: ((Item, URL) -> Void)?
    /// panel hide / dismiss 路径调用——AppDelegate 用它 cancel 进行中的 lazy paste
    /// task + 重置 state.pasteProgress。覆盖三条触发点：Esc 键 / windowDidResignKey
    /// （焦点切走）/ 主动调 hide() 的其它入口
    private let onDismiss: () -> Void
    /// 右上角齿轮按钮触发——AppDelegate 用它 hide() panel + 打开 Settings 窗口。
    /// menubar icon 可被用户隐藏,这是唯一始终可见的"回到 Settings"路径
    private let onOpenSettings: (() -> Void)?
    /// previewShown=true 时拦 ⌘C,如 TextPreviewBody 有选区则调此 callback 把选中
    /// 文本写到 NSPasteboard。AppDelegate 实现里走 `watcher.pasteBack` barrier
    /// 防自家 watcher 再次 capture
    private let onCopyText: ((String) -> Void)?
    private var panel: NSPanel?
    /// panel show **之前**的 frontmost app 快照。PasteInjector 用它在 paste 完成
    /// 后把焦点拉回去 + 注入 Cmd+V。**必须**在 makeKeyAndOrderFront 之前抓——
    /// panel 拿到 key window 状态后 NSWorkspace.frontmostApplication 仍是目标 app
    /// (.nonactivatingPanel 不切 frontmost),但万一未来谁误加了 NSApp.activate
    /// 调用,这个快照能兜底拿到正确目标。**绝不**在 paste 时刻才读 frontmost。
    /// self pid 直接排掉 (用户从 menubar / Settings 触发的入口),避免把自己当目标
    private(set) var previousFrontmostApp: NSRunningApplication?
    /// 标记 ensurePanel 是否刚创建了新 panel(冷启动首次 show)。show() 路径用它决定是否
    /// defer 一个 runloop tick 让 SwiftUI 完成 .glassEffect / .ultraThickMaterial 首帧渲染,
    /// 否则黑影会出现在 alpha fadein 期间。复用 panel 时这个标记是 false 直接动画
    private var freshlyCreated: Bool = false
    private var localKeyMonitor: Any?
    /// 方向键 NSEvent.isARepeat=true(长按 keyboard repeat 触发的事件) 节流时间戳。
    /// macOS 默认 key repeat ~30ms (~33fps),裸放体感"闪现"无法看清滑过的卡;
    /// 但 80ms (~12fps) 又比系统按键慢一倍多体感卡顿。45ms (~22fps) 是平衡点——
    /// 比系统重复慢 ~50% 避免极快 reduction 让 SwiftUI scrollTo + layout 来不及绘制,
    /// 但已接近"流畅滑动"心智 (>20fps)。
    /// **只 throttle 长按 repeat**:首次按下(isARepeat=false)永远立刻 fire,体感跟单击一样灵敏
    private var lastNavigateRepeatTime: TimeInterval = 0
    private static let navigateRepeatMinIntervalSec: TimeInterval = 0.045
    /// 全局鼠标监听器——抓"用户点了我们 app 之外区域"的事件,触发自动 hide。
    /// 解决 preview 打开时 windowDidResignKey 被守卫(防 TCC alert)的副作用:
    /// 单纯 resign-key 不区分键盘切走/系统 alert/鼠标点外面,无法只关心后者;
    /// 改成 global mouse monitor 专门捕获鼠标点外区域 → 主动 hide。
    /// global monitor 永远收不到自家 app 内事件(包括 search panel + preview panel),
    /// 所以点 panel 自身不会误触发,TCC alert 是系统弹无鼠标 down 也不会触发
    private var globalClickMonitor: Any?
    /// 空格预览的独立浮窗 controller。lazy 跟搜索 panel 同生命周期——首次 ensurePanel
    /// 时一并创建,setAnchor 绑搜索 panel 作为屏幕坐标换算锚点。
    /// 浮窗不抢 key,因此搜索 panel 的 NSEvent monitor 仍然能截到空格/箭头/Esc 路由预览
    private var previewController: PreviewPanelController?

    init(state: AppState, onPaste: @escaping ([Item]) -> Void,
         onReveal: ((Item) -> Void)? = nil,
         onOpenWith: ((Item, URL) -> Void)? = nil,
         onDismiss: @escaping () -> Void = {},
         onOpenSettings: (() -> Void)? = nil,
         onCopyText: ((String) -> Void)? = nil) {
        self.state = state
        self.onPaste = onPaste
        self.onReveal = onReveal
        self.onOpenWith = onOpenWith
        self.onDismiss = onDismiss
        self.onOpenSettings = onOpenSettings
        self.onCopyText = onCopyText
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
        let targetOrigin = bottomOrigin()
        // 开场动画:从 targetOrigin.y - 14 处淡入上浮。alphaValue=0 + 偏移 14pt 起,
        // NSAnimationContext 走 0.22s ease-out 到 targetOrigin + alphaValue=1。
        // panel hide 时复位的 alpha + origin 在这里被重新设回起点
        let startOrigin = NSPoint(x: targetOrigin.x, y: targetOrigin.y - 14)
        p.setFrameOrigin(startOrigin)
        p.alphaValue = 0
        // makeKeyAndOrderFront 之前快照 frontmost app —— panel 用 .nonactivatingPanel
        // styleMask + HUDPanel.canBecomeKey 拿键盘焦点,**不**抢 app activation,所以
        // 目标 app 仍是 frontmost。但 NSWorkspace.frontmostApplication 在 panel 已经
        // 是 key window 之后语义会变模糊(取决于 AppKit 实现细节),提前抓最稳。
        // self pid 排除:menubar / Settings 触发时 frontmost 是自己,这种情况下没有
        // "回填目标",previousFrontmostApp 留 nil 让 PasteInjector graceful 退化
        let front = NSWorkspace.shared.frontmostApplication
        let selfPid = ProcessInfo.processInfo.processIdentifier
        previousFrontmostApp = (front?.processIdentifier != selfPid) ? front : nil
        // **不**调 NSApp.activate(ignoringOtherApps:) —— 这会把 duo-paste 切到 frontmost,
        // 破坏 .nonactivatingPanel 的整条产品意图(panel 显示时目标输入框仍是 first
        // responder,paste 完 Cmd+V 直接落在原 caret 处)。makeKeyAndOrderFront 单独
        // 工作只让 panel 拿 key 状态,不切 frontmost
        p.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        installGlobalClickMonitor()
        // 触发 SearchView 重新抢焦点 + kick refresh（panel 被复用，onAppear 不再 fire）
        state.openPulse &+= 1
        // **保留 selectedIDs**:用户上次翻到第 N 张关 panel,再开 panel 应该回到第 N 张
        // (产品需求"保留 index")。anchor/scrollTo 的同步由 SearchView 端的 scrollTo 跟
        // 随 anchor 实现(scrollTo 用 selectedIDs.last ?? results.first?.id),保证 anchor
        // 卡始终在视口内 GeometryReader 能挂载 publish frame
        // 冷启动首次 show 时 SwiftUI .glassEffect / .ultraThickMaterial 渲染是 async 的,
        // ensurePanel 的 layoutSubtreeIfNeeded 只保证 AppKit 层 layout pass 跑过,SwiftUI 的
        // material 子层仍可能落后一帧。defer 一个 main runloop tick 让 render server 接管
        // 后再启动 fadein 动画,黑影就藏在 alpha=0 阶段不会被用户看到
        let wasFreshlyCreated = freshlyCreated
        freshlyCreated = false
        let animate: @MainActor () -> Void = { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.3, 1.0)
                ctx.allowsImplicitAnimation = true
                p.animator().setFrameOrigin(targetOrigin)
                p.animator().alphaValue = 1
            }
        }
        if wasFreshlyCreated {
            DispatchQueue.main.async { MainActor.assumeIsolated(animate) }
        } else {
            animate()
        }
    }

    /// `immediate=true` 跳过 140ms 淡出动画**同步** orderOut——专给 paste 路径用:
    /// PasteInjector post Cmd+V 时如果 panel 仍在 window list(动画期间 isVisible=true),
    /// windowserver 把 panel 当 key window,Cmd+V 投到 panel 被吞,目标 app 收不到。
    /// 默认 `false` 保留淡出动画给 Esc / 点空白 / windowDidResignKey 这些路径
    func hide(immediate: Bool = false) {
        // **同步**先 cancel：lazy paste task / preview——动画 140ms 内 fetchBlobLazy
        // 可能完成（30s 总超时下尤其放大），把 blob 字节写进 NSPasteboard 但 panel 已
        // 关，用户切到其他 app 后莫名收到 paste = CLAUDE.md "孤儿写入" 现象。
        // 视觉收场动画照常走，但 cancel paste/preview 不等动画
        finalizeHideImmediate()

        guard let p = panel, p.isVisible else {
            panel?.orderOut(nil)
            removeKeyMonitor()
            removeGlobalClickMonitor()
            return
        }

        if immediate {
            // 同步 orderOut:从 windowserver 的 window list 摘下,key window 立即让给
            // 底下的 target app。alpha 复位让下次 show 不会因为残留 alpha=0 被中断。
            // 视觉损失:无淡出。paste 心智下用户期望的就是"内容立即出现",animation
            // 反而碍事——Paste.app 实测也是 instant close
            p.orderOut(nil)
            p.alphaValue = 1
            removeKeyMonitor()
            removeGlobalClickMonitor()
            return
        }

        let currentOrigin = p.frame.origin
        let exitOrigin = NSPoint(x: currentOrigin.x, y: currentOrigin.y - 8)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrameOrigin(exitOrigin)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // NSAnimationContext 的 completionHandler 不带 isolation——回到 main 后
            // 才能访问 @MainActor 隔离的 panel / removeKeyMonitor
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel?.orderOut(nil)
                // alpha 复位让下次 show 不会因为残留 alpha=0 被中断
                self.panel?.alphaValue = 1
                self.removeKeyMonitor()
                self.removeGlobalClickMonitor()
            }
        })
    }

    /// hide 路径共用同步收尾——cancel preview + 通知 caller cancel paste task。
    /// **必须**在动画**开始前**调，否则 140ms 动画期间 lazy fetch 可能完成把字节写进
    /// NSPasteboard，导致用户切到其他 app 后莫名收到 paste
    private func finalizeHideImmediate() {
        // preview overlay 永远不跨 panel 生命周期保留——hide 时强制复位,
        // 下次 show 看到的是干净状态。windowDidResignKey 也走这里,所以 panel
        // 失焦自动隐藏的路径同样覆盖。state.previewShown 复位还会触发 SearchView
        // 的 onChange → previewController.hide();这里直接再调一次兜底,避免 SwiftUI
        // 在 panel 已 orderOut 后 onChange 不触发的边界情况
        state.previewShown = false
        previewController?.hide()
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
            // isARepeat = NSEvent 标记本事件是 keyboard repeat(长按持续触发)非首次按下。
            // 方向键路径用它做节流,避免 macOS 默认 ~30/s 重复速率让卡片闪现而非平滑滑过
            let isARepeat = event.isARepeat
            // 横向卡片布局:←/→ 切换选中(123/124);↑/↓(126/125)继续兼容老用户 muscle memory
            // (TextField 横向单行,↑/↓ 移光标无意义,可吞掉重定向到 navigate)。
            // 51 = Backspace,仅在 query 为空 + activeQualifiers 非空时拦截弹最后一个 chip,
            // 其他情况透传给 TextField 让用户正常删字
            let interceptCodes: Set<Int> = [123, 124, 125, 126, 36, 76, 53, 51]
            // ⌘P (keyCode=35) = 切换选中行的 pinned。仅 Cmd 修饰键命中时截走；
            // 不带修饰键的 P 透传给 TextField 当作正常字符输入
            let isCmdP = (keyCode == 35 && isCmd)
            // ⌘C (keyCode=8) = previewShown 状态下若文本预览有选区,复制选中文字。
            // 无选区 / preview 未开则透传给 TextField (原生 ⌘C 仍能复制搜索框选中文字)
            let isCmdC = (keyCode == 8 && isCmd)
            // ⌘A (keyCode=0) = previewShown 状态下全选预览内容(文本→NSTextView.selectAll;
            // 图片→Live Text selectAllText)。preview 未开 / 当前 kind 无可选目标透传给搜索框
            let isCmdA = (keyCode == 0 && isCmd)
            // 空格键(49)的拦截条件——以 input 焦点状态为主分流:
            //   A) input 没焦点(用户点了卡 / 空白) → 无视 query 直接 toggle preview
            //   B) input 有焦点 + preview 已开 → 空格关 preview(从 preview 状态退出)
            //   C) input 有焦点 + preview 未开 + query 为空 → 打开 preview
            //   D) input 有焦点 + query 非空 → 透传字面空格(多词搜索 "ipados news")
            // firstResponder is NSTextView 检测——TextField 拿焦点时 field editor
            // (NSTextView)是 firstResponder;否则是 panel / hosting view
            let inputFocused = (event.window?.firstResponder is NSTextView)
            let isSpace = (keyCode == 49)
            // ⌘1 ~ ⌘9 = 直接粘贴 results[N-1](paste-app 风格快捷键)。macOS 数字键
            // keyCode 不连续(1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25),
            // 用 dict 反查。仅 Cmd 修饰键命中时拦截;不带 Cmd 的数字键透传给 TextField
            let cmdDigitPos: Int? = isCmd ? Self.digitKeyMap[keyCode] : nil
            // 点卡 / 点空白摘焦点后,用户打可见字符 → 吃进 query 再 refocus,
            // 把"摘焦点状态下输入"重新引回正常搜索路径。命中条件:
            //   - input 没焦点
            //   - 没 Cmd / Ctrl 修饰键(快捷键不算输入)
            //   - characters 非空 + 单字符 + 非 control char(Tab / Return / Esc 等已在 interceptCodes)
            let isCtrl = event.modifierFlags.contains(.control)
            let printableChar: String? = {
                if inputFocused || isCmd || isCtrl { return nil }
                if interceptCodes.contains(keyCode) || isSpace { return nil }
                guard let chars = event.characters, chars.count == 1 else { return nil }
                guard let scalar = chars.unicodeScalars.first else { return nil }
                // 控制字符(< 0x20)以及 DEL(0x7F)统统跳过——printable 范围是 0x20+ 但
                // space 已上面单独处理过,所以这里取 0x21+
                guard scalar.value >= 0x21 && scalar.value != 0x7F else { return nil }
                return chars
            }()
            guard interceptCodes.contains(keyCode)
                    || isCmdP || isCmdC || isCmdA || isSpace || cmdDigitPos != nil
                    || printableChar != nil else { return event }
            // SwiftUI TextField 编辑时 firstResponder = NSTextField 的 field editor（NSTextView）。
            // hasMarkedText() == true 代表 IME 正在 compose 候选词，所有键都让 IME 自己消费。
            if let tv = event.window?.firstResponder as? NSTextView, tv.hasMarkedText() {
                return event
            }
            // 空格的拦截/透传决定要读 state.previewShown / state.query,因此推到
                // MainActor 闭包内做。其他键统一吞掉(返回 nil),空格走 shouldConsume 分流
            let shouldConsume = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, panel.isKeyWindow else {
                    return false
                }
                // 摘焦点状态下首个可见字符——append 到 query + bump pulse 让
                // SearchView 把 TextField 焦点抢回来,后续字符走正常 TextField 输入
                if let ch = printableChar {
                    self.state.query.append(ch)
                    self.state.inputFocusPulse &+= 1
                    return true
                }
                // slash 补全菜单优先消化 ↑↓/Enter/Esc——必须在卡片导航 / Quick Look /
                // 粘贴路径之前判断,否则补全菜单的方向键会跟卡片导航打架
                if self.state.completionMenuVisible {
                    switch keyCode {
                    case 125, 124:                              // ↓ / →
                        self.state.moveCompletionHighlight(by: 1)
                        return true
                    case 126, 123:                              // ↑ / ←
                        self.state.moveCompletionHighlight(by: -1)
                        return true
                    case 36, 76:                                // Return / Enter
                        self.state.acceptCompletion()
                        return true
                    case 53:                                    // Esc
                        self.state.dismissCompletion()
                        return true
                    default:
                        break
                    }
                }
                // Backspace 在 query 空 + activeQualifiers 非空时弹最后一个 chip。
                // 补全菜单显示时 backspace 透传(让用户改 /xx 输入),不弹 chip。
                // **`!isCmd`** (plan hashed-allen §Step 4):⌘Backspace 是删除选中
                // item 的快捷键(下面 switch 处理),这里必须放行不能吞掉
                if keyCode == 51 && !isCmd {
                    if !self.state.completionMenuVisible
                        && self.state.query.isEmpty
                        && !self.state.activeQualifiers.isEmpty {
                        self.state.popLastQualifier()
                        return true
                    }
                    return false  // 透传给 TextField 正常删字
                }
                switch keyCode {
                case 49:                                        // Space — Quick Look 风格预览
                    FileHandle.standardError.write(Data("preview-debug: SPACE pressed · inputFocused=\(inputFocused) · previewShown=\(self.state.previewShown) · currentItem=\(self.state.currentItem?.id ?? "nil") · rect=\(self.state.selectedCardWindowRect) · query='\(self.state.query)'\n".utf8))
                    if self.state.previewShown {
                        // preview 已开,空格关闭(同时也响应 Esc 路径,但这里更明确)
                        self.state.previewShown = false
                        return true
                    }
                    // input 没焦点(用户点过卡 / 空白)→ 直接 toggle preview,无视 query
                    // 内容。"点击非 input 区域 = 离开编辑状态" 的心智下,空格自然是
                    // Quick Look,不应该被 query 是否空决定
                    if !inputFocused {
                        if self.state.currentItem != nil {
                            self.state.previewShown = true
                            return true
                        }
                        return true                            // 无选中项也消费,避免空格漏到底下
                    }
                    // input 有焦点 + query 非空 → 透传给 TextField 当字面空格,
                    // 让 "ipados news" 这种多词搜索可输入
                    let trimmed = self.state.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty else { return false }
                    if self.state.currentItem != nil {
                        self.state.previewShown = true
                        return true
                    }
                    return false                               // 无选中项(结果空) → 透传
                case 123, 124, 125, 126:                        // ←/→/↑/↓ 切卡
                    // 长按节流:isARepeat=true 事件按 navigateRepeatMinIntervalSec 间隔放行,
                    // 首次按下总是立刻 fire (跟单击一样灵敏)。macOS 默认 key repeat ~30ms
                    // 太快卡片"闪现",节流到 ~22fps 后既流畅又能看清滑过
                    if isARepeat {
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - self.lastNavigateRepeatTime < Self.navigateRepeatMinIntervalSec {
                            return true   // 吃掉这次 repeat 不下推 navigate
                        }
                        self.lastNavigateRepeatTime = now
                    }
                    let delta = (keyCode == 124 || keyCode == 125) ? 1 : -1
                    self.state.navigate(by: delta)
                case 36, 76:                                    // Return / Enter
                    // preview 打开时 Enter 仍粘贴——Quick Look 心智里 Return = 选择/确认
                    // (像 Finder Quick Look: 选中再 Return 打开)。粘贴流程会自然关 panel,
                    // panel.hide() 路径会复位 previewShown,不需要单独清
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
                case 53:                                        // Esc
                    // Esc 优先关 preview(不关 panel)——Finder Quick Look 的标准心智:
                    // QL 开着时 Esc 收回 QL;再按 Esc 才退出选择。这里 preview 关后用户
                    // 可以继续在 panel 内操作,再按 Esc 才真正关 panel
                    if self.state.previewShown {
                        self.state.previewShown = false
                    } else {
                        self.hide()
                    }
                case 35 where isCmd:                            // ⌘P = toggle pin
                    if let item = self.state.currentItem {
                        self.state.togglePin(item)
                    }
                case 8 where isCmd:                             // ⌘C = 复制文本预览选中内容
                    // previewShown=false / preview kind 不是文本 / 无选区 → 透传(返 false)
                    // 让 TextField 保留原生 ⌘C 复制搜索框选中文字的能力
                    guard self.state.previewShown,
                          let text = self.previewController?.selectedPreviewText(),
                          !text.isEmpty else {
                        return false
                    }
                    self.onCopyText?(text)
                    return true
                case 0 where isCmd:                             // ⌘A = 全选预览(文本 / 图片 Live Text)
                    // previewShown=false / 当前 kind 无可选目标 → 透传给搜索框 TextField,
                    // 保留原生 ⌘A 全选搜索框文字。preview 已开时 ⌘A 给预览符合 QuickLook 心智
                    guard self.state.previewShown,
                          self.previewController?.selectAllPreview() == true else {
                        return false
                    }
                    return true
                default:
                    // ⌘1-9 = 直接粘贴 results 前 9 位中第 N 项,不改 selectedIDs。
                    // 越界 (results 不足 N 条) 透传,UI 上对应 ⌘N 角标也不显示
                    if let pos = cmdDigitPos {
                        guard pos - 1 < self.state.results.count else { return false }
                        self.onPaste([self.state.results[pos - 1]])
                        return true
                    }
                    return false
                }
                return true
            }
            return shouldConsume ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    /// 装全局鼠标监听:用户点击我们 app 之外区域(其它 app / 桌面)→ 主动 hide 整个
    /// search panel + preview。global monitor 文档保证只能看到自家 app 之外的事件,
    /// 所以点 search panel / preview panel 内部都不会误触发,无需额外 hit-test。
    /// 跟 windowDidResignKey 互补:那条路径被 previewShown 守卫(防 TCC alert 误关),
    /// 这里覆盖"鼠标主动点外面要退出"的明确意图——TCC alert 是系统弹窗不会派 mouseDown,
    /// 所以两条路径不会冲突
    private func installGlobalClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    private func removeGlobalClickMonitor() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        // Floating island 风格:四周留 margin,四角都圆。早期推过"全宽贴底",但视觉太
        // 重像 Paste.app 老版底栏;改回 floating 让 panel 像独立悬浮卡片。
        // hMargin/vMargin 是 panel 外边距(屏幕边到 panel 边),底部相对 Dock 顶留同
        // 量呼吸。positionBottom 用同一对常量保持单一来源
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let hMargin: CGFloat = Self.panelHMargin
        // header(~56) + filterBar(~32) + ScrollView(254) + 底 padding(16) = 358
        let contentRect = NSRect(
            x: 0, y: 0,
            width: max(640, screenFrame.width - hMargin * 2),
            height: 358
        )
        // borderless 让 window frame 直接 = content rect,setFrameOrigin 设的 y 就是 content
        // 底沿。原 .titled + fullSizeContentView 组合下 window.frame.height = content + 28pt
        // titlebar,setFrameOrigin 让 window 底沿(含 titlebar 下方区)贴 Dock,content 底沿
        // 比 Dock 上沿低 28pt,看着像"panel 没贴 Dock 有缝隙"
        let p = HUDPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false   // 自己控制 hide
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // panel 贴底全宽 + 卡片是主交互区,user 反馈"不应该可以移动"——拖动会让 panel
        // 飘离贴底位置,误操作 + 位置紊乱
        p.isMovableByWindowBackground = false
        p.isMovable = false
        p.delegate = self
        // Spotlight-style 大圆角 + 透明 panel：让 SwiftUI .ultraThickMaterial 背景
        // 配 RoundedRectangle clipShape 自己控制形状；panel 自身透明只用来定位 + 投影。
        // hasShadow=true 时 AppKit 会沿 contentView layer.cornerRadius 形状画系统级 drop shadow。
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        // 预览浮窗 controller——跟搜索 panel 同时创建,锚点指向搜索 panel 自己。
        // SearchView 的 onPreviewChange 闭包驱动它 show/hide;箭头切换 / 滚动让卡片
        // frame 变化时 SwiftUI .onChange 也会回调一次让浮窗 reposition
        let preview = PreviewPanelController(state: state, blobs: state.deps.blobs)
        preview.setAnchor(p)
        self.previewController = preview

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
            },
            onPreviewChange: { [weak self] shown in
                guard let self else { return }
                FileHandle.standardError.write(Data("preview-debug: onPreviewChange(\(shown)) · current=\(self.state.currentItem?.id ?? "nil") · rect=\(self.state.selectedCardWindowRect)\n".utf8))
                if !shown {
                    preview.hide()
                    return
                }
                guard let item = self.state.currentItem else {
                    FileHandle.standardError.write(Data("preview-debug: → hide (no currentItem)\n".utf8))
                    preview.hide()
                    return
                }
                // **P3 修复**: shown=true 但 selectedCardWindowRect == .zero 时不主动 hide——
                // 这通常发生在 previewAnchorID 切换(箭头切卡)瞬间,SearchView 主动 reset
                // 让新卡 frame 到位时再统一 reposition。如果这里走 hide() 浮窗会
                // alphaValue 1→0→1 闪烁;改成保持上一帧状态等新 frame nonzero 时一次性
                // 切换到新 item + 新位置,视觉无中断
                guard self.state.selectedCardWindowRect != .zero else {
                    FileHandle.standardError.write(Data("preview-debug: → wait (rect=.zero)\n".utf8))
                    return
                }
                FileHandle.standardError.write(Data("preview-debug: → show item=\(item.id) rect=\(self.state.selectedCardWindowRect)\n".utf8))
                preview.show(item: item, cardRectInGlobal: self.state.selectedCardWindowRect)
            },
            // contextMenu "在 Finder 显示" + ⌘Return 走同一 onReveal handler
            onReveal: onReveal,
            // contextMenu "打开方式" 子菜单。nil 时 SearchView 自动隐藏该项
            onOpenWith: onOpenWith,
            // 右上角齿轮按钮 → AppDelegate hide panel + showSettings。nil 时 SearchView 不渲染按钮
            onOpenSettings: onOpenSettings
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = contentRect
        hosting.autoresizingMask = [.width, .height]
        // Floating island:四角全圆。panel 四周有 margin,不再有任何一边贴屏幕
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 22
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        // 首次 show 时 SwiftUI `.glassEffect / .ultraThickMaterial` 子层渲染晚于 panel 现身一帧,
        // 期间 wantsLayer=true 后默认 layer.backgroundColor=nil 会让 CA 渲染 fallback 黑色块
        // ("第一次点开搜索框,中间黑影闪烁一下")。显式 .clear 让首帧透明,等 material 接管
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hosting
        // wantsLayer/cornerRadius 后 invalidate 让 shadow 重新按 mask 计算
        p.invalidateShadow()
        // 强制 SwiftUI 跑一次 layout —— 否则 show() 路径 makeKeyAndOrderFront 后 SwiftUI 才
        // 触发首次 layout/render,在 .glassEffect / .ultraThickMaterial 接管前的一两帧空隙里,
        // image kind 卡片的 contentArea 区域露 layer backing store fallback 黑块
        // ("第一次点开搜索框,中部偏左卡片大小黑影闪烁一下")
        hosting.layoutSubtreeIfNeeded()

        panel = p
        freshlyCreated = true
        return p
    }

    private func positionBottom(_ p: NSWindow) {
        p.setFrameOrigin(bottomOrigin())
    }

    /// 计算 panel 贴底浮岛的目标 origin。show 动画起点从 `targetY - 14` 开始上浮到这里;
    /// hide 动画从这里下沉 8pt 同时淡出。`visibleFrame` 已排除 Dock
    private func bottomOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let sFrame = screen.visibleFrame
        return NSPoint(
            x: sFrame.minX + Self.panelHMargin,
            y: sFrame.minY + Self.panelVMargin
        )
    }

    /// Panel 外边距(屏幕边/Dock 顶 → panel 边)。ensurePanel 算 contentRect width 和
    /// positionBottom 设 origin 都用同一对常量,保证 margin 真的对称
    fileprivate static let panelHMargin: CGFloat = 8
    fileprivate static let panelVMargin: CGFloat = 16

    /// macOS keyCode → 数字键面值(1-9)反查表。⌘+N 快捷粘贴用。
    /// 数字键 keyCode 不连续:1=18 2=19 3=20 4=21 5=23 6=22 7=26 8=28 9=25;
    /// 0=29(不映射,paste-app 风格只到 9)
    fileprivate static let digitKeyMap: [Int: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
        22: 6, 26: 7, 28: 8, 25: 9,
    ]

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // preview 打开时**不**自动 hide:空格预览触发的 AVAsset 访问 iCloud / 受限目录
        // 会让 macOS 弹 TCC "允许访问"系统 alert,这个 alert 抢走 panel 的 key 焦点 →
        // windowDidResignKey 立即 hide() 会让 panel + preview 跟 alert 一起消失,用户
        // 还没来得及点"允许"就以为 daemon crash。preview 打开就保留 panel,让 user
        // 主动 Esc 或 space 关。普通 panel(非 preview)时仍按原逻辑——切走自动隐藏
        FileHandle.standardError.write(Data("resign-key: previewShown=\(state.previewShown)\n".utf8))
        if state.previewShown { return }
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

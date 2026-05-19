import AppKit
import Carbon.HIToolbox

/// 模拟 Cmd+V 把当前 NSPasteboard 内容粘到上一个 frontmost app 的输入框。
///
/// 配合 `SearchPanelController.previousFrontmostApp` 快照(panel show 之前抓的目标
/// app)使用——panel 用 .nonactivatingPanel,目标 app 全程保持 frontmost,
/// `target?.activate()` 是兜底:即便我们从未抢过 activation,某些极端 case(panel 关
/// 闭瞬间 Finder 被系统拉前台)仍要保险把目标 app 拉回来。
///
/// **不变量**:
/// 1. AXIsProcessTrusted=false → CGEvent.post 静默无效,pasteboard 已写,用户切回去
///    Cmd+V 仍能粘——graceful degradation,**不阻塞** paste 主路径。**不**主动弹
///    AXIsProcessTrustedWithOptions 那个系统 prompt(体验糟糕且不一定到位),引导通
///    过 Settings 单独按钮去
/// 2. 50ms 延迟:NSPasteboard 写入到对所有 app 可见有 ~30ms 同步窗口(尤其 Electron
///    / web 输入框),50ms 是 Paste.app 经验值。少数 IME composing 中的输入框可能丢
///    首字符——文档化不修
/// 3. `target` 为 nil(panel 从 menubar 触发时 self 是 frontmost,快照排掉了 self pid
///    留 nil)→ 不 post Cmd+V,只写 pasteboard。用户从 menubar 触发本来就不是"粘到
///    某 app",是看历史 / 整理列表
@MainActor
enum PasteInjector {
    /// 调用方:`AppDelegate.pasteBack` 所有写完 NSPasteboard + panel.hide() 之后的成功
    /// 路径。reveal / open-with 路径**不**调(NSWorkspace 接管目标 app)
    static func injectCmdV(into target: NSRunningApplication?) {
        guard let target else { return }
        target.activate()
        Task { @MainActor in
            // 不能在 main 线程 usleep 50ms(panel hide 动画 140ms 同时跑,卡 UI),
            // 用 Task.sleep 让出 main runloop。Task.isCancelled 不检查——panel hide
            // 之后这条任务是 fire-and-forget,Cmd+V 必须 post 到底
            try? await Task.sleep(nanoseconds: 50_000_000)
            postCmdV()
        }
    }

    private static func postCmdV() {
        // .combinedSessionState:同时考虑硬件按键状态 + 软件合成事件状态。若用户此
        // 刻物理按着 Cmd 不放(罕见但 hotkey 路径下用户可能还没松开 ⌥⌘),CGEvent
        // 的 .maskCommand 跟硬件 Cmd 不会叠加成怪状态
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        // .cghidEventTap = HID 事件流最顶端,系统看到的就是用户真按了 Cmd+V。
        // .cgSessionEventTap 在用户态进程层往下注入,部分 sandbox app 收不到
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

import SwiftUI

@main
struct DuoPasteApp: App {
    // CLI 子命令在 SwiftUI 接管 NSApp 之前拦截并 exit；没有子命令时这个 init
    // 直接返回，daemon 流程照常。
    init() {
        CLI.dispatchAndExitIfApplicable()
        SparkleLaunchdHandoff.consumeAndExitIfNeeded()
        // daemon 路径:任何窗口 / 布局出现前装崩溃诊断钩子,把未捕获 ObjC 异常的
        // reason + 栈落盘(.ips 不带 reason、unified log 会滚)。见 CrashDiagnostics。
        CrashDiagnostics.install()
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The daemon owns its Settings NSWindow through SettingsWindowPresenter. This scene only
        // exists to satisfy `SwiftUI.App.body`; registering a second SettingsView here can
        // materialize a duplicate window through the responder chain.
        //
        // It must never produce a window, so a settings-placeholder scene is banned here: even
        // an empty one is a restorable window. With restoration on (`NSQuitAlwaysKeepsWindows=1`,
        // the default) macOS reopened it on every launch as an empty 900x450 "DuoPaste Settings",
        // and — worse — that window took key focus, so the presenter's cooperative-activation
        // handshake never reached key/active, burned its 20 retries, and fell back to
        // `setActivationPolicy(.accessory)`, which hides the app's windows. Net effect: the real
        // Settings window flashed and vanished, and the menu bar shifted as the policy bounced.
        //
        // `MenuBarExtra` with `isInserted: false` renders nothing at all — no window to restore,
        // no key to steal. The real status item is AppKit (`StatusBarController`), so nothing is
        // lost. ⌘, still routes through that status menu into `AppDelegate.showSettings()`.
        MenuBarExtra("duo-paste", isInserted: .constant(false)) { EmptyView() }
    }
}

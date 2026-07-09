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

    // accessory app（无 Dock icon）+ NSApplicationDelegateAdaptor 模式下 SwiftUI `Settings { }`
    // scene 不会注册到标准 `showSettingsWindow:` selector chain——菜单点击没反应。
    // 改由 AppDelegate.showSettings() 手动创建 NSWindow + NSHostingView 持 SettingsView，
    // 完全绕过 SwiftUI Settings scene。
    var body: some Scene {
        Settings { EmptyView() }   // 占位避免 SwiftUI App 协议要求 Scene 非空
    }
}

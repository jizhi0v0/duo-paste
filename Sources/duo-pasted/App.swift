import SwiftUI

@main
struct DuoPasteApp: App {
    // CLI 子命令在 SwiftUI 接管 NSApp 之前拦截并 exit；没有子命令时这个 init
    // 直接返回，daemon 流程照常。
    init() {
        CLI.dispatchAndExitIfApplicable()
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

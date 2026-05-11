import SwiftUI

@main
struct DuoPasteApp: App {
    // CLI 子命令在 SwiftUI 接管 NSApp 之前拦截并 exit；没有子命令时这个 init
    // 直接返回，daemon 流程照常。
    init() {
        CLI.dispatchAndExitIfApplicable()
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

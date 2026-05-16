import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DuoPasteCore

/// 右键 contextMenu 里的 "打开方式" 二级子菜单。按 ItemKind 路由到不同 LaunchServices
/// 查询(text → plainText handler + 编辑器黑名单;url → 浏览器;image/pdf → UTType handler;
/// file 本机存在 → 文件 URL handler),首位是默认 app,末尾是 "其他…" 走 NSOpenPanel。
///
/// **MVP 不显示 app icon**:SwiftUI Menu 在 macOS 上翻译成 NSMenu 时,Button label 里
/// 嵌 NSImage 渲染不可靠(systemImage 可以,NSImage 多半被吞)。要真正显示 app icon
/// 得改用 NSMenu 自管路径,跟 SwiftUI 风格不一致且增加复杂度。后续可单独 follow-up
struct OpenWithMenu: View {
    let item: Item
    /// (item, app bundleURL) → 触发 AppDelegate.openWith。SwiftUI Button action 内调
    let onOpenWith: (Item, URL) -> Void

    @State private var apps: [OpenWithApp] = []
    @State private var loaded: Bool = false

    private var menuTitle: String {
        switch OpenWithProvider.category(for: item) {
        case .textEditor: return "在文本编辑器打开"
        case .browser:    return "在浏览器打开"
        case .viewer, .filePath: return "打开方式"
        }
    }

    var body: some View {
        Menu(menuTitle) {
            menuBody
        }
        .task {
            // .task 在 View 首次出现时跑;contextMenu 第一次展开时 OpenWithMenu 才被
            // 实例化(SwiftUI lazy),所以这里加载 = 用户首次 hover "打开方式" 时
            await loadApps()
        }
    }

    @ViewBuilder
    private var menuBody: some View {
        if !loaded {
            Text("加载中…")
                .disabled(true)
        } else if apps.isEmpty {
            Text("无可用 App")
                .disabled(true)
        } else {
            // default app 首位标 "(默认)" + 分隔线;其余按 LaunchServices 顺序
            let defaultApp = apps.first(where: { $0.isDefault })
            let others = apps.filter { !$0.isDefault }
            if let def = defaultApp {
                Button("\(def.displayName) (默认)") {
                    onOpenWith(item, def.bundleURL)
                }
                if !others.isEmpty {
                    Divider()
                }
            }
            ForEach(others) { app in
                Button(app.displayName) {
                    onOpenWith(item, app.bundleURL)
                }
            }
        }
        Divider()
        Button("其他…") {
            pickOtherApp()
        }
    }

    private func loadApps() async {
        let cat = OpenWithProvider.category(for: item)
        // LaunchServices in-memory cache 首次 cold 50-200ms。Task.detached 让 UI 线程
        // 不卡——Menu 弹出后 SwiftUI 看 loaded=false 显示 "加载中…",再 publish 真实列表
        let loadedApps = await Task.detached(priority: .userInitiated) {
            OpenWithProvider.apps(for: cat)
        }.value
        self.apps = loadedApps
        self.loaded = true
    }

    /// "其他…" → NSOpenPanel 让用户从 /Applications/ 任意挑 app。
    /// runModal() 阻塞当前 main loop,SwiftUI Button action 在 main actor 内调,OK。
    /// 选完不持久化,跟 Finder 标准行为对齐
    @MainActor
    private func pickOtherApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "选择一个 App"
        panel.message = "选择用来打开此项的 App"
        panel.prompt = "选择"
        let response = panel.runModal()
        guard response == .OK, let appURL = panel.url else { return }
        onOpenWith(item, appURL)
    }
}

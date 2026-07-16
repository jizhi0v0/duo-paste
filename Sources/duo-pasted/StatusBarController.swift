import SwiftUI
import DuoPasteCore

/// SwiftUI MenuBarExtra 和 AppDelegate 之间的极小状态桥。
/// Settings 打开动作必须来自 scene environment，不再依赖 AppKit selector。
@MainActor
@Observable
final class StatusBarState {
    static let shared = StatusBarState()

    var hotkey: Config.HotkeyConfig = .default
    var exportProgressText: String?
    @ObservationIgnored var openSettings: OpenSettingsAction?

    private init() {}
}

struct DuoPasteMenuBarExtra: Scene {
    var body: some Scene {
        MenuBarExtra {
            StatusMenu()
        } label: {
            StatusMenuLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct StatusMenuLabel: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: "doc.on.clipboard")
            .accessibilityLabel("duo-paste")
            .onAppear {
                StatusBarState.shared.openSettings = openSettings
            }
    }
}

private struct StatusMenu: View {
    @Bindable private var state = StatusBarState.shared

    var body: some View {
        Button("打开搜索") {
            AppDelegate.shared?.toggleSearch()
        }
        .keyboardShortcut(hotkeyKey, modifiers: hotkeyModifiers)

        Divider()

        Button("设置…") {
            // `.menu` style 的 MenuBarExtra 仍在 AppKit menu tracking loop 里时，
            // SettingsLink 在 LSUIElement/accessory app 上会出现 action 已发送但窗口
            // 没有 order front 的情况。先让菜单 action 返回、菜单完成 dismiss，再走
            // 与搜索窗齿轮相同的 activate + OpenSettingsAction 路径。
            DispatchQueue.main.async {
                AppDelegate.shared?.showSettings()
            }
        }
        .keyboardShortcut(",", modifiers: .command)

        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            Button("检查更新…") {
                UpdaterController.shared.checkForUpdates()
            }
        }

        Button(state.exportProgressText ?? "导出…") {
            if state.exportProgressText == nil {
                AppDelegate.shared?.showExportDialog()
            } else {
                AppDelegate.shared?.cancelExport()
            }
        }

        Divider()

        Button("退出 duo-paste") {
            AppDelegate.shared?.confirmQuit()
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var hotkeyKey: KeyEquivalent {
        KeyEquivalent(Character(state.hotkey.key.lowercased()))
    }

    private var hotkeyModifiers: EventModifiers {
        state.hotkey.modifiers.reduce(into: EventModifiers()) { result, modifier in
            switch modifier.lowercased() {
            case "cmd", "command": result.insert(.command)
            case "option", "alt": result.insert(.option)
            case "control", "ctrl": result.insert(.control)
            case "shift": result.insert(.shift)
            default: break
            }
        }
    }
}

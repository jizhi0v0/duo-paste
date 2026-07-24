import SwiftUI
import AppKit
import DuoPasteCore
import DuoPasteSync

/// Settings 内容。窗口本体(标准 AppKit titlebar / 激活握手 / 跨 Space 前置)由
/// `SettingsWindowPresenter` 托管,这里只管内容:左边分类源列表,右边选中页。
///
/// 布局:原生全高侧边栏(单色符号 + 标题,靠 presenter 的 `.fullSizeContentView` 才是
/// 真 sidebar),右边每页是大标题 + 一叠卡片(见 `SettingsChrome`)。`关于` 之外的页
/// 底部挂 `ApplyBar`。
struct SettingsView: View {
    @State private var model = SettingsModel()
    /// optional 是 `List(selection:)` 单选的惯例形态(`Binding<SelectionValue?>`),旧实现
    /// 也是这么写的,`SettingsWindowPresentationTests` 里那条 sidebar 契约同样按这个形状
    /// 断言。非 optional 能编译过,但没必要偏离标准用法。
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            // 560 是窄屏契约:presenter 按 min(760, 可见区) 收窗口,712pt 宽的缩放屏上
            // 可用内容宽 ~680 —— 内容的 min 必须留在它下面,否则窗口被顶出屏幕。
            minWidth: 560,
            idealWidth: 760,
            maxWidth: .infinity,
            minHeight: 420,
            idealHeight: 620,
            maxHeight: .infinity
        )
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        List(SettingsPane.allCases, selection: $pane) { pane in
            Label {
                Text(pane.title)
            } icon: {
                SettingsPaneIcon(pane: pane)
            }
            .tag(pane)
            .padding(.vertical, 2)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 190)
        .softScrollEdges()
        .accessibilityLabel("设置分类")
    }

    // MARK: - 详情

    private var detail: some View {
        let current = pane ?? .general
        return page(for: current)
            // ApplyBar 只在有改动 / 有状态消息时出现;`关于` 页没有可编辑 config。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if current.editsConfig && (model.isDirty || model.statusMessage != nil) {
                    ApplyBar(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.18), value: model.isDirty)
            .animation(.smooth(duration: 0.18), value: model.statusMessage)
            .animation(.smooth(duration: 0.28), value: pane)
            .onChange(of: model.isDirty) { _, newValue in
                if newValue { model.notifyConfigEdited() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func page(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(model: model, appState: AppDelegate.shared?.state)
        case .ocr:     OCRPane(model: model)
        case .about:   AboutPane()
        }
    }
}

import SwiftUI

struct GlassActionButton: View {
    let title: String
    let isProminent: Bool
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .modifier(NativeGlassButtonChrome(isProminent: isProminent))
            .disabled(isDisabled)
    }
}

/// Settings 里所有独立 action button 的单点样式契约。
///
/// **prominent 走 Liquid Glass(`.glassProminent`),非 prominent 一律 `.bordered`。**
/// 不是审美选择,是 `.buttonStyle(.glass)` 在 Settings 窗口里**渲染坏了**:macOS 27.0
/// beta(26A5378n)实测,非 prominent 的玻璃按钮会把 label 整个吞掉,只剩一块空灰圆角块
/// ——"重新检查"/"添加"/"重建本机 OCR 索引"这些按钮全都没字。`.glassProminent` 不受影响。
///
/// **不要**把这条推广成"这个窗口用不了 Liquid Glass"。这段注释以前把根因归给"不透明
/// 窗口没有可采样背景",那是错的:`SettingsChrome.floatingBarBackground()` 在同一个窗口里
/// 用 `.glassEffect(.regular, in:)` 渲染完全正常(底下卡片正常透出虚化)。坏的只是
/// `.buttonStyle(.glass)` 这一个 style。卡片背景留 material 是**设计选择**(内容背景不该
/// 是玻璃),跟这条 bug 无关,两者不要一起回退。
///
/// Apple 修好之后,把 `.bordered` 换回 `.buttonStyle(.glass)` 即可(先在真机确认按钮有字)。
struct NativeGlassButtonChrome: ViewModifier {
    let isProminent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), isProminent {
            content
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
        } else if isProminent {
            content
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// 二态选择按钮。选中态用 `.glassProminent`(macOS 26+):`.glass(.regular.tint(...))`
/// 渲染成近乎无色的普通玻璃,深色模式下看不出哪个被选中。
///
/// **未选中态一律 `.bordered`**,理由同 `NativeGlassButtonChrome`:`.buttonStyle(.glass)`
/// 在这个不透明窗口里把 label 吞掉,"按需拉取"/"fast" 会变成没字的空灰块。
///
/// 固定外层高度消除两种 style 的 intrinsic padding 差异。
struct GlassChoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *), isSelected {
            button
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
                .frame(height: 28)
        } else if isSelected {
            button
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .frame(height: 28)
        } else {
            button
                .buttonStyle(.bordered)
                .frame(height: 28)
        }
    }

    private var button: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }
}

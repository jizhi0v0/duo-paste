import SwiftUI

/// Settings 的统一外壳:页面骨架 + 卡片 + 行样式。三个 pane 只声明 `SettingsCard { … }`。
///
/// 卡片底板用 material 而**不是** Liquid Glass——原因写在 `settingsCardBackground()`
/// 上(不透明窗口里玻璃合成是坏的,且玻璃本就不该做内容背景)。按钮样式仍然**只**走
/// `NativeGlassButtonChrome` / `GlassActionButton`,这里不造第二套按钮契约。

// MARK: - 度量

enum SettingsMetrics {
    /// 卡片圆角。跟 macOS 26 窗口圆角同心。
    static let cardRadius: CGFloat = 14
    /// 卡片间距。
    static let cardSpacing: CGFloat = 18
    /// 单页可读宽度。窗口再宽也是加 padding,不把内容拉长。
    static let contentWidth: CGFloat = 560
}

// MARK: - 页面骨架

/// 一个 settings pane:大标题 + 副标题 + 一叠卡片,套在 ScrollView 里。
/// pane 只负责给卡片。
struct SettingsPage<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            cards
                .frame(maxWidth: SettingsMetrics.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .softScrollEdges()
    }

    private var cards: some View {
        // 这里曾经套了一层 GlassEffectContainer(合并相邻卡片的玻璃)。卡片改回 material
        // 之后已经没有 glassEffect 子视图可合并,容器就是个纯摆设,故去掉。
        // 见 `settingsCardBackground()` 里为什么不用玻璃。
        VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
            header
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pane.title)
                .font(.system(.title2, weight: .semibold))
            Text(pane.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

}

// MARK: - 卡片

/// 一组行放在一块板子上——pane 的基本积木。`header` 在板子上方,`footer` 在下方,
/// 都在板子**外面**:长说明文字当正文读,不挤在卡片里。
struct SettingsCard<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content

    /// footer 需要 Label / 实时警告而不是死字符串时用这个。
    private var footerView: AnyView?

    init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.footerView = nil
        self.content = content()
    }

    init(header: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> some View) {
        self.header = header
        self.footer = nil
        self.footerView = AnyView(footer())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                Text(header)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsCardBackground()

            if let footer {
                SettingsFootnote(footer)
            } else if let footerView {
                footerView
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// 卡片下方的说明文字。也可以脱离卡片单独用。
struct SettingsFootnote: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

// MARK: - 分隔线

/// 卡片内行与行之间的分隔线。
///
/// 不用裸 `Divider()`:它在 material 卡片上淡到几乎看不见,而且会一路顶到卡片左右边缘。
/// 原生分组的分隔线是**从标题文字的左边缘起**(所以这里 leading inset 跟 `settingsRow()`
/// 的水平内边距一致)、右侧到底,并且比 `Divider()` 实一点。
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

// MARK: - 行

extension View {
    /// 卡片内单行的标准内边距。行与行之间由调用处显式 `SettingsDivider()` 分隔。
    func settingsRow() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 卡片底板。**刻意用 material,不用 `.glassEffect`** —— 两条理由,一条实测一条设计:
    ///
    /// 1. **实测(macOS 27.0 beta 26A5378n)**:Liquid Glass 在 Settings 这种**不透明**窗口
    ///    里渲染是坏的。`content.glassEffect(...)` 把内容本身变成玻璃 → 整张卡片是块空灰板;
    ///    改成 `.background(Color.clear.glassEffect(...))`(即 `SearchView` 那个写法)内容
    ///    回来了但**整片被玻璃层糊住**。`SearchView` 的浮岛能用,是因为那个 panel 是
    ///    `isOpaque=false + bg=.clear` 的透明窗口 —— 玻璃有东西可采样。presenter 托管的
    ///    Settings 是标准不透明 titled window,没有这个条件。
    /// 2. **设计**:Apple 自己的规范里 Liquid Glass 是给浮动/导航层的,不是给内容背景的;
    ///    系统设置的分组内容本来就是 material。
    ///
    /// 玻璃保留在它**能正常工作**的地方:`.glassProminent` 按钮(见 `GlassButtons.swift`)、
    /// 以及浮动动作条(见 `floatingBarBackground()`)。
    ///
    /// **订正**:这段注释原本把根因写成"不透明窗口里 Liquid Glass 没有可采样的背景所以
    /// 渲染异常"。那个解释是错的——`floatingBarBackground()` 在**同一个**不透明窗口里用
    /// `.glassEffect(.regular, in:)` 渲染完全正常,底下的卡片正常透出并虚化。坏的是
    /// 「拿玻璃当**内容**背景」和 `.buttonStyle(.glass)` 这两个具体用法,不是这个窗口。
    /// 所以这里留 material 现在是**设计选择**(内容背景本就不该是玻璃,系统设置也是
    /// material),不是在等 Apple 修 bug。
    func settingsCardBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
        return self
            .background(.thinMaterial, in: shape)
            .overlay { shape.strokeBorder(.separator.opacity(0.45), lineWidth: 0.5) }
    }

    /// 浮动动作条(`ApplyBar`)的底板。**这里用 Liquid Glass 是对的**,跟卡片背景不一样:
    /// 玻璃在 Apple 的规范里就是给浮动/导航层用的——它悬在内容之上、需要透出下面滚动的
    /// 卡片,正是玻璃要表达的层次。卡片背景则是内容本身,那里必须留 material
    /// (见 `settingsCardBackground()`)。
    ///
    /// 旧版是 `.background(.bar)` 满宽实心条,跟窗口底边焊死,读起来像内容的一部分。
    func floatingBarBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return self.modifier(FloatingBarChrome(shape: shape))
    }

    /// macOS 26 让滚动内容在窗口边缘柔化,而不是硬切在标题栏上。
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

/// `floatingBarBackground()` 的实现。macOS 26 走原生 `.glassEffect`,旧系统退到 material。
///
/// 注意跟 `NativeGlassButtonChrome` 那条坑的区别:坏掉的是 `.buttonStyle(.glass)`(吞 label)
/// 和拿玻璃当**内容**背景,不是 `.glassEffect` 本身。这里是浮层,实测正常。
private struct FloatingBarChrome<S: InsettableShape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
    }
}

/// 左标题(可带副标题) + 右任意控件。等价于旧的 `SettingsRow`,但不依赖 Form 的
/// `LabeledContent` 对齐——卡片布局里 Form 那套对齐会失效。
struct SettingsField<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .settingsRow()
    }
}

/// 开关行——duo-paste 里最常见的一种 `SettingsField`,省掉每处重复
/// `.labelsHidden().toggleStyle(.switch)`。
struct SettingsToggleField: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsField(title: title, detail: detail) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

// MARK: - 侧边栏图标

/// 侧边栏行的图标:**单色 SF Symbol**,跟 Mail / Notes / Finder 以及本机 DuoTerminal
/// 设置窗口的原生 sidebar 一致。
///
/// 曾经是系统设置那种彩色圆角块(`RoundedRectangle` + tint + 白符号)。系统设置确实那么
/// 做,但那是它自己的一套;放在这里跟同机其他 app 的 sidebar 不是一个长相。固定宽度让
/// 三行的标题左边缘对齐。
struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.icon)
            .frame(width: 18)
    }
}

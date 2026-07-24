import SwiftUI

/// 详情页底部的动作条：状态消息 + 恢复/应用，OCR 改动时还会多一段半致状态警告。
///
/// ## 这里**绝对不要**加 `.fixedSize(horizontal: false, vertical: true)`
///
/// 警告那行文字曾经带 `.fixedSize(horizontal: false, vertical: true)`（多行文字防截断的
/// 常规写法）。放在**别处**没问题——`SettingsChrome` 里的 footnote / field detail 都在
/// ScrollView 的滚动内容里，高度本来就不受限。但这个 bar 是 `SettingsView.detail` 的
/// `.safeAreaInset(edge: .bottom)` 内容，它参与容器的**最小高度**计算。
///
/// `fixedSize(vertical:)` 的语义是"把理想高度同时当成最小和最大"——也就是让这个视图在
/// 垂直方向**变刚性**。刚性从警告文字传导到 bar，再传导到 detail：detail 的最小高度变成
/// 「整页内容 + bar」。而 `.frame(maxHeight: .infinity)` **只能限制最大值，压不下内容的
/// 最小值**，于是 detail 无视窗口给的 620，直接解析成自己的内容高度，NavigationSplitView
/// 跟着一起涨，超出 NSHostingView 后被居中裁剪——上下各切掉一半。
///
/// 症状不长在这个文件上，所以很难联想过来：侧边栏三行整个消失（它们在被裁掉的顶部
/// ~100pt 里）、页面大标题被顶到标题栏上面跟窗口标题叠字、bar 自己反而看不见（被裁到
/// 底部外面）。实测数字（760x620 窗口，OCR 页 + dirty）：
///
/// | | ApplyBar | detail | sidebar |
/// |---|---|---|---|
/// | 带 fixedSize | 591x74 | 591x**1306** | 168x**1306** |
/// | 不带 | 591x74 | 591x**568** ✓ | 168x**568** ✓ |
///
/// bar 高度**一样是 74**，文字**一样完整换行不截断**——`fixedSize` 在这里只贡献了那个
/// 刚性，没有任何视觉收益。注意 1306 = OCR 页内容 1232 + bar 74，也就是"detail 取了自己
/// 内容的高度"，这是识别这条 bug 的指纹。
///
/// 排查过程里被证伪的方向（别再走一遍）：`NSHostingController.sizingOptions`（无关，但
/// 保留 `[]` 是对的，它另外挡住了窗口从 620 长到 672）、`NSHostingView.sizingOptions`、
/// `.safeAreaInset` 换 VStack、`.softScrollEdges()`、给文字限宽——全都不是。
struct ApplyBar: View {
    @Bindable var model: SettingsModel

    var body: some View {
        // alignment 必须是 .trailing:按钮行永远靠右。VStack 用 .leading 时,警告文字会把
        // stack 撑满宽,按钮行就跟着贴到左边——于是"有警告时按钮在左、没警告时在右"。
        VStack(alignment: .trailing, spacing: 6) {
            if showOCRHalfConsistencyWarning {
                // 见上：不要 .fixedSize —— 没有它文字照样完整换行。
                Text(ocrHalfConsistencyWarningText)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            HStack(spacing: 8) {
                if let msg = model.statusMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(model.statusIsError ? Color.red : Color.green)
                        .lineLimit(2)
                }
                if !model.isDirty && model.statusMessage != nil && needsRestartHint {
                    GlassActionButton(title: "重启", isProminent: false) { model.restartDaemon() }
                }
                GlassActionButton(title: "恢复", isProminent: false, isDisabled: !model.isDirty) { model.discard() }
                GlassActionButton(title: "应用", isProminent: true, isDisabled: !model.isDirty) { model.apply() }
                    .keyboardShortcut(.return)
            }
        }
        // 内边距在玻璃**里面**,外边距在玻璃**外面**——后者就是"浮起来"的那圈间隙。
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingBarBackground()
        // 撑满宽度的 frame 必须在玻璃**之后**:玻璃只包住内容,于是这条按内容收缩——
        // 只有两个按钮时是右下角一颗药丸,带警告文字时自然撑开成一条。要是放在玻璃
        // 之前,没警告的时候就是一整块空玻璃板配两个小按钮,底下的正文还从空处透出来。
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    /// OCR 字段 dirty 且本机已有 OCR 结果(pending 在跑 / done 历史)时弹警告。
    /// 用户改完语言/精度按"应用"前先看到提示。
    /// **必须**也覆盖 pending=0 / done>0 这条稳态——历史 done 仍按旧配置编出来,
    /// 改配置不会自动重 OCR,这才是 PR 要解决的核心半致状态。
    private var showOCRHalfConsistencyWarning: Bool {
        guard model.ocrFieldsDirty else { return false }
        guard let s = model.ocrStats else { return false }
        return s.pending > 0 || s.done > 0
    }

    private var ocrHalfConsistencyWarningText: String {
        let pending = model.ocrStats?.pending ?? 0
        let done = model.ocrStats?.done ?? 0
        if pending > 0 {
            return "⚠ OCR 队列剩 \(pending) 张待处理(另有 \(done) 张历史已完成)。应用后 worker 会用新配置跑剩下的图片,历史已完成的图片保持旧配置 → 半致状态。建议先到「本机索引状态」点「中止当前队列」清场,应用并重启 daemon 后再点「重建本机 OCR 索引」对齐。"
        } else {
            return "⚠ 本机已有 \(done) 张 OCR 结果按旧配置生成。应用后新图片走新配置,历史结果保持旧配置 → 半致状态。建议应用并重启 daemon 后到「本机索引状态」点「重建本机 OCR 索引」让历史也对齐。"
        }
    }

    private var needsRestartHint: Bool {
        model.statusMessage?.contains("重启") ?? false
    }
}

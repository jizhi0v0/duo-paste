import SwiftUI
import DuoPasteCore
import DuoPasteSync

@MainActor private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    // .named → 极近时间显示 "now"，避免 RelativeDateTimeFormatter 默认的 "in 0 sec." 反向前缀
    f.dateTimeStyle = .named
    return f
}()

struct SearchView: View {
    @Bindable var state: AppState
    var onPaste: (Item) -> Void
    var onClose: () -> Void

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            modeBanner
            Divider()
            if state.results.isEmpty {
                emptyView
            } else {
                list
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 480)
        .background(.thinMaterial)
        .task(id: state.query) {
            await state.refresh()
        }
        .onAppear {
            searchFieldFocused = true
            Task { await state.refresh() }
        }
        // 注：箭头 / Return / Esc 由 SearchPanelController 的 NSEvent local monitor
        // 截下来直接调 state.navigate / onPaste，绕过 SwiftUI TextField 对箭头键的吞噬。
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板历史", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($searchFieldFocused)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("\(state.results.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 顶部 banner：standalone / 远端 OK 时不显示；远端 fallback 时黄色提示。
    @ViewBuilder
    private var modeBanner: some View {
        if case .remoteFallback(let reason) = state.searchMode {
            HStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark")
                Text("primary 离线，使用本地结果")
                Text("·").foregroundStyle(.secondary)
                Text(reason).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15))
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(state.query.isEmpty ? "还没有任何剪贴板历史" : "无匹配结果")
                .foregroundStyle(.secondary)
            if let err = state.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.results) { item in
                        ItemRow(
                            item: item,
                            isSelected: item.id == state.selectedID,
                            snippet: state.snippets[item.id]
                        )
                        .contentShape(Rectangle())
                        .id(item.id)
                        // 双击粘贴。挂 .gesture（参与消歧），让双击能稳定识别。
                        .gesture(
                            TapGesture(count: 2).onEnded {
                                onPaste(item)
                            }
                        )
                        // 单击仅改 selection，挂 .simultaneousGesture 跳出消歧、立即触发，
                        // 不会被双击监听拖到 500ms 之后。
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                state.selectedID = item.id
                            }
                        )
                    }
                }
            }
            // 只在键盘导航（scrollPulse 改变）时滚动到选中项，鼠标点击不触发
            .onChange(of: state.scrollPulse) { _, _ in
                if let id = state.selectedID {
                    withAnimation(.linear(duration: 0.08)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct ItemRow: View {
    let item: Item
    let isSelected: Bool
    /// 含 STX/ETX 高亮标记的 FTS snippet。仅 query 非空 + 命中时非 nil。
    let snippet: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .frame(width: 22, height: 22)
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                previewText
                    .lineLimit(2)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : .primary)
                HStack(spacing: 6) {
                    Text(item.sourceAppName ?? item.sourceApp ?? "?")
                    Text("·")
                    // TimelineView 周期重绘，否则 row 稳定后 Date() 不会被重算，
                    // 相对时间永远停在初次渲染的瞬间。
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(relativeFormatter.localizedString(for: capturedDate, relativeTo: ctx.date))
                    }
                    if item.kind == .image, let size = item.blobSize {
                        Text("·")
                        Text(humanSize(size))
                    }
                }
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor : Color.clear)
    }

    private var iconName: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .rtf: "doc.richtext"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }

    private var capturedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(item.capturedAtNs) / 1_000_000_000)
    }

    /// 优先用 snippet（FTS 命中片段，匹配词加粗），否则回退到 preview。
    /// snippet 用 STX/ETX 做标记：拆成 plain / bold 交替的 Text 链。
    /// 注意返回类型 `Text`（不能用 @ViewBuilder 的 _ConditionalContent，要支持
    /// `.lineLimit(2)` 这类只对 Text 生效的修饰）
    private var previewText: Text {
        if let s = snippet, !s.isEmpty {
            return highlightedText(from: s)
        }
        return Text(item.preview ?? "")
    }

    private func highlightedText(from snippet: String) -> Text {
        // snippet 形如 "abc \u{02}match\u{03} def \u{02}more\u{03} ghi"
        var result = Text("")
        var rest = snippet[...]
        while let startRange = rest.range(of: "\u{02}") {
            let beforeStart = rest[..<startRange.lowerBound]
            result = result + Text(String(beforeStart))
            let afterStart = rest[startRange.upperBound...]
            if let endRange = afterStart.range(of: "\u{03}") {
                let matched = afterStart[..<endRange.lowerBound]
                result = result + Text(String(matched)).bold()
                rest = afterStart[endRange.upperBound...]
            } else {
                // 没找到收尾 marker——把剩下的全当 plain（防御性，不应发生）
                result = result + Text(String(afterStart))
                rest = ""[...]
                break
            }
        }
        if !rest.isEmpty {
            result = result + Text(String(rest))
        }
        return result
    }

    private func humanSize(_ size: Int64) -> String {
        let kb = Double(size) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

import SwiftUI
import AppKit
import DuoPasteCore
import DuoPasteSync

@MainActor private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    // .named → 极近时间显示 "now"，避免 RelativeDateTimeFormatter 默认的 "in 0 sec." 反向前缀
    f.dateTimeStyle = .named
    return f
}()

/// 按 bundleID → app icon 的进程内 LRU-less 缓存。
/// NSWorkspace.icon(forFile:) 每次都 IO 一次（读 Info.plist + .icns），row 渲染时不能每次重算。
/// 没装的 bundleID（mirror 来的对端独有 app）会进 notFound 集合避免反复查 LaunchServices。
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]
    private var notFound: Set<String> = []

    /// 系统组件 bundleID 黑名单——LaunchServices 给得出 icon，但不代表真实"来源 app"。
    /// 已知触发场景：mini 屏幕锁着 / 无人前台时，NSWorkspace.frontmostApplication 报
    /// `com.apple.loginwindow`，而 loginwindow.app 自带 icon 是张白色网格占位图，UI 上很丑。
    /// 命中直接返 nil，走 SF Symbol fallback。
    private static let nonAppBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.WindowServer",
        "com.apple.dock",
    ]

    func icon(forBundleID bid: String) -> NSImage? {
        if Self.nonAppBundleIDs.contains(bid) { return nil }
        if let img = cache[bid] { return img }
        if notFound.contains(bid) { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let img = NSWorkspace.shared.icon(forFile: url.path)
            cache[bid] = img
            return img
        }
        notFound.insert(bid)
        return nil
    }
}

struct SearchView: View {
    @Bindable var state: AppState
    var onPaste: (Item) -> Void
    var onClose: () -> Void

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            noticeBanner
            pasteProgressBanner
            skipBanner
            modeBanner
            clockSkewBanner
            // Spotlight 风格不要硬 Divider，用一条细发丝线代替
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 14)
            if state.results.isEmpty {
                emptyView
            } else {
                list
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 400, idealHeight: 520)
        // Spotlight-style 玻璃：.ultraThickMaterial 比 .thinMaterial 更不透明、更"深色玻璃"质感。
        // clipShape 把 hosting view 内容裁成 22pt 大圆角（跟 SearchPanelController 里 layer.cornerRadius 一致）。
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            // 0.5pt hairline 描边——dark mode 下让圆角边缘比 material 更清晰
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        // 让内容延伸到 NSPanel titlebar 区域（fullSizeContentView 把 contentView 占位让出来，
        // 但 SwiftUI 默认仍把 titlebar 计入 top safe area，所以 header 上方会留 ~28pt 空白）
        .ignoresSafeArea()
        // debounce 100ms：用户连打 / 切 chip 时上一个 task 被 .task(id:) cancel 掉，新 task
        // 先 sleep 100ms 再 refresh。停手 100ms 后才真正发远端请求——10 次按键的
        // 远端 roundtrip 合并成 1 次。CancellationError 自然吞掉。
        // id 用 filterID（query + kinds + timeRange 联合指纹），任一维度变化都触发新 fetch
        .task(id: state.filterID) {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                await state.refresh()
            } catch {
                // 被取消（用户继续打字 / 改筛选）→ 让下一个 task 接手，啥也不做
            }
        }
        .onAppear {
            searchFieldFocused = true
            // onAppear 时不 debounce——首次打开应当立刻 refresh
            Task { await state.refresh() }
        }
        // panel 被复用（orderOut 不销毁 hosting view），每次 show() bump openPulse
        // → 这里把焦点抢回 TextField + 立即 refresh，避免 reshow 时光标不见 / 看到 stale results
        .onChange(of: state.openPulse) { _, _ in
            // panel 复用：上次 hide 不会重置 @FocusState，再赋 true 是无效赋值，
            // 光标不会重新装回 field editor（表现为没有闪烁的输入提示）。
            // 先掀掉再下一 runloop 装回，强制 SwiftUI 走一次 focus 变化。
            searchFieldFocused = false
            DispatchQueue.main.async {
                searchFieldFocused = true
            }
            Task { await state.refresh() }
        }
        // 注：箭头 / Return / Esc 由 SearchPanelController 的 NSEvent local monitor
        // 截下来直接调 state.navigate / onPaste，绕过 SwiftUI TextField 对箭头键的吞噬。
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板历史", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFieldFocused)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("\(state.totalCount) 条")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    /// 类型 chip 行 + 时间窗下拉。
    ///
    /// - 类型 chip 多选：空 = 全部（不带 IN 过滤）。pill 风格，选中状态 accent 填充
    /// - 时间窗放右侧 Menu：单选「全部 / 24h / 7d / 30d」
    ///
    /// chip 顺序按 ItemKind 出现频次手排（text 最常用 → 排最左），不按 enum 声明序。
    /// 改 chip 时不要按 ItemKind.allCases 遍历——枚举序 (text/rtf/html/url/image/file)
    /// 把 rtf/html 推到前面会让用户每次都要扫过去找"图片"
    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(filterChipKinds, id: \.self) { kind in
                // 契约：空 dict（remoteOK / 出错）→ nil 隐藏数字；非空 dict（local /
                // unionLocal 路径）→ 缺 key 默认 0 显示 "图片 0"。这样 KindChip 头注释
                // 的 "0 也显示" 才真生效，否则缺 key 时跟 "远端未知" 撞同一种 nil 渲染。
                KindChip(
                    kind: kind,
                    isSelected: state.selectedKinds.contains(kind),
                    count: state.kindCounts.isEmpty ? nil : (state.kindCounts[kind] ?? 0),
                    onTap: { toggleKind(kind) }
                )
            }
            if !state.selectedKinds.isEmpty {
                Button {
                    state.selectedKinds.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除类型筛选")
            }
            pinnedOnlyChip
            Spacer()
            timeRangeMenu
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    /// 「仅置顶」开关——风格跟 KindChip 一致，但单 chip 即开关，不带 ✕
    private var pinnedOnlyChip: some View {
        Button {
            state.pinnedOnly.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                Text("仅置顶")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(state.pinnedOnly ? Color.white : .primary)
            .background(
                Capsule()
                    .fill(state.pinnedOnly ? Color.accentColor : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    /// chip 排列顺序：剪贴板使用频次心智（文本/图片/链接最常用 → 排前面）
    private var filterChipKinds: [ItemKind] {
        [.text, .image, .url, .file, .rtf, .html]
    }

    private func toggleKind(_ kind: ItemKind) {
        if state.selectedKinds.contains(kind) {
            state.selectedKinds.remove(kind)
        } else {
            state.selectedKinds.insert(kind)
        }
    }

    private var timeRangeMenu: some View {
        Menu {
            ForEach(AppState.TimeRange.allCases) { range in
                Button {
                    state.timeRange = range
                } label: {
                    if state.timeRange == range {
                        Label(range.label, systemImage: "checkmark")
                    } else {
                        Text(range.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                Text(state.timeRange.label)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(state.timeRange == .all ? .secondary : Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(state.timeRange == .all ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.15))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 一次性 notice（pin mirror 行被拒等）。文案 3s 自动消失（AppState 控制）。
    /// 跟 skipBanner 区分：notice 是即时操作反馈（按 ⌘P 没生效原因），
    /// skipBanner 是后台 capture 事件（用户没看 panel 时也会塞进来）。
    @ViewBuilder
    private var noticeBanner: some View {
        if let text = state.recentNotice {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(text)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
        }
    }

    /// 体积超限 banner：5 分钟内有 skip → 黄色提示「最近一次复制太大没存」。
    /// ✕ 可关；不持久化，重启就清。这是 capture cap 的可见出口——光 stderr log
    /// 用户感知不到，会以为"daemon 挂了 / bug"。
    @ViewBuilder
    private var skipBanner: some View {
        if let skip = state.recentSkip,
           Date().timeIntervalSince(skip.occurredAt) < 300 {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                Text(skipDescription(skip))
                Spacer()
                Button {
                    state.dismissSkip()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.18))
        }
    }

    /// blob 懒拉过程中的状态条：
    /// - `.idle` → 不显示
    /// - `.fetching` → 蓝色 spinner + "拉取图片…"（含 sizeHint 可知时）
    /// - `.failed` → 红色 banner 显示错误文案；Esc 关闭 panel 或 Enter 重试由 key monitor 处理
    @ViewBuilder
    private var pasteProgressBanner: some View {
        switch state.pasteProgress {
        case .idle:
            EmptyView()
        case .fetching(_, let sizeHint):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                if let s = sizeHint, s > 0 {
                    Text("拉取图片字节（约 \(humanBytes(Int(s)))）…")
                } else {
                    Text("拉取图片字节…")
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.15))
        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text("图片粘贴失败：\(reason)")
                Spacer()
                Button {
                    state.pasteProgress = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.18))
        }
    }

    private func skipDescription(_ s: AppState.SkipNotice) -> String {
        let kindLabel = s.kind == .blob ? "图片/文件" : "文本"
        return "刚才有一段\(kindLabel)太大没入库（\(humanBytes(s.bytes)) > \(humanBytes(s.limit))）；剪贴板本身正常，可直接 Cmd+V 粘贴"
    }

    private func humanBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    /// 顶部 banner：
    /// - `.local` / `.remoteOK` → 不显示（默认顺畅状态）
    /// - `.localMirror` → 稳态隐藏；staleness 超阈值（5 分钟）才以黄色显示「镜像卡顿」
    ///   pull interval 默认 30s，稳态 staleness 应在 0-60s 之间。超过 300s 说明 pull worker
    ///   卡死 / primary 不可达 / 时钟漂移，这时才有告知价值
    /// - `.remoteFallback` → 黄色提示 primary 离线
    @ViewBuilder
    private var modeBanner: some View {
        switch state.searchMode {
        case .localMirror(let stalenessSec) where stalenessSec > 300:
            HStack(spacing: 6) {
                Image(systemName: "internaldrive.badge.exclamationmark")
                Text("本地镜像更新滞后")
                Text("·").foregroundStyle(.secondary)
                Text("已 \(humanStaleness(stalenessSec)) 未同步").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15))
        case .localMirror:
            EmptyView()
        case .remoteFallback(let reason):
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
        case .local, .remoteOK:
            EmptyView()
        }
    }

    /// 时钟偏移 banner：|skew| 超过阈值才显示。HMAC 签名容忍 ±5 分钟 skew，所以这是早期预警：
    /// 用户能看到偏移大小 → 提示去 NTP / sleep 设置排查，免得后面收到 401 才找原因。
    @ViewBuilder
    private var clockSkewBanner: some View {
        if let skew = state.clockSkewMs, abs(skew) >= state.clockSkewWarnMs {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark")
                Text("时钟偏移：primary 比本机\(skew > 0 ? "快" : "慢") \(humanSkew(abs(skew)))")
                Text("·").foregroundStyle(.secondary)
                Text("接近 5 分钟会签名失败").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15))
        }
    }

    private func humanSkew(_ ms: Int64) -> String {
        if ms < 1_000 { return "\(ms)ms" }
        let sec = ms / 1_000
        if sec < 60 { return "\(sec)s" }
        return "\(sec / 60)m\(sec % 60)s"
    }

    private func humanStaleness(_ sec: Int) -> String {
        if sec < 60 { return "\(sec)s" }
        if sec < 3600 { return "\(sec / 60)m" }
        return "\(sec / 3600)h"
    }

    private var emptyView: some View {
        // 区分两个语义：库里真空（首次安装）vs 当前筛选导致空。后者只要 query / kinds /
        // timeRange / pinnedOnly 任一非默认就成立——文案不同避免用户误以为 daemon 挂了
        let hasActiveFilter = !state.query.isEmpty
            || !state.selectedKinds.isEmpty
            || state.timeRange != .all
            || state.pinnedOnly
        return VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(hasActiveFilter ? "当前筛选无结果" : "还没有任何剪贴板历史")
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
                LazyVStack(spacing: 2) {
                    Color.clear.frame(height: 6)  // 列表顶部留点空气
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

/// 类型 chip 单元。pill capsule，选中状态 accent 填充 + 白字。
/// 单击 toggle 选中状态。视觉跟 timeRangeMenu 的 capsule 保持一致——padding / radius 同步
///
/// `count` 非 nil 时尾巴挂活计数 "图片 19"——让用户立刻看出哪个类稀疏。
/// 0 也显示（"图片 0"），避免用户误以为 filter 失效；nil = 远端模式拿不到时隐藏。
/// nil/0 的区分发生在 caller：空 kindCounts dict（remoteOK / 出错）→ nil；非空 dict
/// （本地有命中）→ 缺 key 默认 0。
private struct KindChip: View {
    let kind: ItemKind
    let isSelected: Bool
    let count: Int?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : .primary)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var label: String {
        switch kind {
        case .text: "文本"
        case .rtf: "富文本"
        case .html: "HTML"
        case .url: "链接"
        case .image: "图片"
        case .file: "文件"
        }
    }

    private var symbol: String {
        switch kind {
        case .text: "text.alignleft"
        case .rtf: "doc.richtext"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

private struct ItemRow: View {
    let item: Item
    let isSelected: Bool
    /// 含 STX/ETX 高亮标记的 FTS snippet。仅 query 非空 + 命中时非 nil。
    let snippet: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            leadingIcon
            VStack(alignment: .leading, spacing: 3) {
                previewText
                    .lineLimit(2)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.white : .primary)
                HStack(spacing: 6) {
                    Text(kindLabel)
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
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
            Spacer()
            if item.pinned {
                // 已置顶 row 右侧 pin.fill 角标。accent 色，选中态翻白让两种状态都清晰。
                // 不放在 meta 行里——meta 已经够拥挤，角标在 trailing 视觉更明确（跟"歌单
                // pin 在最上"的 macOS Music app 心智一致）
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Spotlight-style 选中行：inline 圆角块，不通栏到 panel 边缘
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        // 外圈 horizontal padding 让选中块两侧留出空气
        .padding(.horizontal, 10)
    }

    /// 左侧图标：优先 app 图标（按 bundleID 查 LaunchServices）；找不到 fallback 到 kind SF Symbol。
    /// fallback 触发场景：item 来自 mirror 而本机没装那个 app；或源 app 没报 bundleID。
    @ViewBuilder
    private var leadingIcon: some View {
        if let bid = item.sourceApp, let img = AppIconCache.shared.icon(forBundleID: bid) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: kindSymbol)
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
        }
    }

    /// kind 中文标签——meta 行第一列显示。比 bundle name 更立刻能读懂"这是什么"。
    private var kindLabel: String {
        switch item.kind {
        case .text: "文本"
        case .rtf: "富文本"
        case .html: "HTML"
        case .url: "链接"
        case .image: "图片"
        case .file: "文件"
        }
    }

    /// app icon 不可用时的 fallback symbol。
    private var kindSymbol: String {
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

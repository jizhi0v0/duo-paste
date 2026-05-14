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

/// 按 sha256 → 缩略图的进程内 LRU-less 缓存。ItemCard 主区 200×168 显示原图 aspectFit。
///
/// content-addressed 缓存:同一 sha 的字节内容固定 → 缩略图也固定,缓存命中率高。
/// **maxPx=400** ≈ 卡片宽 200 × 2x retina,够清晰;原 Spotlight 列表 32pt row 用 64 太低,
/// 改卡片布局后调高让缩略图不糊。1000 image 缓存 ~10-30MB 内存,可接受
///
/// 加载策略:
/// - `cached(sha:)` 同步查 dict,命中直接返回(SwiftUI body 内可直接调,不卡)
/// - `thumbnail(sha:blobs:)` async,miss 时 Task.detached 跑 background CPU decode +
///   downscale(用 CGImageSourceCreateThumbnailAtIndex 是 Core Graphics 最快路径,~毫秒级)
/// - decode 失败的 sha 进 `notDecodable` 黑名单,LazyVStack 重渲不再反复重试
@MainActor
final class ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    private var cache: [String: NSImage] = [:]
    private var notDecodable: Set<String> = []
    private static let maxPx: Int = 400

    func cached(sha256: String) -> NSImage? { cache[sha256] }

    func thumbnail(sha256: String, blobs: BlobStore) async -> NSImage? {
        if let img = cache[sha256] { return img }
        if notDecodable.contains(sha256) { return nil }
        let maxPx = Self.maxPx
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let data = try? blobs.read(sha256: sha256) ?? nil else { return nil }
            return Self.decodeThumbnail(data: data, maxPx: maxPx)
        }.value
        if let img {
            cache[sha256] = img
        } else {
            notDecodable.insert(sha256)
        }
        return img
    }

    /// `nonisolated` 让 Task.detached 闭包能直接调——本函数纯 CG 调用 + 局部变量,无
    /// MainActor 状态访问,跑 background CPU 安全
    nonisolated private static func decodeThumbnail(data: Data, maxPx: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        // point size = pixel / 2(2x retina) 让 SwiftUI 用 point 摆放跟 32pt frame 对齐
        let size = NSSize(width: CGFloat(cgImg.width) / 2, height: CGFloat(cgImg.height) / 2)
        return NSImage(cgImage: cgImg, size: size)
    }
}

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
        // self-capture sentinel：详见 Item.selfSourceAppSentinel。即便有别处误调
        // AppIconCache，也直接命中黑名单返 nil，让 leadingIcon 走 self badge 分支
        Item.selfSourceAppSentinel,
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
    /// Enter / 双击触发的 paste 回调。双击行传 `[item]` 单条;Enter 由 SearchPanelController
    /// 走 selectedItems 传多条。AppDelegate.pasteBack 根据数量决定单项 / 合并 / 降级路径
    var onPaste: ([Item]) -> Void
    var onClose: () -> Void

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            compactHeader              // 搜索框 + count(单行 ~42px)
            compactFilterBar           // chip 行 + 时间窗 + 仅置顶(~30px)
            // 主体卡片区域,横向 LazyHStack 滚动
            if state.results.isEmpty {
                emptyView
            } else {
                cardScroller
            }
        }
        .overlay(alignment: .top) {
            // banner 用 overlay 浮在 header 上方,不占主体高度。
            // padding.top 让位给 header(42) + filterBar(30) = 72
            VStack(spacing: 4) {
                noticeBanner
                pasteProgressBanner
                skipBanner
                modeBanner
                clockSkewBanner
            }
            .padding(.top, 76)
            .padding(.horizontal, 14)
            .allowsHitTesting(false)  // overlay 不抢点击,user 还能点卡片
        }
        .frame(minWidth: 800, minHeight: 280, idealHeight: 280, maxHeight: 280)
        // Paste.app 风格底部条:全宽贴底,只顶部两个角圆。底部+左右贴屏边没必要圆角
        .background(.ultraThickMaterial)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 22, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 22,
                style: .continuous
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 22, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 22,
                style: .continuous
            )
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

    /// Paste.app 风格紧凑搜索头:单行,~42px。原 header 是 22pt 大字体 + 上下 20px padding =
    /// ~64px,在 280px panel 里占太多。这里压成 16pt + 上下 10px = ~42px
    private var compactHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板历史", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .focused($searchFieldFocused)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("\(state.totalCount) 条")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    /// 紧凑 filter 行 ~30px。原 filterBar 高 ~46px,缩小 chip 字号 + padding 让它适配 280 高 panel
    private var compactFilterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filterChipKinds, id: \.self) { kind in
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
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清除类型筛选")
                    }
                    pinnedOnlyChip
                }
            }
            timeRangeMenu
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// Paste.app 风格横向卡片滚动。LazyHStack 让千条 item 不卡——出视口的卡 unload。
    /// ScrollViewReader.scrollTo 配 selectedIDs.last + scrollPulse 让箭头导航能滚到选中卡
    private var cardScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    Color.clear.frame(width: 6)  // 起始 padding
                    ForEach(state.results) { item in
                        ItemCard(
                            item: item,
                            isSelected: state.selectedIDs.contains(item.id),
                            selfDeviceID: state.deps.deviceID,
                            snippet: state.snippets[item.id],
                            blobs: state.deps.blobs
                        )
                        .id(item.id)
                        // 双击粘贴(无视 selectedIDs)
                        .gesture(
                            TapGesture(count: 2).onEnded {
                                onPaste([item])
                            }
                        )
                        // 单击改 selection;NSEvent.modifierFlags 同步取 cmd/shift 状态
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.command) {
                                    if let i = state.selectedIDs.firstIndex(of: item.id) {
                                        state.selectedIDs.remove(at: i)
                                    } else {
                                        state.selectedIDs.append(item.id)
                                        state.anchorID = item.id
                                    }
                                } else if mods.contains(.shift) {
                                    guard let anchor = state.anchorID,
                                          let from = state.results.firstIndex(where: { $0.id == anchor }),
                                          let to = state.results.firstIndex(where: { $0.id == item.id })
                                    else {
                                        state.selectedIDs = [item.id]
                                        state.anchorID = item.id
                                        return
                                    }
                                    let lo = min(from, to)
                                    let hi = max(from, to)
                                    state.selectedIDs = (lo...hi).map { state.results[$0].id }
                                } else {
                                    state.selectedIDs = [item.id]
                                    state.anchorID = item.id
                                }
                            }
                        )
                    }
                    Color.clear.frame(width: 6)  // 结束 padding
                }
                .padding(.vertical, 8)
            }
            .onChange(of: state.scrollPulse) { _, _ in
                if let id = state.selectedIDs.last {
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
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
    ///
    /// 布局：左侧 chip 区横向滚动（panel 收窄时不会让 "文本" 垂直堆叠成 "文 / 本"，
    /// trackpad 双指水平滑动可见全部 chip），右侧 timeRangeMenu 固定贴边——时间窗高频，
    /// 不能因为滚动隐藏到屏外。chip 内部全部 `.fixedSize()` 保自然宽度。
    private var filterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filterChipKinds, id: \.self) { kind in
                        // 契约：空 dict（出错降级）→ nil 隐藏数字；非空 dict（fold-aware 正常路径）
                        // → 缺 key 默认 0 显示 "图片 0"。这样 KindChip 头注释的 "0 也显示" 才真生效
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
                }
                .padding(.vertical, 1)
            }
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
        .fixedSize()
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
    /// - `.local` → 不显示（standalone 或 mesh 还没追平任何 peer 的初始态）
    /// - `.mesh(stalenessSec: nil)` → 不显示（peer 配了但还没成功跑过 pull tick）
    /// - `.mesh(stalenessSec)` 稳态 0-60s → 不显示
    /// - `.mesh(stalenessSec)` > 300s → 黄色显示「peer 同步滞后」
    ///   pull interval 默认 30s，稳态 staleness 应在 0-60s。超过 300s 说明 PullWorker
    ///   卡死 / peer 不可达 / 时钟漂移，这时才有告知价值
    @ViewBuilder
    private var modeBanner: some View {
        switch state.searchMode {
        case .mesh(let stalenessSec) where (stalenessSec ?? 0) > 300:
            HStack(spacing: 6) {
                Image(systemName: "internaldrive.badge.exclamationmark")
                Text("peer 同步滞后")
                Text("·").foregroundStyle(.secondary)
                Text("已 \(humanStaleness(stalenessSec ?? 0)) 未拉取").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15))
        case .mesh, .local:
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

    // 旧 list(LazyVStack 垂直列表)已被 cardScroller(LazyHStack 横向卡片)替代,见 body 调用
}

/// 类型 chip 单元。pill capsule，选中状态 accent 填充 + 白字。
/// 单击 toggle 选中状态。视觉跟 timeRangeMenu 的 capsule 保持一致——padding / radius 同步
///
/// `count` 非 nil 时尾巴挂活计数 "图片 19"——让用户立刻看出哪个类稀疏。
/// 0 也显示（"图片 0"），避免用户误以为 filter 失效；nil = 出错降级时隐藏。
/// nil/0 的区分发生在 caller：空 kindCounts dict（出错降级）→ nil；非空 dict
/// （fold-aware 路径有命中）→ 缺 key 默认 0。
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
        // 不加这个，父 HStack 收窄时会把 "文本" 压成 "文 / 本" 垂直堆叠（Text 默认允许多行换行）。
        // 配合 filterBar 外层 ScrollView 横滚——panel 即使窄到 minWidth=640 chip 也保自然宽度
        .fixedSize()
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

private struct ItemCard: View {
    let item: Item
    let isSelected: Bool
    /// `item.originDevice != selfDeviceID` 表示 PullWorker 从对端镜像过来的远端 item,
    /// 卡片左上角叠橙色 arrow.down.left 角标
    let selfDeviceID: String
    /// 含 STX/ETX 高亮标记的 FTS snippet,query 非空 + 命中时非 nil
    let snippet: String?
    /// BlobStore reference 让 contentArea 异步加载 image kind / file-as-image 缩略图
    let blobs: BlobStore

    /// 缩略图状态。.task 异步加载完 set;LazyHStack 卡滚出视野 unload 时 cancel + 重置
    @State private var thumbnail: NSImage?

    private var isRemoteMirror: Bool {
        item.originDevice != selfDeviceID
    }

    /// 是否应该显示缩略图。命中三路:image kind / file kind+blob mime=image/ / file kind+
    /// 路径后缀像 image。前提是有 blob sha
    private var shouldShowThumbnail: Bool {
        guard item.blobSha256 != nil else { return false }
        if item.kind == .image { return true }
        if item.kind == .file {
            if let mime = item.blobMime, mime.hasPrefix("image/") { return true }
            if let p = item.textFull, fileLooksLikeImage(path: p) { return true }
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            contentArea       // 主区 168(image aspectFill / 文本多行 / file 图标)
            footer            // 32 (app icon + kind + meta + relative time)
        }
        .frame(width: 200, height: 200)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.08 : 0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            // 选中态加 accent 描边 + 加粗;未选中淡灰发丝线
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.10),
                    lineWidth: isSelected ? 2 : 0.5
                )
        )
        .overlay(alignment: .topTrailing) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(4)
            }
        }
        .overlay(alignment: .topLeading) {
            if isRemoteMirror {
                remoteOriginBadge
                    .padding(6)
            }
        }
        .task(id: item.blobSha256 ?? "") {
            guard shouldShowThumbnail, let sha = item.blobSha256 else {
                if thumbnail != nil { thumbnail = nil }
                return
            }
            if let cached = ImageThumbnailCache.shared.cached(sha256: sha) {
                if thumbnail !== cached { thumbnail = cached }
                return
            }
            let img = await ImageThumbnailCache.shared.thumbnail(sha256: sha, blobs: blobs)
            if !Task.isCancelled, thumbnail !== img {
                thumbnail = img
            }
        }
    }

    /// 卡片主区(200×168)。image kind 走原图 aspectFit(显示完整,letterbox 用深色背景填充);
    /// loading 走 placeholder;text 类走多行文字
    @ViewBuilder
    private var contentArea: some View {
        if shouldShowThumbnail, let thumb = thumbnail {
            ZStack {
                Color.primary.opacity(0.08)  // letterbox 填充色,跟 footer 一致
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
            .frame(width: 200, height: 168)
        } else if shouldShowThumbnail {
            // 加载中:placeholder
            ZStack {
                Color.primary.opacity(0.03)
                Image(systemName: "photo")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            .frame(width: 200, height: 168)
        } else if item.kind == .file {
            // file 卡(非 image-as-file):大文件 SF Symbol + 文件名
            VStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                previewText
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
            }
            .frame(width: 200, height: 168)
        } else {
            // text/url/rtf/html:多行内容
            previewText
                .font(.system(size: 13))
                .lineLimit(8)
                .multilineTextAlignment(.leading)
                .frame(width: 200, height: 168, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
        }
    }

    /// 卡片 footer(200×32):左 app icon + 中 kind/size/time meta + 右 spacer
    private var footer: some View {
        HStack(spacing: 6) {
            footerIcon
                .frame(width: 16, height: 16)
            Text(footerMeta)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 200, height: 32)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var footerIcon: some View {
        if item.isSelfCapture {
            ZStack {
                Circle().fill(Color.accentColor)
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else if let bid = item.sourceApp, let img = AppIconCache.shared.icon(forBundleID: bid) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: kindSymbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// "文本 · 34s" / "图片 · 4.5 MB · 41m" 之类
    private var footerMeta: String {
        var parts: [String] = [kindLabel]
        if item.kind == .image, let size = item.blobSize {
            parts.append(humanSize(size))
        }
        let rel = relativeFormatter.localizedString(for: capturedDate, relativeTo: Date())
        parts.append(rel)
        return parts.joined(separator: " · ")
    }

    /// 远端镜像角标——左上角橙色圆 + 白 stroke + arrow.down.left。
    /// 卡片视觉重心在内容,角标移到左上不抢戏,跟右上 pin 错开
    private var remoteOriginBadge: some View {
        ZStack {
            Circle().fill(Color.orange)
            Circle().strokeBorder(Color.white, lineWidth: 1)
            Image(systemName: "arrow.down.left")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 14, height: 14)
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
        // file 行 text_full 存完整路径；FTS snippet 也是路径片段——
        // 同目录下多条结果路径段相同，用户无法区分。
        // 始终显示完整文件名，并尝试把 snippet 里的高亮词匹配到文件名内加粗。
        if item.kind == .file {
            let raw = item.textFull ?? item.preview ?? ""
            let names = raw.split(separator: "\n", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0)).lastPathComponent }
                .filter { !$0.isEmpty }
            if let first = names.first {
                let head = highlightedFileName(first, from: snippet)
                if names.count == 1 { return head }
                return head + Text(" +\(names.count - 1)").foregroundStyle(.secondary)
            }
        }
        if let s = snippet, !s.isEmpty {
            return highlightedText(from: s)
        }
        return Text(item.preview ?? "")
    }

    /// 完整文件名显示，若搜索词恰好命中文件名则加粗，否则返回纯文本。
    /// 高亮词从 snippet 的 STX/ETX 标记里提取，取最长的那个避免短子串抢先。
    private func highlightedFileName(_ name: String, from snippet: String?) -> Text {
        var terms: [String] = []
        var rest = (snippet ?? "")[...]
        while let s = rest.range(of: "\u{02}") {
            let after = rest[s.upperBound...]
            if let e = after.range(of: "\u{03}") {
                terms.append(String(after[..<e.lowerBound]))
                rest = after[e.upperBound...]
            } else { break }
        }
        guard let term = terms.max(by: { $0.count < $1.count }),
              !term.isEmpty,
              let range = name.range(of: term, options: .caseInsensitive) else {
            return Text(name)
        }
        return Text(String(name[..<range.lowerBound]))
            + Text(String(name[range])).bold()
            + Text(String(name[range.upperBound...]))
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

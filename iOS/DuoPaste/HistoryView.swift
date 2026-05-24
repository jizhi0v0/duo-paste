import SwiftUI
import DuoPasteCore

struct HistoryView: View {
    @Environment(HistoryStore.self) private var store
    @Environment(PeerSyncCoordinator.self) private var coordinator
    /// 搜索框 plain text —— 纯内容搜索,不再解析 `/xxx`(iOS 上下拉 Menu 多选 +
    /// chip 行的入口比 slash 顺手,见 filterMenu)
    @State private var searchText: String = ""
    /// 已激活的过滤 qualifier —— filterChipRow tap 写,store filter 读。
    /// Set 让多选 dedup 自然,顺序无关
    @State private var activeQualifiers: Set<QueryQualifier> = []
    /// 单 debounce 管 store.query 本机更新 + server search。150ms / 250ms 两段
    @State private var storeUpdateTask: Task<Void, Never>?

    var body: some View {
        // **per-render cache**:filtered 只读一次(computed property 多读会再跑 O(items))
        let filteredItems = store.filtered

        return NavigationStack {
            VStack(spacing: 0) {
                if let msg = store.deleteFailureMessage {
                    deleteFailureBanner(message: msg)
                }
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                filterChipRow
                Group {
                    if store.items.isEmpty {
                        emptyState
                    } else if filteredItems.isEmpty {
                        noResultsState
                    } else {
                        listScrollWithItems(filteredItems)
                    }
                }
            }
            .navigationTitle("DuoPaste")
            .onChange(of: searchText) { _, _ in
                scheduleStoreUpdate()
            }
            .onChange(of: activeQualifiers) { _, new in
                // qualifiers 变低频,直接同步 store 不走 debounce(避免用户感觉"勾了
                // 还没生效")
                store.activeQualifiers = Array(new)
            }
            .toolbar { fullToolbar }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .tabBar)
        }
    }

    /// 整套 toolbar:左上角同步状态徽标,右上角刷新按钮
    @ToolbarContentBuilder
    private var fullToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            statusBadge
                .accessibilityLabel("同步状态")
        }
        ToolbarItem(placement: .topBarTrailing) {
            refreshButton
        }
    }

    /// 自建搜索栏:放大镜装饰位 + TextField + 清除按钮。不用 iOS `.searchable` 是因为
    /// 想跟下面 chip 行视觉上连为一体
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索内容", text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// **Apple Mail 风格 chip 行**:始终可见,所有 filter 平铺,tap toggle 选中态。
    /// 选中 chip = accent 实心 + 白字,未选 = 灰底 + 主色文字。一眼看清当前状态 + 可选项,
    /// 比 Menu/Sheet 多一步少;sensoryFeedback 给 tap 触感反馈
    private var filterChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.allFilters, id: \.qualifier) { item in
                    filterChip(item)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func filterChip(_ item: (label: String, qualifier: QueryQualifier)) -> some View {
        let isSelected = activeQualifiers.contains(item.qualifier)
        Button {
            if isSelected {
                activeQualifiers.remove(item.qualifier)
            } else {
                activeQualifiers.insert(item.qualifier)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: QualifierUI.icon(item.qualifier))
                    .font(.system(size: 11, weight: .semibold))
                Text(item.label)
                    .font(.system(.footnote).weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isSelected
                        ? Color.accentColor
                        : Color(.tertiarySystemBackground)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : Color.primary.opacity(0.08),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    /// chip 行用——kind 在前文件细分在后,顺序合常识。`.imageMerged` 合并原生图片 + 文件图片
    private static var allFilters: [(label: String, qualifier: QueryQualifier)] {
        kindFilters + subKindFilters
    }

    /// 主 kind 过滤(`.imageMerged` 把原生图片 + Finder 复制图片文件合并成一个用户视角的"图片")
    private static let kindFilters: [(label: String, qualifier: QueryQualifier)] = [
        ("文本", .kind(.text)),
        ("网址", .kind(.url)),
        ("图片", .imageMerged),
        ("文件", .kind(.file)),
        ("富文本", .kind(.rtf)),
        ("HTML", .kind(.html)),
    ]

    /// 文件细分(`.file` kind 下的 sub-kind)
    private static let subKindFilters: [(label: String, qualifier: QueryQualifier)] = [
        ("PDF", .fileSubKind(.pdf)),
        ("视频", .fileSubKind(.video)),
        ("音频", .fileSubKind(.audio)),
    ]

    /// 单 debounce 同管 store.query 本机更新 + server search。**不**在按键路径直接动 store,
    /// 那俩 mutate 会让 `HistoryStore.filtered` 重算(items × O(N)),每键卡顿。
    /// 150ms 等用户停手再更新,250ms 打 server
    private func scheduleStoreUpdate() {
        storeUpdateTask?.cancel()
        storeUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            store.query = searchText
            store.clearServerSearch()
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            coordinator.searchOnServer(q: trimmed)
        }
    }


    /// toolbar trailing 刷新按钮。SF Symbol 用 `arrow.triangle.2.circlepath` 而非
    /// `arrow.clockwise`——后者字形单箭头不中心对称(头重尾轻),无论 anchor 多准旋转
    /// 视觉上都"飘",看起来不圆。`arrow.triangle.2.circlepath` 两个三角形对称构成完整
    /// 圆环(Safari / Photos reload 同款),配 `.symbolEffect(.rotate)` 是真正的匀速圆周
    ///
    /// **不要换回** `arrow.clockwise`:用户反馈"转起来不圆"直接来源于这个图标的非对称
    private var refreshButton: some View {
        let canPull = coordinator.canForcePull
        return Button {
            coordinator.forcePull()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeating, isActive: coordinator.isPulling)
        }
        .disabled(!canPull)
        .sensoryFeedback(.impact(weight: .light), trigger: coordinator.isPulling)
        .accessibilityLabel("刷新")
        .accessibilityValue(coordinator.isPulling ? "正在刷新" : (canPull ? "" : "未配对,无法刷新"))
    }

    /// 接外部传 items —— body 已经 per-render cache 了 `store.filtered`,这里不再重读
    /// (computed property 重读会再跑一遍 O(items) filter,卡顿源)
    private func listScrollWithItems(_ items: [Item]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10, alignment: .top),
                    GridItem(.flexible(), spacing: 10, alignment: .top),
                ],
                spacing: 10
            ) {
                ForEach(items) { item in
                    HistoryCellView(item: item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
    }

    /// 顶部橙色 banner——`merge()` 检测到 server DELETE 没送达把行重新带回来时显示。
    /// 5s 自动消(`.task(id:)` 让 message 变化时重置 timer)+ ✕ 按钮手动消。
    /// 文案含具体条数让用户知道是删除问题不是其他同步故障
    @ViewBuilder
    private func deleteFailureBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message).font(.caption)
            Spacer()
            Button {
                store.dismissDeleteFailureMessage()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
        .task(id: message) {
            // 5s 自动消;期间用户点 ✕ 已经 dismiss,新一轮 message 出现时 task 重启
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                store.dismissDeleteFailureMessage()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyDescription)
        }
    }

    /// items 非空但 filter 命中 0 的状态——ContentUnavailableView.search 系统给的"无搜索结果"
    /// 标准 layout (放大镜图标 + 当前 search 词), 系统会自适应当前 query 显示成 "未找到 '...'".
    /// 单 chip / 多 chip 场景拿不到搜索词时显示泛化文案
    @ViewBuilder
    private var noResultsState: some View {
        if !store.query.isEmpty {
            ContentUnavailableView.search(text: store.query)
        } else {
            ContentUnavailableView(
                "无匹配项",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("当前筛选条件没匹配到内容,去掉 chip 试试")
            )
        }
    }

    private var emptyTitle: String {
        switch coordinator.status {
        case .unconfigured: "需要配置 peer"
        case .connecting, .backoff: "正在连接"
        case .connected: "等待新内容"
        case .error: "连接出错"
        case .idle: "暂无内容"
        }
    }

    private var emptyIcon: String {
        switch coordinator.status {
        case .unconfigured: "gearshape"
        case .error: "exclamationmark.triangle"
        default: "doc.on.clipboard"
        }
    }

    private var emptyDescription: String {
        switch coordinator.status {
        case .unconfigured:
            "去「设置」填 peer URL + shared secret"
        case .error(let m):
            m
        default:
            "在 Mac 上复制点东西就会同步过来"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch coordinator.status {
        case .connected:
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        case .connecting, .backoff:
            ProgressView().controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unconfigured, .idle:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
}

/// slash qualifier 的 SF Symbol + 中文标签映射。chip 行 + (未来)补全 suggestion
/// row 共用——靠 Label(text, systemImage) 系统自动布局图标在前文字在后,跟 Mail/Files
/// 等系统 app chip 视觉一致。
///
/// 标签策略:用 QueryParser canonical alias 显示 `/pdf` / `/image` 等——让用户看 chip
/// 就知道在搜索栏可以输什么字符复现这个 filter,降低 slash 命令的学习门槛
enum QualifierUI {
    static func label(_ q: QueryQualifier) -> String {
        switch q {
        case .kind(.text):  return "/text"
        case .kind(.url):   return "/url"
        case .kind(.file):  return "/file"
        case .kind(.rtf):   return "/rtf"
        case .kind(.html):  return "/html"
        case .kind(.image): return "/image"
        case .imageMerged:  return "/image"
        case .fileSubKind(.pdf):       return "/pdf"
        case .fileSubKind(.video):     return "/video"
        case .fileSubKind(.audio):     return "/audio"
        case .fileSubKind(.imageFile): return "/imagefile"
        case .textSuffix(let s):       return "/" + s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }

    static func icon(_ q: QueryQualifier) -> String {
        switch q {
        case .kind(.text):  return "text.alignleft"
        case .kind(.url):   return "link"
        case .kind(.file):  return "doc"
        case .kind(.rtf):   return "doc.richtext"
        case .kind(.html):  return "globe"
        case .kind(.image): return "photo"
        case .imageMerged:  return "photo"
        case .fileSubKind(.pdf):       return "doc.text"
        case .fileSubKind(.video):     return "video"
        case .fileSubKind(.audio):     return "music.note"
        case .fileSubKind(.imageFile): return "photo"
        case .textSuffix:              return "chevron.left.forwardslash.chevron.right"
        }
    }
}

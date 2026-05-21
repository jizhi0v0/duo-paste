import SwiftUI
import DuoPasteCore

struct HistoryView: View {
    @Environment(HistoryStore.self) private var store
    @Environment(PeerSyncCoordinator.self) private var coordinator
    @State private var searchText = ""
    /// 搜索 debounce task。每次 query 变直接 cancel 上一个,250ms 后真正发 /search 请求。
    /// 避免用户敲字时每个字符都打 server。Sendable 不必——只在 MainActor 改
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let msg = store.deleteFailureMessage {
                    deleteFailureBanner(message: msg)
                }
                Group {
                    if store.items.isEmpty {
                        emptyState
                    } else {
                        listScroll
                    }
                }
            }
            .navigationTitle("DuoPaste")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索"
            )
            .onChange(of: searchText) { _, new in
                store.query = new
                // 清掉上一轮 server 结果让 UI 暂时 fallback 本机 contains,防止旧命中残影;
                // 250ms debounce 后真正打 server
                store.clearServerSearch()
                searchDebounceTask?.cancel()
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                searchDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                    // 用户改了 query → 上一个 task 已 cancel,这里 trimmed 是最新的
                    coordinator.searchOnServer(q: trimmed)
                }
            }
            .toolbar { statusToolbar }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .tabBar)
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

    private var listScroll: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10, alignment: .top),
                    GridItem(.flexible(), spacing: 10, alignment: .top),
                ],
                spacing: 10
            ) {
                ForEach(store.filtered) { item in
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

    @ToolbarContentBuilder
    private var statusToolbar: some ToolbarContent {
        // 左上角:同步状态徽标。leading 离 nav title 远,跟用户"先看连接好不好,再看内容"
        // 的扫视顺序一致
        ToolbarItem(placement: .topBarLeading) {
            statusBadge
                .accessibilityLabel("同步状态")
        }
        // 右上角:刷新按钮。toolbar 风格代替之前的右下角 FAB——iOS 视觉跟 Mail / Photos
        // 等系统 app 一致,且不挡列表底部的卡片
        ToolbarItem(placement: .topBarTrailing) {
            refreshButton
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

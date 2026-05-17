import SwiftUI
import DuoPasteCore

struct HistoryView: View {
    @Environment(HistoryStore.self) private var store
    @Environment(PeerSyncCoordinator.self) private var coordinator
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else {
                    listScroll
                }
            }
            // iOS 26 TabView crossfade 会让两个 tab 同时半透明叠加。
            // 不给根视图加 opaque 底,Liquid Glass 卡片之间的缝就会漏出对面 tab 内容。
            // ignoresSafeArea 让 opaque 底延伸到 nav bar / search drawer / tab bar 下面,
            // 这样 Liquid Glass blur 永远只看到一个 solid color 而不是对面 tab 的内容
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("DuoPaste")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索"
            )
            .onChange(of: searchText) { _, new in store.query = new }
            .toolbar { statusToolbar }
        }
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
        // iOS 26 API:把顶/底 edge effect 从默认 soft(柔化模糊)切到 hard(硬边)。
        // soft 模式下内容滚到 nav bar 下方会被柔化半透显示,Tab crossfade 那一帧 blur
        // 抖一下就漏到对面 tab。hard 模式硬切,内容到 safe area 边就停,不再延伸到 bar 下
        .scrollEdgeEffectStyle(.hard, for: .top)
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
        ToolbarItem(placement: .topBarTrailing) {
            statusBadge
                .accessibilityLabel("同步状态")
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

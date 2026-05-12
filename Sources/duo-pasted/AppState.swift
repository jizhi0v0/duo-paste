import Foundation
import Observation
import DuoPasteCore
import DuoPasteSync

/// SwiftUI 视图与底层 Database/CaptureService 的桥接。
/// 持有当前搜索字符串、结果列表和高亮行号；提供 refresh / paste / 监听捕获更新等动作。
@MainActor
@Observable
final class AppState {
    var query: String = ""
    var results: [Item] = []
    /// `id → snippet`（含 STX/ETX 高亮标记）。仅 query 非空 + FTS 命中时有内容。
    /// SearchView ItemRow 用 `snippet(for:)` 拿；为 nil 时 fallback 到 item.preview。
    var snippets: [String: String] = [:]
    var selectedID: String?
    var lastError: String?
    /// 当前搜索源——决定顶部 banner 显示什么。
    var searchMode: SearchProvider.Mode = .local
    /// 键盘导航触发滚动用的脉冲计数；每次箭头导航 +1，触发 SearchView 滚动到选中项。
    /// 鼠标点击只改 selectedID 不动这个，避免不必要的滚动。
    var scrollPulse: Int = 0
    /// 最近一次 capture 被跳过的提示（超过 CaptureLimits）。
    /// 5 分钟内有值 → SearchView 顶部黄色 banner；用户能手动 ✕ 关闭立即清掉。
    /// 不持久化——重启就清，是 "刚才有点东西没存下来" 的实时提示。
    var recentSkip: SkipNotice?

    let deps: AppDependencies

    /// 单次跳过的提示。`bytes` / `limit` 单位字节，UI 端 humanize。`kind` 决定文案。
    struct SkipNotice: Equatable, Sendable {
        enum Kind: Sendable { case text, blob }
        let kind: Kind
        let bytes: Int
        let limit: Int
        let occurredAt: Date
    }

    /// 由 AppDelegate.handleCapture 在拿到 `.skippedTooLarge` outcome 时调用。
    /// 副作用：5 分钟后自动清掉（如果还没被新的 skip 覆盖 / 用户没手动 ✕）——
    /// 否则 SwiftUI 不会自己重新求值 `Date().timeIntervalSince() < 300`，banner 永驻。
    func recordSkip(kind: SkipNotice.Kind, bytes: Int, limit: Int) {
        let notice = SkipNotice(kind: kind, bytes: bytes, limit: limit, occurredAt: Date())
        self.recentSkip = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            // 仅当 recentSkip 仍是本次塞进去的那条时才清；中间被新 skip 覆盖或被
            // dismissSkip 清掉 → 不该再动
            if self?.recentSkip == notice {
                self?.recentSkip = nil
            }
        }
    }

    func dismissSkip() {
        self.recentSkip = nil
    }

    init(deps: AppDependencies) {
        self.deps = deps
        // 同步预填本地最新 200 条，避免 panel 首次打开 SwiftUI 第一帧渲染
        // 时 results=[] → 看到 "0 条" 闪一下。Panel 触发 .task 后会异步 refresh
        // 一次（可能从 remote 拿更新），把这里的结果替换/扩展。
        // 用本地不走 searchProvider，绕开 remote 慢路径——0 ms 同步可拿到结果。
        let initial = (try? deps.searchAPI.search(SearchQuery(limit: 200))) ?? []
        self.results = initial
        self.selectedID = initial.first?.id
    }

    /// 当前应该粘贴的项：优先选中项，否则取列表首项。
    var currentItem: Item? {
        if let id = selectedID, let it = results.first(where: { $0.id == id }) {
            return it
        }
        return results.first
    }

    func navigate(by delta: Int) {
        guard !results.isEmpty else { return }
        let idx = results.firstIndex(where: { $0.id == selectedID }) ?? 0
        let next = max(0, min(results.count - 1, idx + delta))
        selectedID = results[next].id
        scrollPulse &+= 1
    }

    func refresh() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = SearchQuery(
            text: trimmed.isEmpty ? nil : trimmed,
            limit: 200
        )
        do {
            let outcome = try await deps.searchProvider.search(q)
            self.results = outcome.items
            self.snippets = outcome.snippets
            self.searchMode = outcome.mode
            updateSelection(forItems: outcome.items, queryIsEmpty: trimmed.isEmpty)
            self.lastError = nil
        } catch is CancellationError {
            // 用户在打字，新查询正在替换旧的，正常
        } catch {
            self.lastError = "\(error)"
        }
    }

    /// 列表刷新后调整选中行：
    /// - **query 空**（首次打开 / 清空搜索）→ 强制选第一项（最新捕获），并触发滚回顶部
    /// - **query 非空 + 原选中行仍在结果里** → 保持选中（让"缩小关键词"流不丢焦点）
    /// - **query 非空 + 原选中行不在结果里** → 选第一项
    private func updateSelection(forItems items: [Item], queryIsEmpty: Bool) {
        let newSelection: String?
        if queryIsEmpty {
            newSelection = items.first?.id
        } else if let id = self.selectedID, items.contains(where: { $0.id == id }) {
            newSelection = id  // preserve
        } else {
            newSelection = items.first?.id
        }
        if newSelection != self.selectedID {
            self.selectedID = newSelection
            // selection 跳到非临近行（清空搜索时常见），SearchView 需要重新滚到选中项；
            // scrollPulse 是唯一让它滚动的入口
            if newSelection != nil {
                self.scrollPulse &+= 1
            }
        }
    }
}

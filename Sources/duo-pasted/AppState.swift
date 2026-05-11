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
    var selectedID: String?
    var lastError: String?
    /// 当前搜索源——决定顶部 banner 显示什么。
    var searchMode: SearchProvider.Mode = .local
    /// 键盘导航触发滚动用的脉冲计数；每次箭头导航 +1，触发 SearchView 滚动到选中项。
    /// 鼠标点击只改 selectedID 不动这个，避免不必要的滚动。
    var scrollPulse: Int = 0

    let deps: AppDependencies

    init(deps: AppDependencies) {
        self.deps = deps
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
        let q = SearchQuery(
            text: query.isEmpty ? nil : query,
            limit: 200
        )
        do {
            let outcome = try await deps.searchProvider.search(q)
            self.results = outcome.items
            self.searchMode = outcome.mode
            if let id = self.selectedID, outcome.items.contains(where: { $0.id == id }) {
                // 保持选中行
            } else {
                self.selectedID = outcome.items.first?.id
            }
            self.lastError = nil
        } catch is CancellationError {
            // 用户在打字，新查询正在替换旧的，正常
        } catch {
            self.lastError = "\(error)"
        }
    }
}

import Foundation
import Testing

private func r31Source(_ relativePath: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@Suite("R3.1 macOS custom date range source contract")
struct SearchTimeRangeUIContractTests {
    @Test("菜单暴露两个 date-only DatePicker 和可见的自定义标签")
    func menuExposesCustomDateEditor() throws {
        let view = try r31Source("Sources/duo-pasted/SearchView.swift")

        #expect(view.contains("Text(\"自定义日期…\")"))
        #expect(view.components(separatedBy: "displayedComponents: .date").count == 3)
        #expect(view.contains("timeRangeLabel(state.timeRange)"))
        #expect(view.contains("customRangePresented"))
    }

    @Test("应用、倒序校验和清除动作都接到 timeRange 状态")
    func editorCanApplyValidateAndClear() throws {
        let view = try r31Source("Sources/duo-pasted/SearchView.swift")

        #expect(view.contains("state.timeRange = .custom("))
        #expect(view.contains(".disabled(!customRangeIsValid)"))
        #expect(view.contains("state.timeRange = .all"))
        #expect(view.contains("Text(\"结束日期不能早于开始日期\")"))
    }

    @Test("AppState 把同一时间模型的上下界写入 SearchQuery")
    func appStateWiresBothBoundsIntoSearchQuery() throws {
        let appState = try r31Source("Sources/duo-pasted/AppState.swift")

        #expect(appState.contains("let timeBounds = timeRange.bounds()"))
        #expect(appState.contains("fromNs: timeBounds.fromNs"))
        #expect(appState.contains("toNs: timeBounds.toNs"))
        #expect(appState.contains("timeRange.filterKey"))
    }
}

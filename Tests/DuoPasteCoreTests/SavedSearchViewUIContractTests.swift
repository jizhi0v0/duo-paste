import Foundation
import Testing

private func r32Source(_ relativePath: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@Suite("R3.2 saved search view UI and lifecycle contract")
struct SavedSearchViewUIContractTests {
    @Test("AppState 写盘成功后才发布数组，并恢复全部筛选字段")
    func appStatePublishesAfterDiskAndAppliesEveryField() throws {
        let source = try r32Source("Sources/duo-pasted/AppState.swift")
        let disk = try #require(source.range(of: "try savedViewStore.save(library)"))
        let publish = try #require(source.range(of: "savedSearchViews = library.views", range: disk.upperBound..<source.endIndex))

        #expect(disk.lowerBound < publish.lowerBound)
        #expect(source.contains("query = view.filter.query"))
        #expect(source.contains("activeQualifiers = view.filter.qualifiers"))
        #expect(source.contains("selectedKinds = Set(view.filter.kinds)"))
        #expect(source.contains("selectedFileSubKinds = Set(view.filter.fileSubKinds)"))
        #expect(source.contains("timeRange = view.filter.timeRange"))
        #expect(source.contains("pinnedOnly = view.filter.pinnedOnly"))
    }

    @Test("SearchView 暴露保存、应用与删除入口")
    func searchViewExposesSavedViewActions() throws {
        let source = try r32Source("Sources/duo-pasted/SearchView.swift")

        #expect(source.contains("保存当前视图…"))
        #expect(source.contains("state.applySavedSearchView(view)"))
        #expect(source.contains("state.saveCurrentSearchView"))
        #expect(source.contains("state.deleteSavedSearchView"))
        #expect(source.contains("savedViewEditorPresented"))
    }

    @Test("菜单栏按稳定 ID 应用视图后打开搜索面板")
    func statusBarQuickOpenUsesStableID() throws {
        let statusBar = try r32Source("Sources/duo-pasted/StatusBarController.swift")
        let delegate = try r32Source("Sources/duo-pasted/AppDelegate.swift")

        #expect(statusBar.contains("updateSavedSearchViews"))
        #expect(statusBar.contains("representedObject = view.id"))
        #expect(statusBar.contains("AppDelegate.shared?.openSavedSearchView(id: id)"))
        #expect(delegate.contains("state.applySavedSearchView(id: id)"))
        #expect(delegate.contains("panel.show()"))
    }
}

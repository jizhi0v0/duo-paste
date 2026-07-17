import Foundation
import Testing

@Suite("macOS search loading UI contract")
struct SearchLoadingUIContractTests {
    @Test("search task owns a visible accessible loading indicator")
    func searchTaskShowsLoading() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/duo-pasted/AppState.swift")
        )
        let searchView = try String(
            contentsOf: root.appendingPathComponent("Sources/duo-pasted/SearchView.swift")
        )

        #expect(appState.contains("var isSearching: Bool"))
        #expect(searchView.contains("state.beginSearchLoading()"))
        #expect(searchView.contains("state.endSearchLoading(token)"))
        #expect(searchView.contains("if state.isSearching"))
        #expect(searchView.contains("ProgressView()"))
        #expect(searchView.contains(".accessibilityLabel(\"正在搜索\")"))
    }

    @Test("clearing restores the cached empty-query result before background validation")
    func clearingRestoresCachedLibrary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/duo-pasted/AppState.swift")
        )
        let searchView = try String(
            contentsOf: root.appendingPathComponent("Sources/duo-pasted/SearchView.swift")
        )

        #expect(appState.contains("func restoreCachedEmptySearch() -> Bool"))
        #expect(appState.contains("cachedEmptySearch ="))
        #expect(searchView.contains("let restored = state.restoreCachedEmptySearch()"))
        #expect(searchView.contains("state.endSearchLoading(token)"))
    }
}

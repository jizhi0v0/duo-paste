import Testing
@testable import DuoPasteCore

@Suite("Search refresh policy")
struct SearchRefreshPolicyTests {
    @Test("clearing the search input refreshes immediately")
    func emptyQueryHasNoDebounce() {
        #expect(SearchRefreshPolicy.delayNanoseconds(for: "") == 0)
    }

    @Test("typing a non-empty query keeps the keystroke debounce")
    func nonEmptyQueryIsDebounced() {
        #expect(SearchRefreshPolicy.delayNanoseconds(for: "hello") == 60_000_000)
    }

    @Test("a cancelled older search cannot hide a newer search's loading state")
    func staleCompletionDoesNotClearLatestLoading() {
        var tracker = SearchLoadingTracker()
        let older = tracker.begin()
        let newer = tracker.begin()

        tracker.end(older)
        #expect(tracker.isLoading)

        tracker.end(newer)
        #expect(!tracker.isLoading)
    }
}

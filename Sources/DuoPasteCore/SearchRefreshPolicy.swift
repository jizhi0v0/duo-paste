/// Search refresh timing shared by the UI and performance benchmark.
///
/// Keystrokes are briefly coalesced to avoid starting an FTS query for every character. Clearing
/// the input is different: users expect the complete library to come back immediately, so an empty
/// query deliberately bypasses the debounce.
public enum SearchRefreshPolicy {
    public static let typingDelayNanoseconds: UInt64 = 60_000_000

    public static func delayNanoseconds(for query: String) -> UInt64 {
        query.isEmpty ? 0 : typingDelayNanoseconds
    }
}

/// Owns the visible loading state for replaceable searches.
///
/// Search tasks are cancelled and replaced while the user types. An older task may observe its
/// cancellation after the replacement has already started, so only the latest token may clear the
/// loading state.
public struct SearchLoadingTracker: Sendable {
    private var latestToken: UInt64 = 0
    public private(set) var isLoading = false

    public init() {}

    public mutating func begin() -> UInt64 {
        latestToken &+= 1
        isLoading = true
        return latestToken
    }

    public mutating func end(_ token: UInt64) {
        guard token == latestToken else { return }
        isLoading = false
    }
}

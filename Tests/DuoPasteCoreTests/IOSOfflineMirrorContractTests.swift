import Foundation
import Testing

private func r21Source(_ relativePath: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile
        .deletingLastPathComponent() // DuoPasteCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@Suite("R2.1 iOS offline mirror source contract")
struct IOSOfflineMirrorContractTests {
    @Test func foregroundAndBackgroundUseTheSQLitePageWriter() throws {
        let coordinator = try r21Source("iOS/DuoPaste/PeerSyncCoordinator.swift")
        let background = try r21Source("iOS/DuoPaste/BackgroundPullService.swift")

        #expect(coordinator.contains("store.synchronizeMetadata"))
        #expect(background.contains("mirror.synchronize"))
        #expect(coordinator.contains("backfillPages"))
        #expect(!coordinator.contains("PersistedCursor"))
        #expect(!background.contains("PersistedCursor"))
        #expect(!background.contains("items.json"))
    }

    @Test func historySearchNeverCallsThePeerSearchEndpoint() throws {
        let view = try r21Source("iOS/DuoPaste/HistoryView.swift")
        let coordinator = try r21Source("iOS/DuoPaste/PeerSyncCoordinator.swift")
        let client = try r21Source("iOS/DuoPaste/PeerClient.swift")

        #expect(view.contains("store.searchLocal"))
        #expect(!view.contains("searchOnServer"))
        #expect(!coordinator.contains("func searchOnServer"))
        #expect(!coordinator.contains("searchItems("))
        #expect(!client.contains("func searchItems"))
    }

    @Test func legacyJSONIsOnlyAOneTimeVerifiedImport() throws {
        let store = try r21Source("iOS/DuoPaste/HistoryStore.swift")

        #expect(store.contains("mirror.importLegacyItems"))
        #expect(store.contains("mirror.containsItemIDs"))
        #expect(store.contains("removeItem(at: Self.itemsFile)"))
        #expect(!store.contains("func persist("))
    }
}

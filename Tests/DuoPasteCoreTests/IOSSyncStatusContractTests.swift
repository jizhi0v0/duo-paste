import Foundation
import Testing

private func r22Source(_ relativePath: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@Suite("R2.2 iOS sync progress and offline state source contract")
struct IOSSyncStatusContractTests {
    @Test func historyExposesProgressStrictnessPeerAndLastSuccess() throws {
        let store = try r22Source("iOS/DuoPaste/HistoryStore.swift")
        let view = try r22Source("iOS/DuoPaste/HistoryView.swift")

        #expect(store.contains("MetadataMirrorSyncProgress"))
        #expect(store.contains("lastSuccessAt"))
        #expect(store.contains("isStrictlyCaughtUp"))
        #expect(store.contains("currentPeer"))
        #expect(view.contains("syncStatusCard"))
        #expect(view.contains("已严格追平"))
        #expect(view.contains("正在重建"))
    }

    @Test func foregroundCanCancelResumeAndRefreshWithoutClearingTheCursor() throws {
        let coordinator = try r22Source("iOS/DuoPaste/PeerSyncCoordinator.swift")
        let view = try r22Source("iOS/DuoPaste/HistoryView.swift")

        #expect(coordinator.contains("func cancelPull()"))
        #expect(coordinator.contains("store.markSyncPaused"))
        #expect(coordinator.contains("store.isSyncPausedByUser"))
        #expect(view.contains("继续同步"))
        #expect(view.contains("立即刷新"))
        #expect(view.contains("coordinator.cancelPull()"))
    }

    @Test func durableCheckpointLivesOutsideCachesAndBackgroundPullUpdatesIt() throws {
        let store = try r22Source("iOS/DuoPaste/HistoryStore.swift")
        let background = try r22Source("iOS/DuoPaste/BackgroundPullService.swift")

        #expect(store.contains(".applicationSupportDirectory"))
        #expect(store.contains("syncCheckpointFile"))
        #expect(background.contains("MetadataMirrorSyncCheckpointStore"))
        #expect(background.contains("lastSuccessAt"))
        #expect(background.contains("syncPausedDefaultsKey"))
    }
}

import Foundation
import Testing
@testable import DuoPasteCore

@Suite("iOS metadata mirror durable sync state")
struct MetadataMirrorSyncStateTests {
    @Test func checkpointRoundTripsOutsideTheEvictableMirror() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("duo-ios-sync-state-\(UUID().uuidString)", isDirectory: true)
        let path = root.appendingPathComponent("sync-checkpoint.json")
        let store = MetadataMirrorSyncCheckpointStore(path: path)
        let checkpoint = MetadataMirrorSyncCheckpoint(
            lastSuccessAt: Date(timeIntervalSince1970: 123),
            lastPeerDeviceID: "mac-a",
            lastLocalItemCount: 1_500,
            lastSourceTrackedItemCount: 1_200,
            lastServerTotalCount: 1_200,
            finalCursor: SinceCursor(ingestedAtNs: 999, id: "last")
        )

        #expect(try store.load() == nil)
        try store.save(checkpoint)
        #expect(try store.load() == checkpoint)
    }

    @Test func missingPreviouslyCompleteCacheIsClassifiedAsRebuilding() {
        let checkpoint = MetadataMirrorSyncCheckpoint(
            lastSuccessAt: Date(timeIntervalSince1970: 123),
            lastPeerDeviceID: "mac-a",
            lastLocalItemCount: 1_500,
            lastSourceTrackedItemCount: 1_200,
            lastServerTotalCount: 1_200,
            finalCursor: SinceCursor(ingestedAtNs: 999, id: "last")
        )

        #expect(MetadataMirrorBootstrapDisposition.classify(
            mirrorFileExisted: false,
            localItemCount: 0,
            cursor: .zero,
            checkpoint: checkpoint
        ) == .rebuilding)
        #expect(MetadataMirrorBootstrapDisposition.classify(
            mirrorFileExisted: true,
            localItemCount: 100,
            cursor: SinceCursor(ingestedAtNs: 100, id: "partial"),
            checkpoint: checkpoint
        ) == .rebuilding)
    }

    @Test func freshExistingAndVerifiedCachesHaveDistinctBootstrapStates() {
        #expect(MetadataMirrorBootstrapDisposition.classify(
            mirrorFileExisted: false,
            localItemCount: 0,
            cursor: .zero,
            checkpoint: nil
        ) == .initialSync)
        #expect(MetadataMirrorBootstrapDisposition.classify(
            mirrorFileExisted: true,
            localItemCount: 10,
            cursor: SinceCursor(ingestedAtNs: 10, id: "ten"),
            checkpoint: nil
        ) == .verifyingExistingCache)

        let checkpoint = MetadataMirrorSyncCheckpoint(
            lastSuccessAt: Date(timeIntervalSince1970: 123),
            lastPeerDeviceID: "mac-a",
            lastLocalItemCount: 10,
            lastSourceTrackedItemCount: 10,
            lastServerTotalCount: 10,
            finalCursor: SinceCursor(ingestedAtNs: 10, id: "ten")
        )
        #expect(MetadataMirrorBootstrapDisposition.classify(
            mirrorFileExisted: true,
            localItemCount: 10,
            cursor: SinceCursor(ingestedAtNs: 10, id: "ten"),
            checkpoint: checkpoint
        ) == .ready(checkpoint))
    }
}

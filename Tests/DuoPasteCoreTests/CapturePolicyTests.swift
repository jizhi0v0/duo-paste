import CryptoKit
import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

private func makeCapturePolicyFixture() throws -> (Paths, CaptureService, DuoPasteCore.Database) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-capture-policy-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let database = try DuoPasteCore.Database(path: paths.mainDB)
    let limits = Config.CaptureLimits(
        maxBlobBytes: 1024,
        maxTextBytes: 1024,
        excludedBundleIDs: ["com.example.SecretApp"]
    )
    let service = CaptureService(
        database: database,
        blobs: BlobStore(root: paths.blobsDir),
        deviceID: "capture-policy-test",
        limits: limits
    )
    return (paths, service, database)
}

private func itemCount(_ database: DuoPasteCore.Database) async throws -> Int {
    try await database.pool.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
}

@Test func captureConfigExcludedBundleIDsDefaultAndRoundTrip() throws {
    #expect(Config.CaptureLimits.default.excludedBundleIDs.isEmpty)

    let json = Data(#"{"max_blob_mb":32,"max_text_kb":512,"excluded_bundle_ids":["com.apple.Notes","com.example.Secret"]}"#.utf8)
    let decoded = try JSONDecoder().decode(Config.CaptureLimits.self, from: json)
    #expect(decoded.excludedBundleIDs == ["com.apple.Notes", "com.example.Secret"])

    let encoded = try JSONEncoder().encode(decoded)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["excluded_bundle_ids"] as? [String] == ["com.apple.Notes", "com.example.Secret"])
}

@Test func capturePolicyNormalizesBundleIDsAndHonorsPause() {
    let policy = CapturePolicy(excludedBundleIDs: ["  COM.Example.SecretApp  "])
    #expect(policy.decision(sourceAppBundleID: nil) == .allow)
    #expect(policy.decision(sourceAppBundleID: "com.example.other") == .allow)
    #expect(
        policy.decision(sourceAppBundleID: "com.example.secretapp")
            == .excludedApp(bundleID: "com.example.secretapp")
    )

    let now = Date(timeIntervalSince1970: 1_000)
    let timed = CapturePause.until(now.addingTimeInterval(300))
    #expect(timed.isActive(at: now.addingTimeInterval(299.9)))
    #expect(!timed.isActive(at: now.addingTimeInterval(300)))
    #expect(CapturePause.untilResumed.isActive(at: now.addingTimeInterval(99_999)))
    #expect(
        policy.decision(
            sourceAppBundleID: "com.example.other",
            pause: timed,
            now: now
        ) == .paused
    )
}

@Test func captureServiceExcludedAndPausedPathsWriteNothing() async throws {
    let (paths, service, database) = try makeCapturePolicyFixture()

    let excludedText = CapturedPasteboard(
        kind: .text,
        text: "must-never-persist",
        sourceAppBundleID: "COM.EXAMPLE.SECRETAPP",
        capturedAtNs: 1_000
    )
    let textResult = try await service.ingest(excludedText)
    #expect(textResult.outcome == .skippedExcludedApp(bundleID: "COM.EXAMPLE.SECRETAPP"))

    let bytes = Data([0xCA, 0xFE, 0xBA, 0xBE])
    let excludedBlob = CapturedPasteboard(
        kind: .image,
        blob: bytes,
        blobExt: "png",
        blobMime: "image/png",
        sourceAppBundleID: "com.example.secretapp",
        capturedAtNs: 2_000
    )
    let blobResult = try await service.ingest(excludedBlob)
    #expect(blobResult.outcome == .skippedExcludedApp(bundleID: "com.example.secretapp"))
    let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(!BlobStore(root: paths.blobsDir).exists(sha256: sha))

    let pauseNow = Date(timeIntervalSince1970: 2_000)
    let pausedResult = try await service.ingest(
        CapturedPasteboard(
            kind: .text,
            text: "paused-must-never-persist",
            sourceAppBundleID: "com.example.allowed",
            capturedAtNs: 3_000
        ),
        pause: .until(pauseNow.addingTimeInterval(300)),
        now: pauseNow
    )
    #expect(pausedResult.outcome == .skippedPaused)
    #expect(try await itemCount(database) == 0)
}

@Test func expiredPauseAllowsCaptureAgain() async throws {
    let (_, service, database) = try makeCapturePolicyFixture()
    let now = Date(timeIntervalSince1970: 3_000)
    let result = try await service.ingest(
        CapturedPasteboard(
            kind: .text,
            text: "capture-resumed",
            sourceAppBundleID: "com.example.allowed",
            capturedAtNs: 4_000
        ),
        pause: .until(now),
        now: now
    )
    #expect(result.outcome == .inserted)
    #expect(try await itemCount(database) == 1)
}

import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-ocr-worker-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct TestEnv {
    let paths: Paths
    let db: DuoPasteCore.Database
    let blobs: BlobStore
    let deviceID: String
}

private func makeEnv(deviceID: String = "self-device") throws -> TestEnv {
    let paths = Paths(root: tempDir())
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB, role: .primary)
    let blobs = BlobStore(root: paths.blobsDir)
    return TestEnv(paths: paths, db: db, blobs: blobs, deviceID: deviceID)
}

/// 落一个 fake "image" blob 字节到 BlobStore，返回 sha。OCR 不用真图，stub recognizer
/// 看 URL.lastPathComponent 决策。
private func seedBlob(_ env: TestEnv, content: String = "fake-image-bytes") throws -> String {
    let data = content.data(using: .utf8)!
    let info = try env.blobs.put(data, ext: "png")
    return info.sha256
}

private func seedItem(
    _ env: TestEnv,
    id: String,
    originDevice: String,
    kind: ItemKind = .image,
    ocrState: OCRState? = .pending,
    blobSha: String? = nil,
    capturedAtNs: Int64 = 1_700_000_000_000_000_000,
    deletedAtNs: Int64? = nil
) throws {
    let it = Item(
        id: id,
        originDevice: originDevice,
        capturedAtNs: capturedAtNs,
        kind: kind,
        preview: "preview-\(id)",
        blobSha256: blobSha,
        deletedAtNs: deletedAtNs,
        pushState: .acked,
        ocrState: ocrState
    )
    try env.db.pool.write { try it.insert($0) }
}

private func fetchItem(_ env: TestEnv, id: String) throws -> Item? {
    try env.db.pool.read { conn in
        try Item.filter(Column("id") == id).fetchOne(conn)
    }
}

/// 给 worker 一个极小化 config：idle 短 / pause 0 / batch 大，让 tick 测试不等
private func fastConfig(maxAttempts: Int = 3, maxBlobMB: Int = 16) -> OCRWorker.Config {
    OCRWorker.Config(
        idleIntervalSec: 0.05,
        perItemPauseMs: 0,
        maxAttempts: maxAttempts,
        batchSize: 50,
        maxBlobBytes: maxBlobMB * 1024 * 1024,
        languages: ["en-US"]
    )
}

@Test func ocrWorkerProcessesPendingOwnOriginImage() async throws {
    let env = try makeEnv()
    let sha = try seedBlob(env)
    try seedItem(env, id: "img-1", originDevice: env.deviceID, blobSha: sha)
    // stub 表用 sha（不带 ext）也能匹配
    let recorder = OCRCallRecorder()
    let recognizer = StubOCRRecognizer(
        table: [sha: .success(OCRResult(text: "hello world"))],
        recorder: recorder
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let result = await w.tick()
    #expect(result.processed == 1)
    #expect(result.done == 1)
    let after = try fetchItem(env, id: "img-1")
    #expect(after?.ocrState == .done)
    #expect(after?.textFull == "hello world")
    #expect(after?.ingestedAtNs != nil)
    #expect(await recorder.count() == 1)
}

@Test func ocrWorkerSkipsOtherOriginImages() async throws {
    let env = try makeEnv()
    let sha = try seedBlob(env)
    try seedItem(env, id: "other-img", originDevice: "someone-else", blobSha: sha)
    let recorder = OCRCallRecorder()
    let recognizer = StubOCRRecognizer(
        table: [sha: .success(OCRResult(text: "should not appear"))],
        recorder: recorder
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let r = await w.tick()
    #expect(r.processed == 0)
    let after = try fetchItem(env, id: "other-img")
    #expect(after?.ocrState == .pending)  // 状态不变
    #expect(after?.textFull == nil)
    #expect(await recorder.count() == 0)
}

@Test func ocrWorkerSkipsNonImageKind() async throws {
    let env = try makeEnv()
    try seedItem(env, id: "txt-1", originDevice: env.deviceID, kind: .text, ocrState: nil)
    let recorder = OCRCallRecorder()
    let recognizer = StubOCRRecognizer(recorder: recorder)
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let r = await w.tick()
    #expect(r.processed == 0)
    #expect(await recorder.count() == 0)
}

@Test func ocrWorkerSkipsSoftDeleted() async throws {
    let env = try makeEnv()
    let sha = try seedBlob(env)
    try seedItem(env, id: "deleted-img", originDevice: env.deviceID,
                 blobSha: sha, deletedAtNs: 999)
    let recorder = OCRCallRecorder()
    let recognizer = StubOCRRecognizer(
        table: [sha: .success(OCRResult(text: "x"))],
        recorder: recorder
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let r = await w.tick()
    #expect(r.processed == 0)
    #expect(await recorder.count() == 0)
}

@Test func ocrWorkerMarksDoneEvenWithEmptyText() async throws {
    let env = try makeEnv()
    let sha = try seedBlob(env)
    try seedItem(env, id: "blank-img", originDevice: env.deviceID, blobSha: sha)
    let recognizer = StubOCRRecognizer(
        table: [sha: .success(OCRResult(text: ""))]
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let r = await w.tick()
    #expect(r.done == 1)
    let after = try fetchItem(env, id: "blank-img")
    #expect(after?.ocrState == .done)
    #expect(after?.textFull == nil)  // 空字符串归一化为 nil（不变量 #3）
}

@Test func ocrWorkerSkipsWhenBlobMissing() async throws {
    let env = try makeEnv()
    // 故意造 sha 不落盘——recognizer 不会被调到（worker 在 locate 阶段就跳过）
    let fakeSha = String(repeating: "f", count: 64)
    try seedItem(env, id: "no-blob", originDevice: env.deviceID, blobSha: fakeSha)
    let recorder = OCRCallRecorder()
    let recognizer = StubOCRRecognizer(recorder: recorder)
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let r = await w.tick()
    #expect(r.skipped == 1)
    let after = try fetchItem(env, id: "no-blob")
    #expect(after?.ocrState == .skipped)
    #expect(after?.lastPushError?.contains("blob missing") == true)
    #expect(await recorder.count() == 0)
}

@Test func ocrWorkerSkipsWhenBlobTooLarge() async throws {
    let env = try makeEnv()
    // 写一个 2KB blob，config cap 设 0MB → 任何 blob 都超 cap
    let sha = try seedBlob(env, content: String(repeating: "x", count: 2048))
    try seedItem(env, id: "huge-img", originDevice: env.deviceID, blobSha: sha)
    let recorder = OCRCallRecorder()
    let recognizer = StubOCRRecognizer(
        table: [sha: .success(OCRResult(text: "should-not-run"))],
        recorder: recorder
    )
    // maxBlobBytes 用一个比真实文件小的值：构造 cap=1KB
    var cfg = fastConfig()
    cfg.maxBlobBytes = 1024
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: cfg
    )
    let r = await w.tick()
    #expect(r.skipped == 1)
    let after = try fetchItem(env, id: "huge-img")
    #expect(after?.ocrState == .skipped)
    #expect(after?.lastPushError?.contains("blob too large") == true)
    #expect(await recorder.count() == 0)
}

@Test func ocrWorkerSkipsOnImageLoadFailure() async throws {
    let env = try makeEnv()
    let sha = try seedBlob(env)
    try seedItem(env, id: "bad-img", originDevice: env.deviceID, blobSha: sha)
    let recognizer = StubOCRRecognizer(
        table: [sha: .failure(.imageLoadFailed)]
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let r = await w.tick()
    #expect(r.skipped == 1)
    let after = try fetchItem(env, id: "bad-img")
    #expect(after?.ocrState == .skipped)
}

@Test func ocrWorkerSkipsOnPermanentVisionError() async throws {
    let env = try makeEnv()
    let sha = try seedBlob(env)
    try seedItem(env, id: "perm-err", originDevice: env.deviceID, blobSha: sha)
    let recognizer = StubOCRRecognizer(
        table: [sha: .failure(.visionPermanent(reason: "stub permanent"))]
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let r = await w.tick()
    #expect(r.skipped == 1)
    let after = try fetchItem(env, id: "perm-err")
    #expect(after?.ocrState == .skipped)
}

@Test func ocrWorkerRetriesTransientThenFailsAfterMaxAttempts() async throws {
    let env = try makeEnv()
    let sha = try seedBlob(env)
    try seedItem(env, id: "flaky", originDevice: env.deviceID, blobSha: sha)
    let recorder = OCRCallRecorder()
    let recognizer = AlwaysTransientRecognizer(recorder: recorder)
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig(maxAttempts: 3)
    )
    // 跑 3 个 tick：attempts 1 → 2 → 3 触发 max → 标 failed
    var lastResult = OCRWorker.TickResult()
    for _ in 0..<3 {
        lastResult = await w.tick()
    }
    let after = try fetchItem(env, id: "flaky")
    #expect(after?.ocrState == .failed)
    #expect(after?.lastPushError?.contains("max attempts") == true)
    #expect(lastResult.failed == 1)
    #expect(await recorder.count() == 3)
}

@Test func ocrWorkerCatchesUpOldestFirst() async throws {
    let env = try makeEnv()
    let sha1 = try seedBlob(env, content: "blob-1")
    let sha2 = try seedBlob(env, content: "blob-2")
    let sha3 = try seedBlob(env, content: "blob-3")
    try seedItem(env, id: "newest", originDevice: env.deviceID,
                 blobSha: sha3, capturedAtNs: 3000)
    try seedItem(env, id: "oldest", originDevice: env.deviceID,
                 blobSha: sha1, capturedAtNs: 1000)
    try seedItem(env, id: "middle", originDevice: env.deviceID,
                 blobSha: sha2, capturedAtNs: 2000)
    let recorder = OCRCallRecorder()
    let recognizer = StubOCRRecognizer(
        table: [
            sha1: .success(OCRResult(text: "one")),
            sha2: .success(OCRResult(text: "two")),
            sha3: .success(OCRResult(text: "three")),
        ],
        recorder: recorder
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let r = await w.tick()
    #expect(r.processed == 3)
    let calls = await recorder.snapshot()
    // 顺序应是 oldest → middle → newest（按 sha 前缀）
    #expect(calls.count == 3)
    #expect(calls[0].hasPrefix(sha1))
    #expect(calls[1].hasPrefix(sha2))
    #expect(calls[2].hasPrefix(sha3))
}

@Test func ocrWorkerWakeShortcutsIdleSleep() async throws {
    // 验证 wake() 能让 worker 处理新插入的 pending 行，不必等 idle interval。
    let env = try makeEnv()
    let recorder = OCRCallRecorder()
    let sha = try seedBlob(env)
    let recognizer = StubOCRRecognizer(
        table: [sha: .success(OCRResult(text: "woke"))],
        recorder: recorder
    )
    var cfg = fastConfig()
    cfg.idleIntervalSec = 60  // 故意大，验证不是等满
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: cfg
    )
    await w.start()
    // 让 worker 跑第一轮空 tick 进入 sleep
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(await recorder.count() == 0)
    // 插入新 image 并 wake
    try seedItem(env, id: "fresh", originDevice: env.deviceID, blobSha: sha)
    w.wake()
    // 给 worker 一点时间处理。CI 上 50ms × 20 = 1s 偶发抢不到 CPU，放宽到 3s 总
    // budget（60 × 50ms）让 wake → tick → DB write 链路在慢机器上也稳
    for _ in 0..<60 {
        if await recorder.count() > 0 { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    await w.stop()
    #expect(await recorder.count() >= 1)
    let after = try fetchItem(env, id: "fresh")
    #expect(after?.ocrState == .done)
    #expect(after?.textFull == "woke")
}

@Test func ocrWorkerMarkSkippedDoesNotClobberPushFailedLastError() async throws {
    // 不变量：last_push_error 列被 push / OCR 共享，OCR mark skipped/failed 时不该
    // 盖掉 push 真实失败的 last_push_error
    let env = try makeEnv()
    let sha = try seedBlob(env)
    // 故意造一个 push_state=failed 行，last_push_error 是 push 的真实错误
    let it = Item(
        id: "push-and-ocr-fail",
        originDevice: env.deviceID,
        capturedAtNs: 1_700_000_000_000_000_000,
        kind: .image,
        preview: "p",
        blobSha256: sha,
        pushState: .failed,
        lastPushError: "rejected: server returned 400",
        ocrState: .pending
    )
    try await env.db.pool.write { try it.insert($0) }
    // OCR recognizer 抛 imageLoadFailed → markSkipped 会想把 reason 写 last_push_error
    let recognizer = StubOCRRecognizer(
        table: [sha: .failure(.imageLoadFailed)]
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    _ = await w.tick()
    let after = try fetchItem(env, id: "push-and-ocr-fail")
    #expect(after?.ocrState == .skipped)
    // 但 last_push_error 保留 push 失败的真实原因
    #expect(after?.lastPushError == "rejected: server returned 400")
}

@Test func ocrWorkerBumpsIngestedAtNsOnMarkDone() async throws {
    let env = try makeEnv()
    let sha = try seedBlob(env)
    // seed 一个 ingestedAtNs = 100 让我们能验证 bump 后值变大
    let it = Item(
        id: "bump-test",
        originDevice: env.deviceID,
        capturedAtNs: 1_700_000_000_000_000_000,
        ingestedAtNs: 100,
        kind: .image,
        preview: "p",
        blobSha256: sha,
        pushState: .acked,
        ocrState: .pending
    )
    try await env.db.pool.write { try it.insert($0) }
    let recognizer = StubOCRRecognizer(
        table: [sha: .success(OCRResult(text: "bump"))]
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    _ = await w.tick()
    let after = try fetchItem(env, id: "bump-test")
    #expect(after?.ingestedAtNs != nil)
    #expect((after?.ingestedAtNs ?? 0) > 100)
}

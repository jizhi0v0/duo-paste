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
    let db = try DuoPasteCore.Database(path: paths.mainDB)
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
    #expect(after?.extractedText == "hello world")
    #expect(after?.extractedTextSource == .ocr)
    #expect(after?.textFull == nil)              // image kind text_full 永远 nil（v9 契约）
    #expect(after?.ingestedAtNs != nil)
    #expect(await recorder.count() == 1)
}

private actor OCRCursorAdvancedRecorder {
    private var ns: [Int64] = []
    func record(_ v: Int64) { ns.append(v) }
    func values() -> [Int64] { ns }
}

/// OCR Phase 2 不变量：markDone 必须触发注入的 onCursorAdvanced 闭包，让 server 端
/// broadcaster fan-out cursor_advanced 帧给对端 —— 不接的话对端要等 30s pull tick
/// 才同步 OCR 结果。
@Test func ocrWorkerMarkDoneTriggersOnCursorAdvanced() async throws {
    let env = try makeEnv()
    let sha = try seedBlob(env)
    try seedItem(env, id: "p2-img", originDevice: env.deviceID, blobSha: sha)
    let recognizer = StubOCRRecognizer(table: [sha: .success(OCRResult(text: "ocr text"))])
    let cursorRecorder = OCRCursorAdvancedRecorder()
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig(),
        onCursorAdvanced: { ns in
            Task { await cursorRecorder.record(ns) }
        }
    )
    let result = await w.tick()
    #expect(result.done == 1)
    // onCursorAdvanced 异步 Task → 等一小段让它落地
    try? await Task.sleep(nanoseconds: 100_000_000)
    let recorded = await cursorRecorder.values()
    #expect(recorded.count == 1)
    #expect((recorded.first ?? 0) > 0)
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
    #expect(after?.extractedText == nil)
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
    #expect(after?.extractedText == nil)  // 空字符串归一化为 nil（不变量 #3）
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
    #expect(await recorder.count() == 0)
}

@Test func ocrWorkerSkipsImageWithNullBlobSha() async throws {
    // legacy/corrupt image 行 sha 缺失。fetchPending **不**应过滤掉它们——
    // processOne 第一行 `guard let sha` 走 markSkipped 收敛掉，否则永卡 pending
    let env = try makeEnv()
    try seedItem(env, id: "no-sha-img", originDevice: env.deviceID, blobSha: nil)
    let recorder = OCRCallRecorder()
    let recognizer = StubOCRRecognizer(recorder: recorder)
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let r = await w.tick()
    #expect(r.skipped == 1)
    let after = try fetchItem(env, id: "no-sha-img")
    #expect(after?.ocrState == .skipped)
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
    // 等最终可观察状态而不是 recognizer 已被调用。recorder 先于 markDone 更新，若在它
    // 刚变为 1 时 stop worker，会取消尚未提交的 DB write，制造测试自己的竞态。
    for _ in 0..<60 {
        if let item = try fetchItem(env, id: "fresh"),
           item.ocrState == .done,
           item.extractedText == "woke" {
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    await w.stop()
    #expect(await recorder.count() >= 1)
    let after = try fetchItem(env, id: "fresh")
    #expect(after?.ocrState == .done)
    #expect(after?.extractedText == "woke")
}

/// 在 recognize() 内部触发软删的 recognizer，用来精准模拟 markDone 时 row 已是 tombstone。
/// fetchPending 已经排除了 deleted_at_ns IS NOT NULL 的行，所以普通 race 无法触发；
/// 这里跨 fetchPending 后、markDone 前的窗口
private struct SoftDeleteOnRecognize: OCRRecognizer {
    let id: String
    let db: DuoPasteCore.Database
    let result: OCRResult

    func recognize(imageURL: URL, languages: [String]) async throws -> OCRResult {
        let rowID = id
        try await db.pool.write { conn in
            try conn.execute(sql: "UPDATE item SET deleted_at_ns = ? WHERE id = ?",
                             arguments: [999, rowID])
        }
        return result
    }
}

@Test func ocrWorkerMarkDoneGuardsAgainstTombstoneRace() async throws {
    // 不变量：fetchPending → processOne 之间用户软删该行，markDone 的
    // `AND deleted_at_ns IS NULL` 守护必须过滤掉它，不把 OCR 结果写进 tombstone
    let env = try makeEnv()
    let sha = try seedBlob(env)
    try seedItem(env, id: "tombstone-race", originDevice: env.deviceID, blobSha: sha)
    let recognizer = SoftDeleteOnRecognize(
        id: "tombstone-race", db: env.db,
        result: OCRResult(text: "should not land")
    )
    let cursorRecorder = OCRCursorAdvancedRecorder()
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig(),
        onCursorAdvanced: { ns in
            Task { await cursorRecorder.record(ns) }
        }
    )
    _ = await w.tick()
    let after = try fetchItem(env, id: "tombstone-race")
    // 已被软删
    #expect(after?.deletedAtNs == 999)
    // markDone 的 guard 让 UPDATE 命中 0 行 —— extracted_text 没被写入
    #expect(after?.extractedText == nil)
    // UPDATE 0 行 不应触发 cursor_advanced fan-out —— 否则对端 PullWorker 收到空帧、
    // /since 拉空页浪费往返
    try? await Task.sleep(nanoseconds: 100_000_000)
    let recorded = await cursorRecorder.values()
    #expect(recorded.isEmpty, "UPDATE 0 行不应 broadcast，实际收到 \(recorded.count) 帧")
}

// PR 4 删了 push_state / last_push_error 列，原 ocrWorkerMarkSkippedDoesNotClobberPushFailedLastError
// 测试不再适用——OCR worker 现在只动 ocr_state 列，reason 走 stderr log。

@Test func ocrWorkerProcessesFileKindWithImageBlob() async throws {
    // v9 之后：用户从 Finder 复制 .png 文件路径 → kind=.file + blob_mime='image/png'
    // + blob_sha256 非空（PasteboardWatcher 给单 image-like 文件 URL 额外读字节）。
    // OCRWorker 应该扫这类行，OCR 文本进 extracted_text 让搜索能命中图里的字
    let env = try makeEnv()
    let sha = try seedBlob(env)
    let it = Item(
        id: "file-img-1",
        originDevice: env.deviceID,
        capturedAtNs: 1_700_000_000_000_000_000,
        kind: .file,
        preview: "screenshot.png",
        textFull: "/Users/bobby/Downloads/screenshot.png",  // file kind text_full = path
        blobSha256: sha,
        blobSize: 16,
        blobMime: "image/png",
        ocrState: .pending
    )
    try await env.db.pool.write { try it.insert($0) }
    let recognizer = StubOCRRecognizer(
        table: [sha: .success(OCRResult(text: "文本 折线图 柱状图"))]
    )
    let w = OCRWorker(
        database: env.db, blobs: env.blobs,
        recognizer: recognizer, originDevice: env.deviceID,
        config: fastConfig()
    )
    let result = await w.tick()
    #expect(result.processed == 1)
    #expect(result.done == 1)
    let after = try fetchItem(env, id: "file-img-1")
    #expect(after?.ocrState == .done)
    #expect(after?.extractedText == "文本 折线图 柱状图")
    #expect(after?.extractedTextSource == .ocr)
    // 关键：file kind text_full 不被 markDone 动 —— path 必须保留供 Finder reveal + paste-back
    #expect(after?.textFull == "/Users/bobby/Downloads/screenshot.png")
}

@Test func ocrWorkerSkipsFileKindWithNonImageBlob() async throws {
    // file kind 但 blob_mime 不是 image/*（比如 video/mp4 / application/pdf）应被
    // fetchPending 谓词过滤，不进 batch
    let env = try makeEnv()
    let sha = try seedBlob(env)
    let it = Item(
        id: "file-mp4",
        originDevice: env.deviceID,
        capturedAtNs: 1_700_000_000_000_000_000,
        kind: .file,
        preview: "video.mp4",
        textFull: "/tmp/video.mp4",
        blobSha256: sha,
        blobMime: "video/mp4",
        ocrState: .pending             // 即便 state=pending,谓词过滤掉 mp4 不走 OCR
    )
    try await env.db.pool.write { try it.insert($0) }
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
    let after = try fetchItem(env, id: "file-mp4")
    #expect(after?.ocrState == .pending)   // 状态不变
}

@Test func ocrWorkerSkipsFileKindWithoutBlobSha() async throws {
    // file kind 路径串行(c.blob=nil 走 ingestText) → blob_mime 跟 blob_sha256 都 nil
    // 即使有 image 路径后缀,fetchPending 谓词 `blob_sha256 IS NOT NULL` 兜底过滤
    let env = try makeEnv()
    let it = Item(
        id: "file-path-only",
        originDevice: env.deviceID,
        capturedAtNs: 1_700_000_000_000_000_000,
        kind: .file,
        preview: "screenshot.png",
        textFull: "/some/path/screenshot.png",
        ocrState: .pending             // 历史数据可能误标 pending 也不应被扫
    )
    try await env.db.pool.write { try it.insert($0) }
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

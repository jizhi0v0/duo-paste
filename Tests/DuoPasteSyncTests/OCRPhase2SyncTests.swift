import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// OCR Phase 2 跨设备同步：mini 端 OCR 完成后 ocr_state=done + extracted_text 写入，
/// 对端 PullWorker 通过 /since 拉到这条更新，对端 item 表 ocr_state + extracted_text
/// 同步落地，FTS5 索引 OCR text 让对端搜索可命中。
///
/// 这是端到端 SQL 层验证：**不**起 server，模拟 mini → MBP 的状态推送。
/// 完整 HTTP 路径已经被 PullWorkerTests 覆盖（INSERT OR REPLACE 走 ocr_state +
/// extracted_text 列），这里专门钉死"OCR 结果跨设备 visible to search"语义。
///
/// v9 之后 OCR 文本走 `extracted_text` 列（独立于 `text_full`）。`text_full` 永远是
/// "原始可粘贴文本"——image kind 没有这个，所以永远 nil

private typealias DuoDB = DuoPasteCore.Database

private func makeDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-ocr-p2-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

@Test func pullWorkerApplyOverwritesPeerOCRStateAndExtractedText() async throws {
    // 模拟：MBP 上预先有一条 mini-origin image（pending，没 OCR text）
    // → PullWorker 拉到 mini 上同 id 的 OCR done 更新 → MBP 上 ocr_state 变 done +
    //   extracted_text 写入（v9 之后 OCR 文本不再装 text_full）
    let db = try makeDB()
    let mboPriorImage = Item(
        id: "mini-img-1",
        originDevice: "mini-device",
        capturedAtNs: 100,
        ingestedAtNs: 100,
        kind: .image,
        sourceAppName: "ScreenCapture",
        preview: "[image 100KB]",
        textFull: nil,             // image kind 永远 nil
        blobSha256: "deadbeef" + String(repeating: "0", count: 56),
        blobSize: 100 * 1024,
        blobMime: "image/png",
        ocrState: .pending
    )
    try await db.pool.write { try mboPriorImage.insert($0) }

    // mini 上 OCR 完成后这条 item 的状态：extracted_text 填好 + extracted_text_source='ocr'
    // + ocr_state=done + ingested_at_ns bump
    let oCRDone = Item(
        id: "mini-img-1",                       // 同 id
        originDevice: "mini-device",
        capturedAtNs: 100,
        ingestedAtNs: 500,                       // bump
        kind: .image,
        sourceAppName: "ScreenCapture",
        preview: "[image 100KB]",
        textFull: nil,                           // image kind 永远 nil（v9 契约）
        blobSha256: "deadbeef" + String(repeating: "0", count: 56),
        blobSize: 100 * 1024,
        blobMime: "image/png",
        ocrState: .done,
        extractedText: "OCR result text 文本识别结果",
        extractedTextSource: .ocr
    )

    // 模拟 PullWorker.applyPage 收到 OCR done 更新（INSERT OR REPLACE）
    let transport = OCRPhase2FakeTransport(
        pages: [SincePageWire(
            ok: true, count: 1, items: [oCRDone],
            nextCursor: SinceCursor(ingestedAtNs: 500, id: "mini-img-1"),
            hasMore: false
        )],
        healthDeviceID: "mini-device"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "mbp-device",
        expectedPeerDeviceID: "mini-device",
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runPullWorkerToCompletion(worker)

    // 验证：MBP 上同 id item 的 ocr_state 变 done + extracted_text 写入
    let after = try await db.pool.read { conn in
        try Item.filter(Column("id") == "mini-img-1").fetchOne(conn)
    }
    #expect(after?.ocrState == .done)
    #expect(after?.extractedText == "OCR result text 文本识别结果")
    #expect(after?.extractedTextSource == .ocr)
    #expect(after?.textFull == nil)              // image kind text_full 永远 nil
    #expect(after?.ingestedAtNs == 500)
}

@Test func pullWorkerApplyTriggersFTSIndexForOCRText() async throws {
    // OCR 结果的 extracted_text 通过 INSERT OR REPLACE 写入后，FTS5 trigger（item_au）应当
    // 自动重 index（v9 的 FTS5 表把 extracted_text 也纳入索引列）。MBP 上搜 OCR text 应能命中
    let db = try makeDB()
    // 预置：MBP 已有这条 image 的 pending 行（text_full=nil，extracted_text 也 nil）
    let prior = Item(
        id: "mini-img-2",
        originDevice: "mini-device",
        capturedAtNs: 200,
        ingestedAtNs: 200,
        kind: .image,
        preview: "[image 50KB]",
        blobSha256: "cafebabe" + String(repeating: "0", count: 56),
        blobSize: 50 * 1024,
        ocrState: .pending
    )
    try await db.pool.write { try prior.insert($0) }

    // 拉到 mini 端 OCR done 更新（含一段独特的可搜词 "灯泡 lighting"，装在 extracted_text）
    let oCRDone = Item(
        id: "mini-img-2",
        originDevice: "mini-device",
        capturedAtNs: 200,
        ingestedAtNs: 600,
        kind: .image,
        preview: "[image 50KB]",
        textFull: nil,                           // image kind 永远 nil
        blobSha256: "cafebabe" + String(repeating: "0", count: 56),
        blobSize: 50 * 1024,
        ocrState: .done,
        extractedText: "灯泡 lighting fixture installation manual page 3",
        extractedTextSource: .ocr
    )
    let transport = OCRPhase2FakeTransport(
        pages: [SincePageWire(
            ok: true, count: 1, items: [oCRDone],
            nextCursor: SinceCursor(ingestedAtNs: 600, id: "mini-img-2"),
            hasMore: false
        )],
        healthDeviceID: "mini-device"
    )
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "mbp-device",
        expectedPeerDeviceID: "mini-device",
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60)
    )
    await runPullWorkerToCompletion(worker)

    // FTS5 search 走 SearchAPI.searchHits — 搜独特词应命中这条 image
    let api = SearchAPI(database: db)
    let hits = try api.searchHits(SearchQuery(text: "lighting"))
    #expect(hits.count == 1)
    #expect(hits.first?.0.id == "mini-img-2")
    #expect(hits.first?.0.kind == .image)

    // 中文 token 也应命中（unicode61 tokenizer）
    let zhHits = try api.searchHits(SearchQuery(text: "灯泡"))
    #expect(zhHits.count == 1)
    #expect(zhHits.first?.0.id == "mini-img-2")
}

// markDone 触发 onCursorAdvanced 的测试在 OCRWorkerTests 里
// （那里能访问 internal `tick()` + 现成 StubOCRRecognizer）

// MARK: - Test fakes

private actor OCRPhase2FakeTransport: SinceTransport {
    private var pages: [SincePageWire]
    private let healthDeviceID: String
    init(pages: [SincePageWire], healthDeviceID: String) {
        self.pages = pages
        self.healthDeviceID = healthDeviceID
    }
    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        await self._fetchSince()
    }
    private func _fetchSince() async -> RemoteSinceResult {
        guard !pages.isEmpty else {
            return RemoteSinceResult(outcome: .unreachable(reason: "no more pages"))
        }
        return RemoteSinceResult(outcome: .ok(pages.removeFirst()))
    }
    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        PrimaryHealthResult(outcome: .ok(deviceID: healthDeviceID, nowMs: 1_000, ponteHost: nil))
    }
}

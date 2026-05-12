import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-cap-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeService(limits: Config.CaptureLimits) throws -> (CaptureService, DuoPasteCore.Database) {
    let paths = Paths(root: tempDir())
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB, role: .primary)
    let blobs = BlobStore(root: paths.blobsDir)
    let service = CaptureService(database: db, blobs: blobs, deviceID: "test", limits: limits)
    return (service, db)
}

@Test func captureSkipsBlobOverLimit() async throws {
    // 32MB cap → 33MB blob 应跳过，库里 0 行，blob 文件不生成
    let limits = Config.CaptureLimits(maxBlobBytes: 32 * 1024 * 1024, maxTextBytes: 512 * 1024)
    let (service, db) = try makeService(limits: limits)
    let bigBlob = Data(count: 33 * 1024 * 1024)
    let c = CapturedPasteboard(
        kind: .image,
        blob: bigBlob,
        blobExt: "png",
        blobMime: "image/png",
        capturedAtNs: 1_700_000_000_000_000_000
    )
    let r = try await service.ingest(c)
    if case .skippedTooLarge(let kind, let bytes, let limit) = r.outcome {
        #expect(kind == .blob)
        #expect(bytes == 33 * 1024 * 1024)
        #expect(limit == 32 * 1024 * 1024)
    } else {
        Issue.record("expected .skippedTooLarge, got \(r.outcome)")
    }
    #expect(r.item == nil)
    // 库里不应该有行
    let count = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(count == 0)
}

@Test func captureAcceptsBlobUnderLimit() async throws {
    // 边界：limit=10MB，9MB blob 应正常入库
    let limits = Config.CaptureLimits(maxBlobBytes: 10 * 1024 * 1024, maxTextBytes: 512 * 1024)
    let (service, db) = try makeService(limits: limits)
    let okBlob = Data(count: 9 * 1024 * 1024)
    let c = CapturedPasteboard(
        kind: .image, blob: okBlob, blobExt: "png", blobMime: "image/png",
        capturedAtNs: 1_700_000_000_000_000_000
    )
    let r = try await service.ingest(c)
    #expect(r.outcome == .inserted)
    let count = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(count == 1)
}

@Test func captureSkipsTextOverLimit() async throws {
    // 512KB cap → 1MB 文本应跳过
    let limits = Config.CaptureLimits(maxBlobBytes: 32 * 1024 * 1024, maxTextBytes: 512 * 1024)
    let (service, db) = try makeService(limits: limits)
    let bigText = String(repeating: "a", count: 600 * 1024)  // 600KB
    let c = CapturedPasteboard(
        kind: .text, text: bigText,
        capturedAtNs: 1_700_000_000_000_000_000
    )
    let r = try await service.ingest(c)
    if case .skippedTooLarge(let kind, let bytes, let limit) = r.outcome {
        #expect(kind == .text)
        #expect(bytes == 600 * 1024)
        #expect(limit == 512 * 1024)
    } else {
        Issue.record("expected .skippedTooLarge, got \(r.outcome)")
    }
    let count = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(count == 0)
}

@Test func captureTextAtExactLimitPasses() async throws {
    // 边界契约：`> limit` 不是 `>=`，等于 limit 时入库通过
    let limits = Config.CaptureLimits(maxBlobBytes: 1024, maxTextBytes: 100)
    let (service, db) = try makeService(limits: limits)
    let exact = String(repeating: "a", count: 100)
    let c = CapturedPasteboard(kind: .text, text: exact, capturedAtNs: 1)
    let r = try await service.ingest(c)
    #expect(r.outcome == .inserted)
    let count = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(count == 1)
}

@Test func captureMultibyteUTF8CountedByBytes() async throws {
    // 关键契约：cap 是字节数不是字符数。"中" UTF-8 占 3 字节，
    // 100 字节 limit 下放 34 个汉字 = 102 字节应被拒，33 个汉字 = 99 字节应通过
    let limits = Config.CaptureLimits(maxBlobBytes: 1024, maxTextBytes: 100)
    let (service, _) = try makeService(limits: limits)
    let tooBig = String(repeating: "中", count: 34)   // 102 字节
    let okSize = String(repeating: "中", count: 33)   // 99 字节
    #expect(tooBig.utf8.count == 102)
    #expect(okSize.utf8.count == 99)
    let r1 = try await service.ingest(CapturedPasteboard(kind: .text, text: tooBig, capturedAtNs: 1))
    if case .skippedTooLarge(let kind, let bytes, _) = r1.outcome {
        #expect(kind == .text)
        #expect(bytes == 102)
    } else {
        Issue.record("expected skippedTooLarge for 34 chinese chars")
    }
    let r2 = try await service.ingest(CapturedPasteboard(kind: .text, text: okSize, capturedAtNs: 2))
    #expect(r2.outcome == .inserted)
}

@Test func captureFilePathAlwaysPassesEvenWithTinyLimit() async throws {
    // 关键不变量：Finder 复制文件走 .file kind + 路径字符串，
    // 即使把 maxTextBytes 调到 100 字节，路径字符串永远入得了库
    let limits = Config.CaptureLimits(maxBlobBytes: 1024, maxTextBytes: 100)
    let (service, db) = try makeService(limits: limits)
    let path = "/Users/bobby/Movies/SomeProject.fcpbundle"  // 50 字节 < 100
    let c = CapturedPasteboard(
        kind: .file, text: path,
        capturedAtNs: 1_700_000_000_000_000_000
    )
    let r = try await service.ingest(c)
    #expect(r.outcome == .inserted)
    let stored = try await db.pool.read { conn in
        try Item.fetchOne(conn)
    }
    #expect(stored?.kind == .file)
    #expect(stored?.textFull == path)
    let _ = db
}

@Test func captureDefaultLimitsMatchDocumentedValues() throws {
    let d = Config.CaptureLimits.default
    #expect(d.maxBlobBytes == 32 * 1024 * 1024)
    #expect(d.maxTextBytes == 512 * 1024)
    #expect(d.mergeWindowSec == 300)
}

@Test func captureServiceMergeWindowDerivedFromLimits() async throws {
    // 关键契约：CaptureService 默认从 limits.mergeWindowSec 推导窗口，
    // 不再固定 2s。同内容 200s 后再次 ingest 应当 merge（300s 窗口内）
    let limits = Config.CaptureLimits(
        maxBlobBytes: 1024, maxTextBytes: 1024, mergeWindowSec: 300
    )
    let (service, db) = try makeService(limits: limits)
    let now: Int64 = 1_700_000_000_000_000_000
    let later = now + 200 * 1_000_000_000  // 200s 后
    let c1 = CapturedPasteboard(kind: .text, text: "same", capturedAtNs: now)
    let c2 = CapturedPasteboard(kind: .text, text: "same", capturedAtNs: later)
    let r1 = try await service.ingest(c1)
    #expect(r1.outcome == .inserted)
    let r2 = try await service.ingest(c2)
    #expect(r2.outcome == .mergedWithPrevious)
    let count = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(count == 1)
}

@Test func captureServiceMergeWindowZeroDisablesMerge() async throws {
    let limits = Config.CaptureLimits(
        maxBlobBytes: 1024, maxTextBytes: 1024, mergeWindowSec: 0
    )
    let (service, db) = try makeService(limits: limits)
    // 同 ns 也不 merge（窗口 = now - 0 = now，不包含 captured_at_ns == now 的旧行）
    // 用稍微靠后的 ns 模拟两次复制
    let r1 = try await service.ingest(CapturedPasteboard(
        kind: .text, text: "same", capturedAtNs: 1_700_000_000_000_000_000
    ))
    #expect(r1.outcome == .inserted)
    let r2 = try await service.ingest(CapturedPasteboard(
        kind: .text, text: "same", capturedAtNs: 1_700_000_000_000_000_001
    ))
    #expect(r2.outcome == .inserted)
    let count = try await db.pool.read { conn in
        try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? -1
    }
    #expect(count == 2)
}

@Test func captureLimitsDecodeFromJSON() throws {
    let json = #"""
    { "max_blob_mb": 16, "max_text_kb": 256 }
    """#.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.CaptureLimits.self, from: json)
    #expect(cfg.maxBlobBytes == 16 * 1024 * 1024)
    #expect(cfg.maxTextBytes == 256 * 1024)
}

@Test func captureLimitsDecodeMissingKeysFallsBackToDefault() throws {
    // 空 capture 段：两个字段都缺 → 用默认值
    let json = "{}".data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.CaptureLimits.self, from: json)
    #expect(cfg.maxBlobBytes == 32 * 1024 * 1024)
    #expect(cfg.maxTextBytes == 512 * 1024)
}

@Test func configWithoutCaptureSectionFallsBack() throws {
    // 老 config.json（没有 capture 段）→ 默认 limits 生效
    let json = """
    { "serve": true, "serve_host": "127.0.0.1", "serve_port": 8443 }
    """.data(using: .utf8)!
    let cfg = try JSONDecoder().decode(Config.self, from: json)
    #expect(cfg.capture.maxBlobBytes == 32 * 1024 * 1024)
    #expect(cfg.capture.maxTextBytes == 512 * 1024)
}

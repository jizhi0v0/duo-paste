import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-ocr-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeService() throws -> (CaptureService, DuoPasteCore.Database) {
    let paths = Paths(root: tempDir())
    paths.ensureExists()
    let db = try DuoPasteCore.Database(path: paths.mainDB)
    let blobs = BlobStore(root: paths.blobsDir)
    let service = CaptureService(database: db, blobs: blobs, deviceID: "test")
    return (service, db)
}

@Test func ingestImageMarksOcrStatePending() async throws {
    let (service, db) = try makeService()
    let c = CapturedPasteboard(
        kind: .image, blob: Data(count: 1024), blobExt: "png", blobMime: "image/png",
        capturedAtNs: 1_700_000_000_000_000_000
    )
    let r = try await service.ingest(c)
    #expect(r.outcome == .inserted)
    let row = try await db.pool.read { conn in
        try Item.fetchOne(conn)
    }
    #expect(row?.kind == .image)
    #expect(row?.ocrState == .pending)
}

@Test func ingestFileDoesNotMarkOcrState() async throws {
    // file kind 即使后缀是图片，也不参与 OCR（BlobStore 里没字节）
    let (service, db) = try makeService()
    let c = CapturedPasteboard(
        kind: .file, text: "/Users/x/screenshot.png",
        capturedAtNs: 1
    )
    let r = try await service.ingest(c)
    #expect(r.outcome == .inserted)
    let row = try await db.pool.read { conn in try Item.fetchOne(conn) }
    #expect(row?.kind == .file)
    #expect(row?.ocrState == nil)
}

@Test func ingestTextDoesNotMarkOcrState() async throws {
    let (service, db) = try makeService()
    let c = CapturedPasteboard(kind: .text, text: "hello", capturedAtNs: 1)
    let r = try await service.ingest(c)
    #expect(r.outcome == .inserted)
    let row = try await db.pool.read { conn in try Item.fetchOne(conn) }
    #expect(row?.ocrState == nil)
}

@Test func meshPeerImageIngestMarksPending() async throws {
    // mesh 拓扑下每台 mac 都是 peer，所有 image kind 入库即标 pending → 本机 OCR worker 处理
    let (service, db) = try makeService()
    let c = CapturedPasteboard(
        kind: .image, blob: Data(count: 256), blobExt: "png", blobMime: "image/png",
        capturedAtNs: 1
    )
    let r = try await service.ingest(c)
    #expect(r.outcome == .inserted)
    let row = try await db.pool.read { conn in try Item.fetchOne(conn) }
    #expect(row?.ocrState == .pending)
}

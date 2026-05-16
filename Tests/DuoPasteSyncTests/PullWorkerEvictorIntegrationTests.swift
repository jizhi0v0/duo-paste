import Testing
import Foundation
import GRDB
import CryptoKit
import DuoPasteCore
@testable import DuoPasteSync

/// PullWorker × BlobEvictor 端到端联动：mesh pull 跟 LRU/orphan 驱逐共用同一 BlobStore +
/// Database，本测试验证两边互不踩脚——
/// - PullWorker 拉新 blob 进 BlobStore（fetchBlobsFull 路径）
/// - 同时 BlobEvictor 清理孤儿（用户软删的老 blob）
/// - DB 行不被驱逐动；活跃行的 blob 不被误清
///
/// ENOSPC retry loop 本身在 [[blob-eviction-tests]] 用 mock put 闭包覆盖。真磁盘满
/// 通过 BlobStore.put 触发只能实机验，CI 不仿真。

private typealias DuoDB = DuoPasteCore.Database

private func makeDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-pw-evict-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func makeBlobs() -> BlobStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-blobs-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func insertImageRow(
    _ db: DuoDB,
    id: String, origin: String,
    sha: String, capturedAtNs: Int64,
    deletedAtNs: Int64? = nil,
    pinned: Bool = false
) throws {
    try db.pool.write { d in
        try d.execute(sql: """
            INSERT INTO item
              (id, origin_device, captured_at_ns, ingested_at_ns, kind,
               source_app, source_app_name, preview, text_full,
               blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
               ocr_state, extracted_text, extracted_text_source)
            VALUES (?, ?, ?, ?, 'image',
                    NULL, NULL, '[image]', NULL,
                    ?, 1024, 'image/png', ?, ?,
                    NULL, NULL, NULL)
        """, arguments: [
            id, origin, capturedAtNs, capturedAtNs,
            sha, pinned ? 1 : 0, deletedAtNs
        ])
    }
}

private func mkItem(
    id: String, origin: String, ingestedAtNs: Int64,
    blobSha: String, deletedAtNs: Int64? = nil
) -> Item {
    Item(
        id: id, originDevice: origin,
        capturedAtNs: ingestedAtNs, ingestedAtNs: ingestedAtNs,
        kind: .image,
        sourceAppName: "Test",
        preview: "[image]",
        blobSha256: blobSha, blobSize: 1024, blobMime: "image/png",
        deletedAtNs: deletedAtNs
    )
}

private func page(items: [Item], nextNs: Int64, nextID: String, hasMore: Bool) -> SincePageWire {
    SincePageWire(
        ok: true, count: items.count, items: items,
        nextCursor: SinceCursor(ingestedAtNs: nextNs, id: nextID),
        hasMore: hasMore
    )
}

private actor StubSinceTransport: SinceTransport {
    private var pages: [SincePageWire]
    private let healthDeviceID: String
    init(pages: [SincePageWire], healthDeviceID: String) {
        self.pages = pages; self.healthDeviceID = healthDeviceID
    }
    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        await self._fetch()
    }
    private func _fetch() -> RemoteSinceResult {
        guard !pages.isEmpty else {
            return RemoteSinceResult(outcome: .unreachable(reason: "no more pages"))
        }
        return RemoteSinceResult(outcome: .ok(pages.removeFirst()))
    }
    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        PrimaryHealthResult(outcome: .ok(deviceID: healthDeviceID, nowMs: 1_000, ponteHost: nil))
    }
}

private actor StubBlobFetcher: BlobFetcher {
    var script: [String: GetBlobOutcome] = [:]
    func set(_ sha: String, _ outcome: GetBlobOutcome) { script[sha] = outcome }
    nonisolated func getBlob(sha256: String) async throws -> GetBlobOutcome {
        await self._get(sha256)
    }
    private func _get(_ sha: String) -> GetBlobOutcome {
        script[sha] ?? .notFound
    }
}

private func runBriefly(_ w: PullWorker, ms: Int = 300) async {
    await w.start()
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    await w.stop()
}

// MARK: - 联动场景

/// 用户场景：本机 mirror 老 peer 行已软删（用户在对端 swipe-to-delete + /since 同步过来 DB
/// tombstone），blob 文件留着占空间。PullWorker 同时拉新行 + evictor drain 老孤儿。
@Test func pullWorkerFetchesNewBlobWhileEvictorDrainsOrphans() async throws {
    let db = try makeDB()
    let blobs = makeBlobs()

    // 预置 3 个孤儿：DB 行 origin=peer-A 已 tombstone，blob 字节仍在本机
    var orphanShas: [String] = []
    for i in 0..<3 {
        let bytes = Data(repeating: UInt8(0x10 + i), count: 100)
        let info = try blobs.put(bytes)
        try insertImageRow(
            db, id: "old-\(i)", origin: "peer-A",
            sha: info.sha256, capturedAtNs: Int64(1_000 + i),
            deletedAtNs: Int64(5_000 + i)
        )
        orphanShas.append(info.sha256)
    }

    // 预置 1 个活跃 peer 行 + blob——必须不被 evictor 误清（mesh 跨 origin 同 sha 已有
    // 单测覆盖；这里再验整链路下也不会被 PullWorker 写 + Evictor drain 互相干扰）
    let liveData = Data(repeating: 0x55, count: 100)
    let liveSha = sha256Hex(liveData)
    _ = try blobs.put(liveData)
    try insertImageRow(
        db, id: "live", origin: "peer-A",
        sha: liveSha, capturedAtNs: 2_000
    )

    // 新 blob —— PullWorker tick 要拉的
    let newBytes = Data(repeating: 0xEE, count: 200)
    let newSha = sha256Hex(newBytes)
    let newItem = mkItem(id: "new-img", origin: "peer-A",
                         ingestedAtNs: 9_000, blobSha: newSha)
    let transport = StubSinceTransport(
        pages: [page(items: [newItem], nextNs: 9_000, nextID: "new-img", hasMore: false)],
        healthDeviceID: "peer-A"
    )
    let fetcher = StubBlobFetcher()
    await fetcher.set(newSha, .found(newBytes))

    // BlobEvictor 走真实 LRU/orphan 路径
    let evictor = BlobEvictor(database: db, blobs: blobs)
    let evictOnFull: @Sendable () throws -> Bool = { try evictor.evictOneOldest() }

    let worker = PullWorker(
        database: db, transport: transport,
        selfDeviceID: "self", meshStatus: MeshStatus(),
        blobFetcher: fetcher, blobs: blobs,
        evictOnFull: evictOnFull,
        config: PullWorker.Config(intervalSec: 60, storageMode: .full)
    )
    await runBriefly(worker)

    // PullWorker 这一刀的结果——新 blob 落盘 + mirror 行写入
    #expect(blobs.exists(sha256: newSha))
    let mirroredIDs = try await db.pool.read { d in
        try Row.fetchAll(d, sql: "SELECT id FROM item ORDER BY captured_at_ns")
            .map { $0["id"] as String }
    }
    #expect(mirroredIDs.contains("new-img"))
    // PullWorker 不动孤儿——orphan drain 是单独路径
    for sha in orphanShas { #expect(blobs.exists(sha256: sha)) }

    // 现在跑 orphan drain
    let (freed, _) = try evictor.evictTombstoneBlobs()
    #expect(freed == 3)

    // 孤儿字节没了
    for sha in orphanShas { #expect(!blobs.exists(sha256: sha)) }
    // 活跃 blob + 新 blob 安然无恙
    #expect(blobs.exists(sha256: liveSha))
    #expect(blobs.exists(sha256: newSha))

    // DB 行**全部**保留（包括 3 个 tombstone 行——/since 仍要把删除状态同步到其他 peer）
    let totalRows = try await db.pool.read { d in
        try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM item") ?? 0
    }
    #expect(totalRows == 5)  // 3 orphan + 1 live + 1 new
    let tombstoneCount = try await db.pool.read { d in
        try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM item WHERE deleted_at_ns IS NOT NULL") ?? 0
    }
    #expect(tombstoneCount == 3)
}


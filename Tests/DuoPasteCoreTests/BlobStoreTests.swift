import Testing
import Foundation
import CryptoKit
@testable import DuoPasteCore

private func tempBlobStore(stats: BlobStorageStats? = nil) -> BlobStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-blobs-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root, stats: stats)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test func putVerifiedAcceptsMatchingSha() throws {
    let store = tempBlobStore()
    let data = Data((0..<256).map { UInt8($0 & 0xFF) })
    let expected = sha256Hex(data)
    let info = try store.putVerified(data, expectedSha256: expected)
    #expect(info.sha256 == expected)
    #expect(info.wasExisting == false)
    #expect(store.exists(sha256: expected))
    // 内容可读
    let readBack = try store.read(sha256: expected)
    #expect(readBack == data)
}

@Test func putVerifiedRejectsMismatchedSha() throws {
    let store = tempBlobStore()
    let data = Data((0..<128).map { UInt8($0) })
    let wrong = String(repeating: "00", count: 32)
    #expect(throws: BlobStoreError.self) {
        _ = try store.putVerified(data, expectedSha256: wrong)
    }
    // 不应写盘——store 干净
    #expect(!store.exists(sha256: wrong))
}

@Test func putVerifiedShortCircuitsWhenAlreadyExists() throws {
    let store = tempBlobStore()
    let data = Data([0x42, 0x42, 0x42])
    let sha = sha256Hex(data)
    // 第一次写
    let first = try store.putVerified(data, expectedSha256: sha)
    #expect(first.wasExisting == false)
    // 第二次写同 sha → wasExisting=true，不重复 IO
    let second = try store.putVerified(data, expectedSha256: sha)
    #expect(second.wasExisting == true)
    #expect(second.path == first.path)
}

@Test func putVerifiedPreservesByteOrder() throws {
    // 确认顺序 + size 计算没受 sha 校验路径污染
    let store = tempBlobStore()
    let data = Data((0..<10_000).map { UInt8($0 & 0xFF) })
    let sha = sha256Hex(data)
    let info = try store.putVerified(data, expectedSha256: sha, ext: "bin")
    #expect(info.size == 10_000)
    let read = try store.read(sha256: sha)
    #expect(read?.count == 10_000)
    #expect(read == data)
}

/// 并发 put 同 sha：BlobStorageStats 只能看到一份 size，不能重复计数。
/// 历史回归：旧 put 的 catch 分支检测到 target 已被赢家占领后仍走 notifyAdded(size)
/// 让 stats 每丢一次竞争就多算一份字节
@Test func concurrentPutSameShaCountsOnceInStats() async throws {
    let stats = BlobStorageStats()
    await stats.setBaseline(0)
    let store = tempBlobStore(stats: stats)
    let data = Data((0..<10_000).map { UInt8($0 & 0xFF) })

    // 起 16 个并发 put 同 sha——locate 与 moveItem 之间的窗口足够让多个进入 catch
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<16 {
            group.addTask {
                _ = try? store.put(data)
            }
        }
    }

    // BlobStorageStats.add 走 Task {} 异步喂入 actor。等到 actor 排队跑完
    try await Task.sleep(nanoseconds: 200_000_000)

    let bytes = await stats.current()
    #expect(bytes == 10_000, "并发 put 应只算一份字节，实际 \(String(describing: bytes))")
}

/// 当 BlobStore 路径上已经有 race winner 留下的 target 文件时（locate 一致命中），
/// 后到的 put 应当返回 wasExisting=true、不调 notifyAdded、并复用现存路径
@Test func putShortCircuitsWhenTargetAlreadyExists() async throws {
    let stats = BlobStorageStats()
    await stats.setBaseline(0)
    let store = tempBlobStore(stats: stats)
    let data = Data([0x42, 0x42, 0x42, 0x42, 0x42])
    // 第一次 put：wasExisting=false + 计入 stats
    let first = try store.put(data)
    #expect(first.wasExisting == false)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(await stats.current() == Int64(data.count))

    // 第二次 put 同 sha：wasExisting=true，stats 不再增长
    let second = try store.put(data)
    #expect(second.wasExisting == true)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(await stats.current() == Int64(data.count))
}

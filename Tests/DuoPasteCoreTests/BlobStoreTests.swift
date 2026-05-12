import Testing
import Foundation
import CryptoKit
@testable import DuoPasteCore

private func tempBlobStore() -> BlobStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-blobs-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root)
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

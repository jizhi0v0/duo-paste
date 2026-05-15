import Testing
import Foundation
@testable import DuoPasteCore

/// `Volume.availableBytes` 依赖系统卷不好 mock，单测覆盖 `directorySize` 即可。
/// 真 ENOSPC 路径只能实机验。

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-vol-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func directorySizeReturnsZeroForEmptyDir() {
    let dir = tempDir()
    #expect(Volume.directorySize(at: dir) == 0)
}

@Test func directorySizeSumsRegularFiles() throws {
    let dir = tempDir()
    try Data(repeating: 0xAA, count: 100).write(to: dir.appendingPathComponent("a.bin"))
    try Data(repeating: 0xBB, count: 250).write(to: dir.appendingPathComponent("b.bin"))
    #expect(Volume.directorySize(at: dir) == 350)
}

@Test func directorySizeRecursesIntoSubdirs() throws {
    let dir = tempDir()
    let sub1 = dir.appendingPathComponent("sub-1")
    let sub2 = dir.appendingPathComponent("sub-1/nested")
    try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)
    try Data(repeating: 0x01, count: 50).write(to: dir.appendingPathComponent("top.bin"))
    try Data(repeating: 0x02, count: 100).write(to: sub1.appendingPathComponent("mid.bin"))
    try Data(repeating: 0x03, count: 200).write(to: sub2.appendingPathComponent("deep.bin"))
    // BlobStore 用 <ab>/<cd>/<sha> 两级子目录——必须深度递归覆盖
    #expect(Volume.directorySize(at: dir) == 350)
}

@Test func directorySizeReturnsNilForNonexistentPath() {
    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-vol-missing-\(UUID().uuidString)", isDirectory: true)
    // 未创建 → enumerator 返回 nil → directorySize 返 nil
    #expect(Volume.directorySize(at: bogus) == nil)
}

@Test func directorySizeIgnoresDirectoryEntries() throws {
    // FileManager.enumerator 会迭代目录本身——我们只想数 regular file。
    // 测试：1 个空子目录 + 1 个文件 → 仅文件字节计入
    let dir = tempDir()
    let emptySub = dir.appendingPathComponent("empty-sub")
    try FileManager.default.createDirectory(at: emptySub, withIntermediateDirectories: true)
    try Data(repeating: 0xCC, count: 42).write(to: dir.appendingPathComponent("only.bin"))
    #expect(Volume.directorySize(at: dir) == 42)
}

@Test func directorySizeMatchesBlobStoreLayout() throws {
    // 模拟 BlobStore 真实布局 <ab>/<cd>/<sha>.png
    let dir = tempDir()
    let level1 = dir.appendingPathComponent("ab")
    let level2 = level1.appendingPathComponent("cd")
    try FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)
    let payload = Data(repeating: 0xAA, count: 1024)
    try payload.write(to: level2.appendingPathComponent("deadbeef.png"))
    #expect(Volume.directorySize(at: dir) == 1024)
}

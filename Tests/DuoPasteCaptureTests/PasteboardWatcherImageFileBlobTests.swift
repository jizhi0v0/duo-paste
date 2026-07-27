import Testing
import Foundation
@testable import DuoPasteCapture

/// `PasteboardWatcher.readImageFileBlob` 契约。
/// 背景（现网 case）：Telegram 复制媒体往剪贴板写的是指向自身 cache 的 **symlink**
/// （`telegram-cloud-photo-...-w.jpg` → 无后缀的 `-w`），且 target 懒 materialize——copy
/// 那一刻 symlink 已写好但字节还没落盘。旧实现单次 `Data(contentsOf:)` 读到 dangling 就
/// 静默降级成纯路径 capture，历史里留一张没缩略图的文件卡；且大小闸量的是 symlink 自身
/// （几十字节）而非真实 target，等于失效。本组测试钉住 resolve + 按真实大小守门 + 重试。

private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("dp-imgblob-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// 最小合法 PNG（1x1）——不校验解码，只验证字节被原样读出。
private let pngBytes: Data = {
    // 内容无所谓，readImageFileBlob 不 decode；用非空可辨认字节即可
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0xAB, count: 64)
}()

@Test func plainImageFileReadsBytes() throws {
    let dir = tmpDir()
    let file = dir.appendingPathComponent("shot.png")
    try pngBytes.write(to: file)

    let read = PasteboardWatcher.readImageFileBlob(at: file, maxBlobBytes: 1 << 20, sleep: { _ in })
    #expect(read?.data == pngBytes)
    #expect(read?.ext == "png")
    #expect(read?.mime == "image/png")
}

@Test func symlinkToMaterializedTargetResolvesAndReads() throws {
    let dir = tmpDir()
    // target 无后缀（模拟 Telegram 的 postbox/media/...-w），symlink 带 .jpg 后缀
    let target = dir.appendingPathComponent("media-w")
    try pngBytes.write(to: target)
    let link = dir.appendingPathComponent("telegram-cloud-photo-w.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let read = PasteboardWatcher.readImageFileBlob(at: link, maxBlobBytes: 1 << 20, sleep: { _ in })
    #expect(read?.data == pngBytes, "应 resolve symlink 读到 target 字节")
    // ext 取原始 link 后缀（target 没后缀），mime 随之
    #expect(read?.ext == "jpg")
    #expect(read?.mime == "image/jpeg")
}

@Test func danglingSymlinkMaterializesOnRetry() throws {
    let dir = tmpDir()
    let target = dir.appendingPathComponent("media-w")
    let link = dir.appendingPathComponent("telegram-cloud-photo-w.jpg")
    // 先只建 dangling symlink，target 尚不存在
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    // sleep 注入：第 2 次调用（第二轮重试的开头）才把 target 落盘，驱动重试路径
    var calls = 0
    let sleep: (Int) -> Void = { _ in
        calls += 1
        if calls == 2 { try? pngBytes.write(to: target) }
    }

    let read = PasteboardWatcher.readImageFileBlob(
        at: link, maxBlobBytes: 1 << 20, retryDelaysMs: [0, 0, 0], sleep: sleep
    )
    #expect(read?.data == pngBytes, "target 在重试间隙 materialize 后应被读到")
    #expect(calls >= 2, "首轮 dangling 应失败并进入下一轮，实际调用次数=\(calls)")
}

@Test func neverMaterializesReturnsNilAfterRetries() throws {
    let dir = tmpDir()
    let target = dir.appendingPathComponent("media-w")
    let link = dir.appendingPathComponent("telegram-cloud-photo-w.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    var calls = 0
    let read = PasteboardWatcher.readImageFileBlob(
        at: link, maxBlobBytes: 1 << 20, retryDelaysMs: [0, 0, 0],
        sleep: { _ in calls += 1 }
    )
    #expect(read == nil, "target 始终不存在 → 耗尽重试返回 nil，调用方降级纯路径")
    #expect(calls == 3, "应把 retryDelays 全部走完，实际=\(calls)")
}

@Test func oversizeTargetRejectedMeasuringResolvedNotSymlink() throws {
    // 反回归：大小闸必须量 resolve 后的真实 target，而不是 symlink 自身（几十字节）。
    // 旧 bug——量 symlink 大小让指向巨物的 symlink 也被全量读进内存。
    let dir = tmpDir()
    let big = Data(repeating: 0x00, count: 4096)
    let target = dir.appendingPathComponent("media-w")
    try big.write(to: target)
    let link = dir.appendingPathComponent("telegram-cloud-photo-w.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    // cap 小于真实 target（4096）但远大于 symlink 自身大小
    let read = PasteboardWatcher.readImageFileBlob(at: link, maxBlobBytes: 512, sleep: { _ in })
    #expect(read == nil, "resolve 后 4096 > cap 512 → 拒绝，不得因量错 symlink 大小而放行")

    // 放宽 cap 后同一 target 应可读，证明拒绝确实来自大小而非 resolve 失败
    let ok = PasteboardWatcher.readImageFileBlob(at: link, maxBlobBytes: 1 << 20, sleep: { _ in })
    #expect(ok?.data == big)
}

@Test func nonImageExtensionReturnsNil() throws {
    let dir = tmpDir()
    let file = dir.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: file)

    let read = PasteboardWatcher.readImageFileBlob(at: file, maxBlobBytes: 1 << 20, sleep: { _ in })
    #expect(read == nil, "非图片后缀不读字节，保持 .file 纯路径语义")
}

@Test func uuRemotePlaceholderPrefersImageRepresentation() {
    let first = URL(fileURLWithPath: "/private/tmp/.uuremote_aeawu02755850784238")
    let second = URL(fileURLWithPath: "/private/tmp/.uuremote_aeawu027503496827147")

    #expect(PasteboardWatcher.shouldPreferImagePayload(over: [first]))
    #expect(PasteboardWatcher.shouldPreferImagePayload(over: [first, second]))
}

@Test func ordinaryOrMixedFilesKeepFileFirstSemantics() {
    let ordinaryImage = URL(fileURLWithPath: "/Users/test/Desktop/photo.png")
    let uuPlaceholder = URL(fileURLWithPath: "/private/tmp/.uuremote_123")
    let misleadingDirectory = URL(fileURLWithPath: "/private/tmp/.uuremote_cache/report.pdf")

    #expect(!PasteboardWatcher.shouldPreferImagePayload(over: []))
    #expect(!PasteboardWatcher.shouldPreferImagePayload(over: [ordinaryImage]))
    #expect(!PasteboardWatcher.shouldPreferImagePayload(over: [uuPlaceholder, ordinaryImage]))
    #expect(!PasteboardWatcher.shouldPreferImagePayload(over: [misleadingDirectory]))
}

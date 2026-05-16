import Testing
import Foundation
@testable import DuoPasteCore

private func freshRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dpw-staging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeItem(
    kind: ItemKind,
    textFull: String? = nil,
    preview: String? = nil,
    blobSha256: String? = nil,
    blobMime: String? = nil
) -> Item {
    Item(
        id: UUID().uuidString,
        originDevice: "test",
        capturedAtNs: 1,
        kind: kind,
        preview: preview,
        textFull: textFull,
        blobSha256: blobSha256,
        blobMime: blobMime
    )
}

@Test func materializeTextWritesUTF8TxtFile() throws {
    let root = try freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blobs = BlobStore(root: root.appendingPathComponent("blobs"))   // 用不到

    let item = makeItem(kind: .text, textFull: "Hello\n世界", preview: "Hello 世界")
    let target = try OpenWithStaging.materialize(item: item, blobs: blobs, root: root)
    if case .fileURL(let url) = target {
        #expect(url.pathExtension == "txt")
        let read = try String(contentsOf: url, encoding: .utf8)
        #expect(read == "Hello\n世界")
        // 文件名 prefix 应包 sanitized preview
        let name = url.deletingPathExtension().lastPathComponent
        #expect(name.contains("Hello"))
    } else {
        Issue.record("text kind 应返回 .fileURL")
    }
}

@Test func materializeRTFUsesRtfExtension() throws {
    let root = try freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blobs = BlobStore(root: root.appendingPathComponent("blobs"))
    let item = makeItem(kind: .rtf, textFull: "{\\rtf1 hi}")
    let target = try OpenWithStaging.materialize(item: item, blobs: blobs, root: root)
    if case .fileURL(let url) = target {
        #expect(url.pathExtension == "rtf")
    } else {
        Issue.record("rtf 应返回 .fileURL")
    }
}

@Test func materializeHTMLUsesHtmlExtension() throws {
    let root = try freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blobs = BlobStore(root: root.appendingPathComponent("blobs"))
    let item = makeItem(kind: .html, textFull: "<p>hi</p>")
    let target = try OpenWithStaging.materialize(item: item, blobs: blobs, root: root)
    if case .fileURL(let url) = target {
        #expect(url.pathExtension == "html")
    } else {
        Issue.record("html 应返回 .fileURL")
    }
}

@Test func materializeURLReturnsWebURL() throws {
    let root = try freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blobs = BlobStore(root: root.appendingPathComponent("blobs"))
    let item = makeItem(kind: .url, textFull: "https://example.com/x?a=1")
    let target = try OpenWithStaging.materialize(item: item, blobs: blobs, root: root)
    if case .webURL(let url) = target {
        #expect(url.absoluteString == "https://example.com/x?a=1")
    } else {
        Issue.record("url kind 应返回 .webURL")
    }
}

@Test func materializeFileLocalPathReturnsOriginalURL() throws {
    let root = try freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blobs = BlobStore(root: root.appendingPathComponent("blobs"))

    // 建一个真实文件,模拟 .file kind 指向本机存在的路径
    let realFile = root.appendingPathComponent("real.md")
    try Data("# hi".utf8).write(to: realFile)

    let item = makeItem(kind: .file, textFull: realFile.path)
    let target = try OpenWithStaging.materialize(item: item, blobs: blobs, root: root)
    if case .fileURL(let url) = target {
        #expect(url.path == realFile.path, "本机路径存在应该原样返回不复制")
    } else {
        Issue.record("file 本地路径应是 .fileURL")
    }
}

@Test func materializeImageCopiesBlobToStaging() throws {
    let root = try freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blobsRoot = root.appendingPathComponent("blobs")
    try FileManager.default.createDirectory(at: blobsRoot, withIntermediateDirectories: true)
    let blobs = BlobStore(root: blobsRoot)
    // 写入一个假 png 字节让 BlobStore 落地真实文件
    let fakePNG = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: UInt8(0), count: 16))
    let blob = try blobs.put(fakePNG, ext: "png")

    let stagingRoot = root.appendingPathComponent("openwith-tmp")
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

    let item = makeItem(
        kind: .image,
        preview: "screenshot",
        blobSha256: blob.sha256,
        blobMime: "image/png"
    )
    let target = try OpenWithStaging.materialize(item: item, blobs: blobs, root: stagingRoot)
    if case .fileURL(let url) = target {
        #expect(url.pathExtension == "png")
        let copied = try Data(contentsOf: url)
        #expect(copied == fakePNG)
        // 真的复制了不是 hard link / symlink → blob 跟 staging 字节相同但 inode 不同
        let blobAttrs = try FileManager.default.attributesOfItem(atPath: blob.path.path)
        let stagingAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let blobInode = blobAttrs[.systemFileNumber] as? NSNumber
        let stagingInode = stagingAttrs[.systemFileNumber] as? NSNumber
        #expect(blobInode != stagingInode, "必须是真复制不能是 hard link,否则编辑器 truncate-write 会污染 blob")
    } else {
        Issue.record("image kind 应返回 .fileURL")
    }
}

@Test func materializeBlobMissingThrows() throws {
    let root = try freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blobs = BlobStore(root: root.appendingPathComponent("blobs"))
    // 不写入 blob → locate 返回 nil
    let item = makeItem(kind: .image, blobSha256: String(repeating: "a", count: 64))
    do {
        _ = try OpenWithStaging.materialize(item: item, blobs: blobs, root: root)
        Issue.record("应抛 MaterializationError.blobNotInStore")
    } catch let err as OpenWithStaging.MaterializationError {
        if case .blobNotInStore = err {
            // OK
        } else {
            Issue.record("应是 .blobNotInStore, 实际 \(err)")
        }
    }
}

@Test func materializeEmptyTextThrows() throws {
    let root = try freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let blobs = BlobStore(root: root.appendingPathComponent("blobs"))
    let item = makeItem(kind: .text, textFull: "")
    do {
        _ = try OpenWithStaging.materialize(item: item, blobs: blobs, root: root)
        Issue.record("应抛 .emptyContent")
    } catch is OpenWithStaging.MaterializationError {
        // OK
    }
}

@Test func cleanupOldStagingRemovesAgedSubdir() throws {
    let root = try freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 建两个子目录,一新一旧
    let oldDir = root.appendingPathComponent("old-uuid", isDirectory: true)
    let newDir = root.appendingPathComponent("new-uuid", isDirectory: true)
    try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: oldDir.appendingPathComponent("f.txt"))
    try Data("x".utf8).write(to: newDir.appendingPathComponent("f.txt"))

    // 把 oldDir mtime 推到 48h 之前
    let old = Date(timeIntervalSinceNow: -48 * 3600)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: oldDir.path)

    OpenWithStaging.cleanupOldStaging(root: root, olderThanHours: 24)

    #expect(!FileManager.default.fileExists(atPath: oldDir.path), "48h 旧目录应被删")
    #expect(FileManager.default.fileExists(atPath: newDir.path), "新目录应保留")
}

@Test func cleanupOldStagingNoOpOnMissingRoot() {
    // 不存在的 root 不抛 / 不崩
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("dpw-missing-\(UUID().uuidString)")
    OpenWithStaging.cleanupOldStaging(root: missing)
}

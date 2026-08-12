import AppKit
import Foundation
import Testing
import DuoPasteCore
@testable import DuoPasteCapture

/// UU 远程桌面往本机 pasteboard 写的 `.uuremote_*` file URL 是它自己的剪贴板传输临时文件
/// （`~/Library/Application Support/com.netease.uuremote{,.server}/Clipboard/`），用完即删。
///
/// 线上证据（用户库）：31 条 `.uuremote_` 行全是 `kind=file` / `blob_sha256=NULL`，抽查 8 条
/// 路径 7 条已从磁盘消失。它们排在面板首位，⌥⌘V + Enter 会把这些死路径写回 NSPasteboard
/// —— 就是用户报告的「UU 远程时剪贴板被覆盖成 UU 的奇怪文件」。
///
/// 这里刻意走**真实 named NSPasteboard + 真实 watcher**，钉的是 `extract()` 里那条
/// `return nil`，而不是一个只有测试在用的纯谓词（那正是 #4 死代码问题的成因）。
@MainActor
private func runWatcher(
    writing write: @MainActor (NSPasteboard) -> Void
) async -> [CapturedPasteboard] {
    let name = NSPasteboard.Name("duo-paste-uu-\(UUID().uuidString)")
    let watched = NSPasteboard(name: name)
    watched.clearContents()

    let box = CaptureBox()
    let watcher = PasteboardWatcher(
        pasteboard: watched,
        pollInterval: 0.01,
        debounceMs: 0,
        shouldCapture: { _ in true },
        onCapture: { box.append($0) }
    )
    await watcher.start()

    let writer = NSPasteboard(name: name)
    writer.clearContents()
    await MainActor.run { write(writer) }
    try? await Task.sleep(for: .milliseconds(200))
    await watcher.stop()
    return box.captured
}

@MainActor
private final class CaptureBox {
    var captured: [CapturedPasteboard] = []
    func append(_ c: CapturedPasteboard) { captured.append(c) }
}

private func fileURL(_ path: String) -> NSURL {
    NSURL(fileURLWithPath: path)
}

/// 控制组：普通文件必须照常捕获。没有这条，下面的 skip 断言可能只是因为测试环境根本
/// 抓不到任何东西而"假通过"。
@MainActor
@Test func ordinaryFileURLIsStillCaptured() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-uu-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let doc = dir.appendingPathComponent("report.pdf")
    FileManager.default.createFile(atPath: doc.path, contents: Data("pdf".utf8))

    let captured = await runWatcher { pb in
        pb.writeObjects([NSURL(fileURLWithPath: doc.path)])
    }
    #expect(captured.count == 1, "普通文件复制必须照常入库")
    #expect(captured.first?.kind == .file)
}

/// 全部是 UU 占位符 + 没有任何图片 representation → 整条跳过。
@MainActor
@Test func uuPlaceholderOnlyPasteboardIsNotCaptured() async {
    let captured = await runWatcher { pb in
        pb.writeObjects([
            fileURL("/Users/bobby/Library/Application Support/com.netease.uuremote/Clipboard/.uuremote_aeawu417663037298784"),
            fileURL("/Users/bobby/Library/Application Support/com.netease.uuremote.server/Clipboard/.uuremote_aeawu410"),
        ])
    }
    #expect(
        captured.isEmpty,
        "UU 传输占位符不该进历史；实际捕获 \(captured.count) 条 kind=\(captured.map(\.kind))"
    )
}

/// UU 确实带了图片字节时保留 be822a3 的行为：按 image 入库，不能被新逻辑一起吞掉。
@MainActor
@Test func uuPlaceholderWithImageBytesStillCapturesImage() async {
    let png = makeTinyPNG()
    let captured = await runWatcher { pb in
        pb.writeObjects([
            fileURL("/Users/bobby/Library/Application Support/com.netease.uuremote/Clipboard/.uuremote_withimage"),
        ])
        pb.setData(png, forType: .png)
    }
    #expect(captured.count == 1)
    #expect(captured.first?.kind == .image)
    #expect(captured.first?.blob == png)
}

/// 混选（占位符 + 用户真实文件）保持 file-first 语义，绝不能整批吞掉真实文件。
@MainActor
@Test func mixedPlaceholderAndRealFileStillCaptures() async {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-uu-mix-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let real = dir.appendingPathComponent("keepme.txt")
    FileManager.default.createFile(atPath: real.path, contents: Data("x".utf8))

    let captured = await runWatcher { pb in
        pb.writeObjects([
            fileURL("/Users/bobby/Library/Application Support/com.netease.uuremote/Clipboard/.uuremote_mixed"),
            NSURL(fileURLWithPath: real.path),
        ])
    }
    #expect(captured.count == 1, "混选里有用户真实文件时不能跳过")
    #expect(captured.first?.kind == .file)
}

private func makeTinyPNG() -> Data {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        return Data()
    }
    return png
}

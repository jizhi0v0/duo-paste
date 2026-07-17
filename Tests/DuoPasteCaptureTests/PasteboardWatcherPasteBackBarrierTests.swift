import AppKit
import Testing
@testable import DuoPasteCapture

/// R3.3 的纯文本动作和普通 paste 共用这条 actor barrier。用独立 pasteboard 实测：
/// pasteBack 内的 self-write 即使 watcher 正在 10ms 轮询，也不会回调成一次 capture。
@MainActor
@Test func pasteBackBarrierSuppressesSelfWriteCapture() async {
    let name = NSPasteboard.Name("duo-paste-pasteback-barrier-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    pasteboard.clearContents()

    var captures = 0
    let watcher = PasteboardWatcher(
        pasteboard: pasteboard,
        pollInterval: 0.01,
        debounceMs: 0,
        onCapture: { _ in captures += 1 }
    )
    await watcher.start()

    // 跟 capture-gate 测试一致：另取同名 NSPasteboard 作为 writer，避免 Swift 6
    // region isolation 把已交给 watcher actor 的同一个引用再次捕获进 main closure。
    let writerPasteboard = NSPasteboard(name: name)
    let wrote = await watcher.pasteBack {
        writerPasteboard.clearContents()
        return writerPasteboard.setString("plain-text self write", forType: .string)
    }
    #expect(wrote)

    try? await Task.sleep(for: .milliseconds(120))
    await watcher.stop()
    #expect(captures == 0)
}

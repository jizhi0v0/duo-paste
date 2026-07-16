import AppKit
import Foundation
import Testing
@testable import DuoPasteCapture

/// R1.1 第一层隐私门：changeCount 仍被 watcher 消费，但 gate=false 时不向业务层投递。
/// gate 在 PasteboardWatcher.capture() 的 pasteboard.types / extract 之前调用，因而也不会
/// 进入可疑短文本诊断日志；CaptureService 的零写入测试覆盖第二层门。
@MainActor
@Test func captureGateRejectsBeforeCallback() async {
    let pasteboardName = NSPasteboard.Name("duo-paste-capture-gate-\(UUID().uuidString)")
    let watchedPasteboard = NSPasteboard(name: pasteboardName)
    watchedPasteboard.clearContents()

    var gateCalls = 0
    var captures = 0
    let watcher = PasteboardWatcher(
        pasteboard: watchedPasteboard,
        pollInterval: 0.01,
        debounceMs: 0,
        shouldCapture: { _ in
            gateCalls += 1
            return false
        },
        onCapture: { _ in captures += 1 }
    )

    await watcher.start()
    // 另取同名 NSPasteboard 作为 writer，避免测试主 actor 在把 watchedPasteboard
    // 交给 watcher actor 后继续持有/访问同一 Swift 引用。
    let writerPasteboard = NSPasteboard(name: pasteboardName)
    writerPasteboard.clearContents()
    writerPasteboard.setString("must-not-reach-callback", forType: .string)
    try? await Task.sleep(for: .milliseconds(150))
    await watcher.stop()

    #expect(gateCalls >= 1)
    #expect(captures == 0)
}

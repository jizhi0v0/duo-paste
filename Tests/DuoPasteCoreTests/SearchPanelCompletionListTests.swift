import Foundation
import Testing
@testable import DuoPasteCore

/// `duo-pasted` 是 executable target，没有测试宿主，AppKit 面板行为无法直接单测；
/// 这条崩溃的修复点又只有一处，沿用 `DocumentationContractTests` 的源码断言做法钉住。
///
/// 背景：`SPCompletionListServiceViewController` 未捕获 NSException 让 daemon abort，
/// 2026-07-25 / 2026-07-28 各一次，且都发生在**已包含** 2f2398e deferral 的 build 1270 上。
/// 崩栈证明 order 已经在干净的 main dispatch queue turn 上执行（frame 14→16→19→21），
/// 完全不在 SwiftUI layout pass 里 —— 所以"挪出 layout pass"不是根因修复。
///
/// 真机制：窗口上屏会广播通知给进程内**每个** `NSRemoteView`；搜索框的自动补全候选列表
/// 是一个跨进程 remote view，当它已无 containing window（assert 的 `expected (null)`）
/// 却仍在观察者表上时就会断言失败。唯一稳的办法是让这个 remote view 不存在。
private func searchPanelSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot
            .appendingPathComponent("Sources/duo-pasted/SearchPanelController.swift"),
        encoding: .utf8
    )
}

@Test func searchPanelDisablesAutomaticTextCompletion() throws {
    let source = try searchPanelSource()
    #expect(
        source.contains("override func fieldEditor(_ createFlag: Bool, for client: Any?) -> NSText?"),
        "HUDPanel 必须覆盖 fieldEditor 才能拿到 SwiftUI TextField 背后的字段编辑器"
    )
    #expect(
        source.contains("textView.isAutomaticTextCompletionEnabled = false"),
        """
        搜索框的系统自动补全候选列表是跨进程 NSRemoteView，是 \
        SPCompletionListServiceViewController 崩溃的来源；关掉它才是根因修复
        """
    )
}

/// 两层防御都要留：deferral 便宜、无害，而崩溃难复现，不要因为加了根因修复就删掉它。
@Test func previewOrderingDeferralIsStillInPlace() throws {
    let source = try searchPanelSource()
    #expect(
        source.contains("DispatchQueue.main.async"),
        "预览浮窗上屏的 runloop deferral 不要删——它与补全列表修复是两层独立防御"
    )
    #expect(source.contains("preview.show(item: item, cardRectInGlobal:"))
}

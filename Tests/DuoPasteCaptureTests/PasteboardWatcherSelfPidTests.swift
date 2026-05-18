import Testing
import Darwin
@testable import DuoPasteCapture

/// 双层防御的第二层:self-pid 匹配 → 跳过 capture。
/// 详见 CLAUDE.md "NSPasteboard 自写回环——双层防御" 一节。
/// pasteBack 的 suppressUpToCurrent 只挡程序化写回;用户在搜索框 / Settings 文本框
/// 手动 Cmd+C 时只有 self-pid 过滤能拦。
@Test func selfPidMatchSkipsCapture() {
    let selfPid: pid_t = 12345
    #expect(PasteboardWatcher.shouldSkipFrontApp(pid: selfPid, selfPid: selfPid))
}

@Test func differentPidDoesNotSkip() {
    let selfPid: pid_t = 12345
    let otherPid: pid_t = 67890
    #expect(!PasteboardWatcher.shouldSkipFrontApp(pid: otherPid, selfPid: selfPid))
}

/// frontApp.pid nil(LSUIElement 无 frontmost / 系统 daemon)→ 不跳过,
/// 按正常 capture 路径走(无 source app 信息 = bundleID nil + appName nil)
@Test func nilPidDoesNotSkip() {
    let selfPid: pid_t = 12345
    #expect(!PasteboardWatcher.shouldSkipFrontApp(pid: nil, selfPid: selfPid))
}

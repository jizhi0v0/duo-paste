import Testing
import Foundation
@testable import DuoPasteCapture

/// RTF 降级 (b) 分支判定:decode 成功但 trim 后全空白 → 跳过 capture。
/// 详见 CLAUDE.md "RTF 三层降级 + raw-size 守门"。
/// 背景:Notes/Mail 在选择折叠到光标位置时仍写一份只有 \rtf1\ansi 元数据头 + 空
/// \fonttbl / \colortbl 没有任何 text run 的 RTF 到 pasteboard。raw markup 既搜不到
/// 又填不出 preview,落库就是噪声——回归测试钉住"识别成空白 → 跳过"这条契约。

/// 现网截图里抓到的真实空壳 RTF——只有元数据头,无任何 text run。
/// 历史现象:作为 kind=.rtf 落库,text_full = raw markup,UI 卡片直接显示
/// `{\rtf1\ansi\ansicpg1252\cocoartf2869...}` 一坨。
private let emptyShellRTF = """
{\\rtf1\\ansi\\ansicpg1252\\cocoartf2869
\\cocoatextscaling0\\cocoaplatform0
{\\fonttbl}
{\\colortbl;\\red255\\green255\\blue255;}
{\\*\\expandedcolortbl;;}
}
"""

private let defaultCap = 512 * 1024

@Test func emptyShellRTFDecodesToWhitespaceOnly() {
    // decode 出来本身应该是空 / 全空白(空头 RTF 没有 text run)
    let plain = PasteboardWatcher.decodeRTFToPlain(emptyShellRTF)
    #expect(plain != nil, "空壳 RTF 应该能解析成功,只是内容为空")
    let trimmed = plain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "non-nil-sentinel"
    #expect(trimmed.isEmpty, "解出的 plain 应该 trim 后全空白,实际: \(plain?.debugDescription ?? "nil")")
}

@Test func emptyShellRTFIsClassifiedAsAllWhitespace() {
    // 核心契约:空壳 RTF → decodedRTFIsAllWhitespace = true → extract 跳过不入库
    #expect(PasteboardWatcher.decodedRTFIsAllWhitespace(emptyShellRTF, maxRawBytes: defaultCap))
}

@Test func rtfWithRealContentIsNotAllWhitespace() {
    // 有 text run 的正常 RTF → 不被识别为空白(继续走 plainTextOrURL 路径)
    let withText = """
    {\\rtf1\\ansi\\ansicpg1252\\cocoartf2869
    {\\fonttbl\\f0\\fnil\\fcharset0 Helvetica;}
    {\\colortbl;\\red255\\green255\\blue255;}
    \\f0\\fs24 hello world}
    """
    #expect(!PasteboardWatcher.decodedRTFIsAllWhitespace(withText, maxRawBytes: defaultCap))
}

@Test func rtfOversizeRawSkipsDecodeAndFallsBack() {
    // raw 超 cap → 不走 decode(避免 @MainActor 同步解 50MB markup),helper 返回 false
    // 让调用方走 raw RTF 兜底路径,后续 CaptureService 字节守门拦下
    // 用一段刻意够大的 RTF source(填充 \par 让字节够大,但 cap 调小让它"超")
    let smallCap = 100
    let oversize = emptyShellRTF + String(repeating: " ", count: 200)
    #expect(oversize.utf8.count > smallCap)
    #expect(!PasteboardWatcher.decodedRTFIsAllWhitespace(oversize, maxRawBytes: smallCap),
            "raw 超 cap 应返回 false 让调用方走兜底,不在判定路径里偷偷 decode")
}

@Test func malformedRTFDecodeFailureNotClassifiedAsEmpty() {
    // decode 失败(不是合法 RTF)→ helper 返回 false 让调用方走兜底
    // 注意 NSAttributedString 对 RTF 解析极其宽松,纯 ASCII / 残破 markup 多数会被
    // "降级"成 plain text 解出来。这里挑一个真的零字节(decode 必失败)的 case
    #expect(!PasteboardWatcher.decodedRTFIsAllWhitespace("", maxRawBytes: defaultCap))
}

/// 边界:空白字符串本身 size = 0 ≤ cap,但 decode 也可能失败或解出空 attr。
/// 不论哪种 helper 都不应崩溃。
@Test func whitespaceOnlyInputDoesNotCrash() {
    _ = PasteboardWatcher.decodedRTFIsAllWhitespace("   \n\t  ", maxRawBytes: defaultCap)
    _ = PasteboardWatcher.decodedRTFIsAllWhitespace("\n", maxRawBytes: defaultCap)
}

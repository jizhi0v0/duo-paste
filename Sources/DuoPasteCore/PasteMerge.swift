import Foundation

/// 多项 paste 的合并策略 + 纯函数 helper。
///
/// 单独成模块的原因:
/// 1. 让"决定怎么合并"跟"实际写 NSPasteboard"解耦——后者依赖 AppKit + FileManager,
///    前者只跟 Item 数组语义有关,可以单测
/// 2. 调用方(Copyback / AppDelegate)消费 strategy 决定走哪条路径,把 banner 文案 / lazy 拉
///    blob / 关 panel 这些副作用留给自己
public enum PasteMerge {
    public enum Strategy: Equatable, Sendable {
        case singleItem    // count == 1,走原 single paste 路径
        case mergedText    // textual 拼接(textFull ?? preview 兜底)
        case mergedFile    // 全 file,合并多 URL
        case mergedImages  // 全 image 多张,落 temp 文件 + writeObjects 多 file URL
    }

    /// 根据 items 的 kind 组合决定合并策略。**纯函数**:不依赖 items 内容,只依赖 kind 集合。
    /// - 0 / 1 项 → singleItem(保留原单项 paste 的 image lazy 拉 blob 能力)
    /// - 多项全 file → mergedFile(writeObjects 多 NSURL)
    /// - 多项全 image → mergedImages(blob 字节落 temp 文件 + writeObjects 多 file URL,
    ///   接收端是 Finder/iMessage/微信会拿到多张图)
    /// - 多项其他(含跨 kind)→ mergedText,image/file 用 preview 兜底
    ///
    /// **设计变更历史**:
    /// 1. (2026-05-14) 原版跨 kind 走 fallback 取首项,user 反馈"选 4 文本+1 图 paste 只
    ///    粘 Gen 2 像 bug"。改成跨 kind 走 textual 拼接,image 用 preview 占位
    /// 2. (2026-05-14 二修) 多 image 原本 fallback 取首项,user 觉得太弱。改成
    ///    mergedImages:每张图落 temp 文件 + writeObjects 多 file URL。接收端按"多文件 paste"
    ///    处理——Finder/Slack/iMessage/浏览器原生支持,Word 显示成多 attachment
    public static func strategy(for items: [Item]) -> Strategy {
        if items.count <= 1 { return .singleItem }
        let kinds = Set(items.map { $0.kind })
        if kinds == [.image] { return .mergedImages }
        if kinds == [.file]  { return .mergedFile }
        return .mergedText
    }

    /// 把 items 内容按顺序拼成单字符串(separator 分隔)。
    /// 取值优先级:`textFull ?? preview`——image kind 的 textFull 通常 nil(OCR 才填),
    /// preview 是 "[image 4.5 MB]" 这类人类可读占位,跨 kind paste 时用 preview 兜底让
    /// image 也能进入拼接结果。全空 → 返回 nil(调用方据此判定"无可写入内容")
    public static func joinTextual(_ items: [Item], separator: String = "\n") -> String? {
        let parts = items.compactMap { $0.textFull ?? $0.preview }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: separator)
    }

    /// 把 file 类 items 的 textFull(\n 分隔的路径列表) 按 items 顺序展平。
    /// 每行 trim 空白,跳过空行。**不**做文件存在性检查——FileManager 调用在 main module 兜底
    public static func flattenFilePaths(_ items: [Item]) -> [String] {
        var out: [String] = []
        for it in items {
            guard let raw = it.textFull else { continue }
            for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
            }
        }
        return out
    }
}

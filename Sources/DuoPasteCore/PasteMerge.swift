import Foundation

/// 多项 paste 的合并策略 + 纯函数 helper。
///
/// 单独成模块的原因:
/// 1. 让"决定怎么合并"跟"实际写 NSPasteboard"解耦——后者依赖 AppKit + FileManager,
///    前者只跟 Item 数组语义有关,可以单测
/// 2. 调用方(Copyback / AppDelegate)消费 strategy 决定走哪条路径,把 banner 文案 / lazy 拉
///    blob / 关 panel 这些副作用留给自己
public enum PasteMerge {
    public enum FallbackReason: Equatable, Sendable {
        case multipleImages   // 全 image 但多于 1 张(NSPasteboard 单 type 单实例,无法承载)
    }

    public enum Strategy: Equatable, Sendable {
        case singleItem                              // count == 1,走原 single paste 路径
        case mergedText                              // textual 拼接(textFull ?? preview 兜底)
        case mergedFile                              // 全 file,合并多 URL
        case fallbackToFirst(reason: FallbackReason) // 全 image 多张,只 paste 首项
    }

    /// 根据 items 的 kind 组合决定合并策略。**纯函数**:不依赖 items 内容,只依赖 kind 集合。
    /// - 0 / 1 项 → singleItem(保留原单项 paste 的 image lazy 拉 blob 能力)
    /// - 多项全 file → mergedFile
    /// - 多项全 image → fallbackToFirst(.multipleImages)
    /// - 多项其他(含跨 kind,即使含 image / file)→ mergedText,image/file 用 preview 兜底
    ///
    /// **设计变更**(2026-05-14):原版跨 kind 也走 fallback,但现实里 user cmd+多选 4 文本
    /// +1 图片时期望 5 条都 paste 不是单首项。改成跨 kind 走 textual 拼接,image 用其
    /// preview("[image 4.5 MB]"等)占位。只有"全 image 多张"这种 NSPasteboard 表达不了的
    /// 真 fallback——多 image 没有"多图占位文本"的合理 paste 语义
    public static func strategy(for items: [Item]) -> Strategy {
        if items.count <= 1 { return .singleItem }
        let kinds = Set(items.map { $0.kind })
        if kinds == [.image] { return .fallbackToFirst(reason: .multipleImages) }
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

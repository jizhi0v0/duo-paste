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
        case crossKind        // items 含多个不同 kind
        case multipleImages   // 全 image 但多于 1 张(NSPasteboard 单 type 单实例,无法承载)
    }

    public enum Strategy: Equatable, Sendable {
        case singleItem                              // count == 1,走原 single paste 路径
        case mergedText                              // 全 text/url/rtf/html,拼字符串
        case mergedFile                              // 全 file,合并多 URL
        case fallbackToFirst(reason: FallbackReason) // 多 image 或跨 kind,只 paste 首项
    }

    /// 根据 items 的 kind 组合决定合并策略。**纯函数**:不依赖 items 内容,只依赖 kind 集合。
    /// - 0 项 → 调用方应早退;这里也返回 singleItem 让 invariant 简单
    /// - 1 项 → singleItem(保留原单项 paste 的 image lazy 拉 blob 能力)
    /// - 多项同 kind 非 image → mergedText / mergedFile
    /// - 多项跨 kind → fallbackToFirst(.crossKind)
    /// - 多项全 image → fallbackToFirst(.multipleImages)
    public static func strategy(for items: [Item]) -> Strategy {
        if items.count <= 1 { return .singleItem }
        let kinds = Set(items.map { $0.kind })
        if kinds.count > 1 { return .fallbackToFirst(reason: .crossKind) }
        // kinds 非空且 count == 1 → 单一 kind
        switch kinds.first! {
        case .image: return .fallbackToFirst(reason: .multipleImages)
        case .file:  return .mergedFile
        case .text, .url, .rtf, .html: return .mergedText
        }
    }

    /// 把 text 类 items 的 textFull 按 items 顺序拼成单字符串(separator 分隔)。
    /// textFull 为 nil 的项跳过;全 nil → 返回 nil(调用方据此判定"无可写入内容")
    public static func joinTextual(_ items: [Item], separator: String = "\n") -> String? {
        let parts = items.compactMap { $0.textFull }
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

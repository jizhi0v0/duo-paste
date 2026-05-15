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

    /// 根据 items 的 kind 组合决定合并策略。**纯函数**:依赖每项 kind + blobMime,不读 textFull 内容。
    /// - 0 / 1 项 → singleItem(保留原单项 paste 的 image lazy 拉 blob 能力)
    /// - 多项全 image-like(image kind / file kind+blob_mime=image/*)→ mergedImages
    ///   (按 sha 落 temp 文件 + writeObjects 多 file URL,接收端 Finder/iMessage/微信拿到多张图)
    /// - 多项全 file 且非全 image-like → mergedFile(writeObjects 多 NSURL,原路径)
    /// - 多项其他(含跨 kind 文本+图)→ mergedText,image/file 用 preview 兜底
    ///
    /// **设计变更历史**:
    /// 1. (2026-05-14) 原版跨 kind 走 fallback 取首项,user 反馈"选 4 文本+1 图 paste 只
    ///    粘 Gen 2 像 bug"。改成跨 kind 走 textual 拼接,image 用 preview 占位
    /// 2. (2026-05-14 二修) 多 image 原本 fallback 取首项,user 觉得太弱。改成
    ///    mergedImages:每张图落 temp 文件 + writeObjects 多 file URL。接收端按"多文件 paste"
    ///    处理——Finder/Slack/iMessage/浏览器原生支持,Word 显示成多 attachment
    /// 3. (2026-05-14 三修) image-like 判定扩展:file kind 但 blob_mime=image/* 也算
    ///    image-like。原因:微信/WeType 等场景同一张图可能以 file URL+image bytes 两套 type
    ///    被 capture 进库,kind 由 watcher 优先级决定(file > image),用户多选这种"实际都是图"
    ///    的混合时,意图是"4 张都粘成图",不是"plain text 拼路径列表"。代价:接收端拿到 temp
    ///    路径(sha 前 16 位+ext)而非原 mac_xxx.png 路径,多图 paste 场景下可接受
    public static func strategy(for items: [Item]) -> Strategy {
        if items.count <= 1 { return .singleItem }
        let kinds = Set(items.map { $0.kind })
        // image-like:image kind 或 file kind+blob 是 image MIME。allSatisfy 空 items 返 true
        // 但上面 count<=1 已 short-circuit,这里至少 2 项
        let allImageLike = items.allSatisfy { isImageLike($0) }
        if allImageLike { return .mergedImages }
        if kinds == [.file] { return .mergedFile }
        return .mergedText
    }

    /// "实际是图"判定:image kind 直接是;file kind 且 blob_mime 以 `image/` 开头算。
    /// **不**靠路径后缀——blob_mime 在 CaptureService 由 NSPasteboard UTI 推断,比文件名
    /// 后缀靠谱(用户可能 cp foo.png bar.txt 之类)
    public static func isImageLike(_ item: Item) -> Bool {
        if item.kind == .image { return true }
        if item.kind == .file, let mime = item.blobMime, mime.hasPrefix("image/") {
            return true
        }
        return false
    }

    /// 把 items 内容按顺序拼成单字符串(separator 分隔)。
    /// 取值优先级:
    /// - image kind:**强制走 preview**("[image NNN KB]" / 文件名)。image 没有"原始可
    ///   粘贴文本"——可粘贴主体是字节(走 mergedImages 路径),v9 之后 textFull 永远 nil。
    ///   OCR 文本现在装在 extracted_text 列(从 v6 历史的 textFull 搬出),不再参与
    ///   跨 kind 合并 paste(语义上 OCR 是"搜索辅助索引"不是"用户复制的内容")
    /// - 其他 kind:`textFull ?? preview`——textFull 不空时直接用,nil 时退 preview 兜底
    /// 全空 → 返回 nil(调用方据此判定"无可写入内容")
    public static func joinTextual(_ items: [Item], separator: String = "\n") -> String? {
        let parts = items.compactMap { item -> String? in
            if item.kind == .image { return item.preview }
            return item.textFull ?? item.preview
        }
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

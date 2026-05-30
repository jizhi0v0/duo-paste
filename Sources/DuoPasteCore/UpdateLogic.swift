import Foundation

/// Sparkle 自动更新的纯逻辑——跟 Sparkle SDK / Bundle / Process 解耦，便于单测。
/// 宿主侧 `SparkleUpdater` / `RelaunchHelper` 调这些函数，副作用（读 Info dict、
/// 起子进程、写 UserDefaults）留在调用方。
public enum UpdateLogic {
    /// 给 feed URL 拼一个时间戳 query 强制不同 CDN cache key——feed 在
    /// raw.githubusercontent.com（Fastly CDN，源站 max-age=300），CI publish 完到 edge
    /// 失效有 ~5min 窗口会拿到旧 appcast 误判「已最新」。base 无法解析成 URLComponents
    /// 返 nil（调用方据此放弃 override 走 Sparkle 默认 feed）。
    public static func cacheBustedFeedURL(_ base: String, epochSeconds: Int) -> String? {
        guard var comps = URLComponents(string: base) else { return nil }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "_", value: String(epochSeconds)))
        comps.queryItems = items
        return comps.url?.absoluteString
    }

    /// beta/stable channel 过滤。`includePrereleases=true` 看 beta channel，否则空集合
    /// = 只看无 channel 标记的 stable。两台自用：一台跟 beta 一台跟 stable 做灰度。
    public static func allowedChannels(includePrereleases: Bool) -> Set<String> {
        includePrereleases ? ["beta"] : []
    }

    /// 从 Info.plist 字节解出 CFBundleVersion。缺键 / 类型不符 / 解析失败 / 空串 → nil。
    /// 用 `PropertyListSerialization` 而非起 PlistBuddy 子进程——relaunch helper poll 每
    /// 0.5s 一次最多 240 次，逐次 spawn 子进程没必要。
    public static func bundleVersion(fromInfoPlist data: Data) -> String? {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let v = dict["CFBundleVersion"] as? String else { return nil }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

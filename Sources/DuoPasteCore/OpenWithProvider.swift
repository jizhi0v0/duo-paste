import AppKit
import Foundation
import UniformTypeIdentifiers

/// 右键菜单"打开方式"路由——按 Item kind 决定要列哪类 app。
///
/// **为什么按 kind 拆**：剪贴板 item 类型差异大,统一一份"所有 app"列表既冗长又不准。
/// text 应该列编辑器(VS Code / Sublime / TextEdit)、image 应该列 Preview / Pixelmator、
/// url 应该列浏览器、pdf 应该列 PDF 阅读器。LaunchServices 已经按 UTType / URL 维护这种
/// 索引,我们只是把 ItemKind → 查询参数 的映射做对。
public enum OpenWithCategory: Sendable, Equatable {
    /// text / rtf / html kind —— 走 `.plainText` handler + 编辑器黑名单。
    /// 不用 `.rtf` / `.html` 自己的 handler:前者会带回 Word / Pages,后者会带回 Safari /
    /// Chrome,都不是用户想要的"在文本编辑器看源码"心智
    case textEditor
    /// url kind —— 列默认浏览器 + 装的其它浏览器
    case browser
    /// image / pdf / 任意有 blob + mime 的 file —— 按 UTType 查 handler
    case viewer(UTType)
    /// `.file` kind 且本机路径存在 —— 用真实文件 URL 查最准
    /// (LaunchServices 会读 file 的 extended attributes,比 mime 推断更精确)
    case filePath(URL)
}

/// 单个可打开 app 的描述。`OpenWithApp` 自身不持 NSImage(Sendable 友好);
/// icon 在 UI 层 lazy load,跟 displayName 解耦
public struct OpenWithApp: Sendable, Hashable, Identifiable {
    public let bundleURL: URL
    public let bundleID: String?
    public let displayName: String
    /// 是否是 category 的默认 handler。UI 层用它在 submenu 顶部标 "(默认)" + 排首位
    public let isDefault: Bool

    public var id: URL { bundleURL }

    public init(bundleURL: URL, bundleID: String?, displayName: String, isDefault: Bool) {
        self.bundleURL = bundleURL
        self.bundleID = bundleID
        self.displayName = displayName
        self.isDefault = isDefault
    }
}

public enum OpenWithProvider {
    /// "文本编辑器"子菜单的黑名单。`.plainText` handler 列表里出现这些 bundle ID
    /// 直接过滤掉——它们虽然声称能开 plainText,但用户想要的"用编辑器打开"语义里都不是。
    ///
    /// 分类:
    /// - Apple 自家 viewer / 系统服务:Preview / Quick Look
    /// - Office 套件:Word / Excel / PowerPoint / Pages / Numbers / Keynote
    /// - PDF 阅读器:Adobe Reader / PDF Expert
    /// - 通讯 app(会把粘贴内容当邮件 / 笔记):Mail / Notes
    /// - 浏览器(plainText 拖进 Safari 不是常态):Safari / Chrome / Firefox / Arc
    public static let textEditorBlacklist: Set<String> = [
        // Apple viewer / 系统
        "com.apple.Preview",
        "com.apple.QuickLookUIService",
        // Office
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        // PDF
        "com.adobe.Reader",
        "com.adobe.Acrobat.Pro",
        "com.readdle.PDFExpert-Mac",
        // 通讯
        "com.apple.Notes",
        "com.apple.mail",
        // 浏览器
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
    ]

    /// kind → category 映射。filePath 优先(本机路径在时最准),其次 UTType from mime,
    /// 兜底 UTType from filename extension,再兜底 `.data`
    public static func category(for item: Item) -> OpenWithCategory {
        switch item.kind {
        case .text, .rtf, .html:
            return .textEditor
        case .url:
            return .browser
        case .image:
            // image kind 走 mime 推 UTType,推不出退到 .image 父类
            // (父类让 Preview / Pixelmator / Photoshop 等通用图片 app 都出现)
            if let mime = item.blobMime, let ut = UTType(mimeType: mime) {
                return .viewer(ut)
            }
            return .viewer(.image)
        case .file:
            // 本机路径存在 → 走 filePath(LaunchServices 看 file 本身的 UTI)
            if let first = firstFilePath(from: item),
               FileManager.default.fileExists(atPath: first.path) {
                return .filePath(first)
            }
            // 路径不在本机但有 mime → 用 mime 推 UTType
            if let mime = item.blobMime, let ut = UTType(mimeType: mime) {
                return .viewer(ut)
            }
            // mime 推不出退到后缀。textFull 里仍有路径字符串可解扩展名
            if let first = firstFilePath(from: item),
               let ut = UTType(filenameExtension: first.pathExtension) {
                return .viewer(ut)
            }
            // 全部推不出 → .data(LaunchServices 会列 Archive Utility / Hex Fiend 等通用)
            return .viewer(.data)
        }
    }

    /// 调 NSWorkspace 拉 category 对应的 app 列表。已按"默认 app 在首位 + 去重"排好。
    ///
    /// 性能:LaunchServices 走 in-memory cache。冷启动首次 50-200ms,warm 后微秒级。
    /// **在主线程调可能首次卡一下**——caller 通常用 `Task.detached` 包起来
    public static func apps(for category: OpenWithCategory) -> [OpenWithApp] {
        let ws = NSWorkspace.shared
        let urls: [URL]
        let defaultURL: URL?
        switch category {
        case .textEditor:
            urls = ws.urlsForApplications(toOpen: .plainText)
            defaultURL = ws.urlForApplication(toOpen: .plainText)
            let ranked = rank(urls: urls, defaultURL: defaultURL)
            return ranked.filter { app in
                guard let bid = app.bundleID else { return true }
                return !textEditorBlacklist.contains(bid)
            }
        case .browser:
            // 用一个稳定的 http URL 当探针 —— LaunchServices 看 scheme 就够,
            // example.com 不会真的请求
            guard let probe = URL(string: "https://example.com") else { return [] }
            urls = ws.urlsForApplications(toOpen: probe)
            defaultURL = ws.urlForApplication(toOpen: probe)
            return rank(urls: urls, defaultURL: defaultURL)
        case .viewer(let ut):
            urls = ws.urlsForApplications(toOpen: ut)
            defaultURL = ws.urlForApplication(toOpen: ut)
            return rank(urls: urls, defaultURL: defaultURL)
        case .filePath(let fileURL):
            urls = ws.urlsForApplications(toOpen: fileURL)
            defaultURL = ws.urlForApplication(toOpen: fileURL)
            return rank(urls: urls, defaultURL: defaultURL)
        }
    }

    /// 拿 app 的本地化显示名 —— 四级 fallback。
    /// `localizedInfoDictionary` 拿的是目标 app 自己的本地化(英文系统下打开中文 app
    /// 仍能拿到中文名),正是要的
    public static func displayName(for appURL: URL) -> String {
        let bundle = Bundle(url: appURL)
        if let name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
           !name.isEmpty { return name }
        if let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String,
           !name.isEmpty { return name }
        if let name = bundle?.localizedInfoDictionary?["CFBundleName"] as? String,
           !name.isEmpty { return name }
        if let name = bundle?.infoDictionary?["CFBundleName"] as? String,
           !name.isEmpty { return name }
        return FileManager.default.displayName(atPath: appURL.path)
    }

    /// 把 LaunchServices 返回的 URL 列表组装成 `OpenWithApp`:default app 排首位、
    /// 去重、其余按 LaunchServices 原顺序。internal 让 OpenWithProviderTests 注入
    /// 假 URL 列表验证排序 + dedup 逻辑(真的 NSWorkspace 调用不可控)
    static func rank(urls: [URL], defaultURL: URL?) -> [OpenWithApp] {
        var seen: Set<URL> = []
        var ordered: [URL] = []
        if let def = defaultURL {
            ordered.append(def)
            seen.insert(def)
        }
        for u in urls where !seen.contains(u) {
            ordered.append(u)
            seen.insert(u)
        }
        return ordered.map { url in
            OpenWithApp(
                bundleURL: url,
                bundleID: Bundle(url: url)?.bundleIdentifier,
                displayName: displayName(for: url),
                isDefault: url == defaultURL
            )
        }
    }

    /// 抽出来给测试用:验证 filter 逻辑而不依赖 NSWorkspace 返回什么
    static func filterTextEditors(_ apps: [OpenWithApp]) -> [OpenWithApp] {
        apps.filter { app in
            guard let bid = app.bundleID else { return true }
            return !textEditorBlacklist.contains(bid)
        }
    }

    /// `.file` kind 的 textFull 拿第一行 → URL
    private static func firstFilePath(from item: Item) -> URL? {
        guard let raw = item.textFull ?? item.preview,
              let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first
        else { return nil }
        let trimmed = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }
}

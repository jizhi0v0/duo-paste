import Foundation

/// 搜索框 `/qualifier` 语法解析。让用户在搜索框直接输 `/pdf hello world` 之类
/// 紧凑命令，跟 chip 双轨并存——chip 走 GUI、qualifier 走键盘，最终都落到 SearchQuery
/// 同一组字段（kinds / fileSubKinds / textFullSuffixes）OR 起来。
///
/// `.imageMerged` case 是产品决策：从用户视角"图片"是一种东西（无论原生剪贴板截图
/// 还是 Finder 复制的 .png 文件），落地时同时映射到 `.kind(.image)` + `.fileSubKind(.imageFile)`，
/// 让 SQL 端 OR 拿到两种存储路径。
public enum QueryQualifier: Equatable, Sendable, Hashable {
    case kind(ItemKind)
    case fileSubKind(FileSubKind)
    /// `.java` / `.c` / `.py` 等代码文件——走 textFull suffix LIKE，FTS5 token 化对 `.` 不可靠
    case textSuffix(String)
    /// `/image /img /png /jpg /jpeg /gif /webp /heic` —— 命中 `.kind(.image)` OR `.fileSubKind(.imageFile)`
    case imageMerged
}

extension QueryQualifier {
    /// 单 Item 是否满足任一 qualifier（OR 语义）。空集合等于不过滤（返 true）。
    ///
    /// - `.kind(k)` 直接比 `item.kind`
    /// - `.fileSubKind(s)` 走 `ItemClassifier.fileSubKind` 推断
    /// - `.textSuffix(sfx)` 走 `item.textFull` 末尾 LIKE（lowercased 比较）
    /// - `.imageMerged` 命中 `.kind(.image)` OR `.fileSubKind(.imageFile)`——
    ///   产品决策：从用户视角"图片"是一种东西，跟 SQL 端 `SearchAPI` 契约同构
    ///
    /// **iOS 内存过滤路径专用**。Mac 走 SQL `SearchAPI` 已经在 fold 前做完同等语义,
    /// 不调这个函数。共享纯函数让两端契约不漂移——回归测试在 `MatchesQualifiersTests`
    public static func matches(_ item: Item, qualifiers: [QueryQualifier]) -> Bool {
        guard !qualifiers.isEmpty else { return true }
        var kinds: Set<ItemKind> = []
        var subKinds: Set<FileSubKind> = []
        var suffixes: [String] = []
        for q in qualifiers {
            switch q {
            case .kind(let k):
                kinds.insert(k)
            case .fileSubKind(let s):
                subKinds.insert(s)
            case .textSuffix(let s):
                suffixes.append(s.lowercased())
            case .imageMerged:
                kinds.insert(.image)
                subKinds.insert(.imageFile)
            }
        }
        if kinds.contains(item.kind) { return true }
        if !subKinds.isEmpty, let sub = ItemClassifier.fileSubKind(item), subKinds.contains(sub) {
            return true
        }
        if !suffixes.isEmpty, let text = item.textFull?.lowercased() {
            for sfx in suffixes where text.hasSuffix(sfx) {
                return true
            }
        }
        return false
    }
}

public struct ParsedQuery: Equatable, Sendable {
    /// 剥掉所有合法 `/xxx` token 后的剩余搜索文本（token 间保留单空格）。未识别的
    /// `/xxx` 会保留进 text，避免输错时突然没结果且没解释
    public let text: String
    /// 按输入顺序去重后的 qualifier 列表
    public let qualifiers: [QueryQualifier]

    public init(text: String, qualifiers: [QueryQualifier]) {
        self.text = text
        self.qualifiers = qualifiers
    }
}

public enum QueryParser {
    /// `/xxx` token 的别名 → qualifier 字典。所有 key 必须 lowercase
    static let aliases: [String: QueryQualifier] = {
        var m: [String: QueryQualifier] = [:]

        // 基础 kind
        m["text"] = .kind(.text)
        m["url"] = .kind(.url)
        m["link"] = .kind(.url)
        m["file"] = .kind(.file)
        m["rtf"] = .kind(.rtf)
        m["html"] = .kind(.html)

        // 图片合并语义——产品决策：用户视角"图片"是一种东西
        m["image"] = .imageMerged
        m["img"] = .imageMerged
        m["png"] = .imageMerged
        m["jpg"] = .imageMerged
        m["jpeg"] = .imageMerged
        m["gif"] = .imageMerged
        m["webp"] = .imageMerged
        m["heic"] = .imageMerged

        // 视频
        m["video"] = .fileSubKind(.video)
        m["mp4"] = .fileSubKind(.video)
        m["m4v"] = .fileSubKind(.video)
        m["mov"] = .fileSubKind(.video)
        m["mkv"] = .fileSubKind(.video)

        // 音频
        m["audio"] = .fileSubKind(.audio)
        m["mp3"] = .fileSubKind(.audio)
        m["m4a"] = .fileSubKind(.audio)
        m["wav"] = .fileSubKind(.audio)
        m["flac"] = .fileSubKind(.audio)

        // PDF
        m["pdf"] = .fileSubKind(.pdf)

        // 精准 imageFile（绕过 imageMerged，"只要文件路径里的图片，不要原生截图"）
        m["imagefile"] = .fileSubKind(.imageFile)
        m["image-file"] = .fileSubKind(.imageFile)

        // 代码扩展名 → textFull suffix 匹配
        let codeExts = ["java", "c", "cpp", "h", "hpp", "py", "swift", "go", "rs", "ts", "js", "rb", "kt", "scala", "sh", "yaml", "yml", "toml", "json", "xml", "md"]
        for ext in codeExts {
            m[ext] = .textSuffix("." + ext)
        }

        return m
    }()

    /// 解析输入字符串，剥出 qualifier，剩余为搜索文本
    public static func parse(_ raw: String) -> ParsedQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ParsedQuery(text: "", qualifiers: []) }

        var quals: [QueryQualifier] = []
        var seen: Set<QueryQualifier> = []
        var textTokens: [String] = []

        for token in trimmed.split(separator: " ", omittingEmptySubsequences: true) {
            let t = String(token)
            if t.hasPrefix("/"), t.count > 1 {
                let key = String(t.dropFirst()).lowercased()
                if let q = aliases[key] {
                    if !seen.contains(q) {
                        quals.append(q)
                        seen.insert(q)
                    }
                    continue
                }
                // unknown qualifier → 保留原 token 进 text（避免输错没结果且没解释）
            }
            textTokens.append(t)
        }

        return ParsedQuery(text: textTokens.joined(separator: " "), qualifiers: quals)
    }

    /// 把 ParsedQuery 反向拼回字符串。用于 ✕ 清除按钮剥掉所有 qualifier 后回写 query
    public static func render(text: String, qualifiers: [QueryQualifier]) -> String {
        var parts: [String] = []
        for q in qualifiers {
            if let alias = canonicalAlias(for: q) {
                parts.append("/" + alias)
            }
        }
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        if !trimmedText.isEmpty { parts.append(trimmedText) }
        return parts.joined(separator: " ")
    }

    /// 从 raw query 中**只**抽出"已闭合"（后面跟空格或不是末尾 token）的合法 /xxx token。
    /// 末尾未闭合的 /xxx（用户正在输入中）保留在 remaining 里供补全菜单继续匹配。
    ///
    /// 用法：搜索框 onChange(query) 调用，把空格后的 /xxx 自动转 chip 进 activeQualifiers，
    /// 字符串里只留搜索文本 + 正在输入的 /xxx。
    /// - 输入 `"/pdf hello"` → ([.fileSubKind(.pdf)], "hello")  ← /pdf 后跟空格,已闭合
    /// - 输入 `"/pdf"` → ([], "/pdf")  ← 没空格,可能还在输入,留给补全菜单
    /// - 输入 `"hello /java"` → ([], "hello /java")  ← /java 在末尾未闭合
    /// - 输入 `"hello /java "` → ([.textSuffix(".java")], "hello ")  ← 末尾空格闭合 /java
    /// - 输入 `"/imgae hello"` → ([], "/imgae hello")  ← unknown 不抽
    public static func extractCompleted(_ raw: String) -> (qualifiers: [QueryQualifier], remaining: String) {
        // 按空格保留 separator 拆,这样能区分末尾是否有空格("/pdf" vs "/pdf ")
        let endsWithSpace = raw.hasSuffix(" ")
        let tokens = raw.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.isEmpty else { return ([], raw) }

        var quals: [QueryQualifier] = []
        var seen: Set<QueryQualifier> = []
        var remainingTokens: [String] = []

        // 末尾 token 是否未闭合:不以空格结尾 + 是最后一个 token
        let lastIdx = tokens.count - 1
        for (i, t) in tokens.enumerated() {
            let isUnclosedTail = (i == lastIdx) && !endsWithSpace
            if !isUnclosedTail, t.hasPrefix("/"), t.count > 1 {
                let key = String(t.dropFirst()).lowercased()
                if let q = aliases[key] {
                    if !seen.contains(q) {
                        quals.append(q)
                        seen.insert(q)
                    }
                    continue  // 抽走,不进 remainingTokens
                }
            }
            remainingTokens.append(t)
        }

        // 拼回剩余字符串,保持原 token 间空格
        var remaining = remainingTokens.joined(separator: " ")
        // 如果原 query 末尾是空格且 remainingTokens 最后一项不是空 string,补回末尾空格
        if endsWithSpace && !remaining.hasSuffix(" ") && !remaining.isEmpty {
            remaining += " "
        }
        return (quals, remaining)
    }

    /// 根据当前输入 prefix（含开头的 `/`）返回候选列表。给搜索框补全 overlay 用
    public static func suggestions(prefix: String) -> [(display: String, qualifier: QueryQualifier)] {
        guard prefix.hasPrefix("/") else { return [] }
        let key = String(prefix.dropFirst()).lowercased()
        // 所有 alias 按 prefix 匹配；按 (qualifier 出现频次心智 → key 字母序) 排序
        // 同一 qualifier 多个 alias 命中时只保留首个
        var seen: Set<QueryQualifier> = []
        var result: [(String, QueryQualifier)] = []
        let sortedKeys = aliases.keys.sorted()
        for k in sortedKeys where k.hasPrefix(key) {
            guard let q = aliases[k] else { continue }
            if seen.contains(q) { continue }
            seen.insert(q)
            result.append(("/" + k, q))
        }
        return result
    }

    /// 给 qualifier 找一个"规范" alias 反向 render 用。规则：选最短 alias，相同长度按字母序。
    /// 让 round-trip 稳定（parse(render(x, q)) == ParsedQuery(text: x, qualifiers: q)）
    private static func canonicalAlias(for q: QueryQualifier) -> String? {
        let candidates = aliases.compactMap { (k, v) -> String? in v == q ? k : nil }
        return candidates.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs < rhs
        }.first
    }
}

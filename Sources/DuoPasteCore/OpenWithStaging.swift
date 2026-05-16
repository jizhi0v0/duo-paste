import Foundation
import UniformTypeIdentifiers

/// "用 XXX 打开"路径需要的目标 URL —— 区分 file vs web。
///
/// AppDelegate 拿到后用不同 NSWorkspace.open 路径分发:
/// - `.fileURL(_)` → `open([URL], withApplicationAt:configuration:)`
/// - `.webURL(_)`  → `open(_:configuration:)` (不写盘,scheme handler 直接处理)
public enum OpenWithTarget: Sendable, Equatable {
    case fileURL(URL)
    case webURL(URL)
}

/// 把 Item 内容落地成临时文件 / 拿到 web URL,供 "用 XXX 打开" 调用。
///
/// **不用 /tmp**:
/// 1. macOS sandbox 偶尔清 /tmp,目标 app 还在 lazy 读时会 ENOENT
/// 2. 我们想保留 24h 让用户在编辑器里修改 + 保存的内容不丢
///
/// 所以 staging 落在 `~/Library/Application Support/duo-paste/openwith-tmp/<uuid>/`,
/// daemon 启动时调 cleanupOldStaging() 删 24h 以上子目录,自管 retention
public enum OpenWithStaging {
    /// 把 item 内容物化成可被 NSWorkspace 打开的 URL。
    /// - `root`:staging 根目录(`~/Library/Application Support/duo-paste/openwith-tmp/`)
    ///   caller 拼好传进来,Core 不知道 Paths 结构
    public static func materialize(item: Item, blobs: BlobStore, root: URL) throws -> OpenWithTarget {
        switch item.kind {
        case .url:
            // url kind 不写盘 —— 直接交给浏览器 scheme handler。
            // textFull 多半就是合法 URL 字符串(watcher capture 时已经做过 URL 验证)
            guard let raw = (item.textFull ?? item.preview)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let url = URL(string: raw)
            else {
                throw MaterializationError.invalidURL
            }
            return .webURL(url)

        case .file:
            // 本机路径存在 → 直接 open 原文件(不复制,真实路径最准)
            if let fileURL = firstFilePath(from: item),
               FileManager.default.fileExists(atPath: fileURL.path) {
                return .fileURL(fileURL)
            }
            // 路径不在但有 blob → 用 blob 写 staging
            return try materializeBlob(item: item, blobs: blobs, root: root)

        case .text, .rtf, .html:
            return try materializeText(item: item, root: root)

        case .image:
            return try materializeBlob(item: item, blobs: blobs, root: root)
        }
    }

    /// daemon 启动时调用 —— 扫 staging 根目录,删 mtime > olderThanHours 的子目录。
    /// 不抛错(失败只 log stderr),不阻塞 launch。staging 目录不存在直接 no-op
    public static func cleanupOldStaging(root: URL, olderThanHours: Int = 24) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date(timeIntervalSinceNow: -Double(olderThanHours) * 3600)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            guard let mtime = values?.contentModificationDate, mtime < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - 内部实现

    private static func materializeText(item: Item, root: URL) throws -> OpenWithTarget {
        guard let text = item.textFull, !text.isEmpty else {
            throw MaterializationError.emptyContent
        }
        let ext: String
        switch item.kind {
        case .rtf:  ext = "rtf"
        case .html: ext = "html"
        default:    ext = "txt"
        }
        let url = try stagingFile(item: item, ext: ext, root: root)
        guard let data = text.data(using: .utf8) else {
            throw MaterializationError.encodingFailed
        }
        try data.write(to: url, options: [.atomic])
        return .fileURL(url)
    }

    /// blob 类(image / file with blob)落地。
    ///
    /// **必须 copy 不能 hard link**:hard link 让 staging 跟 BlobStore 共享 inode,
    /// 编辑器 truncate-write 类保存(vim 默认 backup off 时直接覆盖)会污染 blob 文件,
    /// 之后 sha256 不匹配,lazy fetch 路径会以为本地 blob 损坏。32MB copy 也就 ~100ms,
    /// 值得换 isolation
    private static func materializeBlob(item: Item, blobs: BlobStore, root: URL) throws -> OpenWithTarget {
        guard let sha = item.blobSha256 else {
            throw MaterializationError.missingBlob
        }
        guard let blobURL = blobs.locate(sha256: sha) else {
            throw MaterializationError.blobNotInStore(sha: sha)
        }
        let ext = blobExtension(item: item, blobURL: blobURL)
        let url = try stagingFile(item: item, ext: ext, root: root)
        try FileManager.default.copyItem(at: blobURL, to: url)
        return .fileURL(url)
    }

    /// 推 blob 文件该用什么扩展名,三级 fallback
    private static func blobExtension(item: Item, blobURL: URL) -> String {
        // 1) BlobStore 落地时已带后缀 → 直接用
        let existingExt = blobURL.pathExtension
        if !existingExt.isEmpty { return existingExt }
        // 2) 从 blobMime 推首选扩展名(image/png → png)
        if let mime = item.blobMime,
           let ut = UTType(mimeType: mime),
           let preferred = ut.preferredFilenameExtension {
            return preferred
        }
        // 3) `.file` kind 的 textFull 里有原始路径,扒后缀
        if item.kind == .file,
           let fileURL = firstFilePath(from: item) {
            let pathExt = fileURL.pathExtension
            if !pathExt.isEmpty { return pathExt }
        }
        return "bin"
    }

    /// 在 staging root 下建 `<uuid>/<readable-prefix>.<ext>` 并返回完整路径。
    /// 子目录用 UUID 避免文件名冲突 + 让 cleanup 删整个子目录就够
    private static func stagingFile(item: Item, ext: String, root: URL) throws -> URL {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = readableNamePrefix(item: item)
        return dir.appendingPathComponent("\(prefix).\(ext)")
    }

    /// 把 preview 头 30 字符做成 fs-safe 文件名 prefix —— 让编辑器 tab 标题
    /// 看起来是 "Hello-world.txt" 而不是 uuid。删 / : \ 等 fs 不合法字符,
    /// 空白压成 -;清完为空 → "clip"
    private static func readableNamePrefix(item: Item) -> String {
        let source = item.preview ?? item.textFull ?? "clip"
        let oneline = source.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let truncated = String(oneline.prefix(30))
        var chars: [Character] = []
        for c in truncated {
            if c == "/" || c == ":" || c == "\\" || c == "\0" { continue }
            if c.isWhitespace {
                chars.append("-")
            } else {
                chars.append(c)
            }
        }
        let cleaned = String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return cleaned.isEmpty ? "clip" : cleaned
    }

    /// `.file` kind 的 textFull 拿第一行 → URL(跟 OpenWithProvider 内部同名 helper 同语义,
    /// 但 OpenWithStaging / OpenWithProvider 解耦不互相 import,这里独立一份)
    private static func firstFilePath(from item: Item) -> URL? {
        guard let raw = item.textFull ?? item.preview,
              let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first
        else { return nil }
        let trimmed = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }
}

extension OpenWithStaging {
    public enum MaterializationError: Error, CustomStringConvertible {
        case emptyContent
        case encodingFailed
        case missingBlob
        case blobNotInStore(sha: String)
        case invalidURL

        public var description: String {
            switch self {
            case .emptyContent:          return "item 内容为空"
            case .encodingFailed:        return "文本编码 UTF-8 失败"
            case .missingBlob:           return "item 无 blob_sha256"
            case .blobNotInStore(let s): return "blob 本机未缓存 (sha=\(s.prefix(8))...)"
            case .invalidURL:            return "url kind 字符串无法解析为 URL"
            }
        }
    }
}

extension Paths {
    /// "用 XXX 打开"临时文件落地路径。daemon 启动时清 24h 以上旧子目录
    public var openWithStagingDir: URL {
        root.appendingPathComponent("openwith-tmp", isDirectory: true)
    }
}

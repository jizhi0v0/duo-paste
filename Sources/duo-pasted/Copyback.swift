import Foundation
import AppKit
import DuoPasteCore

/// 把历史中的 Item 写回 NSPasteboard。
/// 调用方在 write 之后必须立刻调用 watcher.suppressUpToCurrent()，
/// 防止 watcher 把"自己粘回的"这次变更又抓回库里。
enum Copyback {
    @MainActor
    @discardableResult
    static func write(item: Item, blobs: BlobStore) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text:
            guard let s = item.textFull else { return false }
            pb.setString(s, forType: .string)
        case .rtf:
            guard let s = item.textFull else { return false }
            pb.setString(s, forType: .rtf)
            // 同时写一份 plain 以便不支持 rtf 的接收者
            if let plain = stripRTF(s) {
                pb.setString(plain, forType: .string)
            }
        case .html:
            guard let s = item.textFull else { return false }
            pb.setString(s, forType: .html)
            pb.setString(s, forType: .string)
        case .url:
            guard let s = item.textFull, let url = URL(string: s) else { return false }
            _ = pb.writeObjects([url as NSURL])
            pb.setString(s, forType: .string)
        case .image:
            guard let sha = item.blobSha256,
                  let data = try? blobs.read(sha256: sha) ?? nil else {
                return false
            }
            let mime = item.blobMime ?? ""
            if mime.contains("png") {
                pb.setData(data, forType: .png)
            } else {
                pb.setData(data, forType: .tiff)
            }
        case .file:
            guard let raw = item.textFull else { return false }
            // text_full 里是 \n 分隔的多条路径
            let paths = raw.split(separator: "\n").compactMap { (s: Substring) -> String? in
                let path = String(s).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
                return path
            }
            if !paths.isEmpty {
                let urls = paths.map { NSURL(fileURLWithPath: $0) }
                _ = pb.writeObjects(urls)
                // **多 representation 兜底**:.fileURL 之外显式写 .string + 图片字节,让不
                // 同 app 的 paste handler 各取所需:
                // - Finder / 邮件附件框 / 上传控件 → .fileURL ✓
                // - terminal (iTerm2 / Terminal.app 部分能转字符串,Zed terminal /
                //   Claude Code 不处理 fileURL paste) → .string 路径字符串
                // - 聊天软件 (飞书 / 微信 / Notes 等图片接收器) → image bytes 直接粘图
                // 没这个兜底之前 CleanShot 截图(本机有文件 + image blob)在 terminal
                // 双击 paste 完全没反应 — 因为只写了 fileURL
                pb.setString(paths.joined(separator: "\n"), forType: .string)
                if paths.count == 1,
                   isImageMime(item.blobMime),
                   let sha = item.blobSha256,
                   let data = try? blobs.read(sha256: sha) ?? nil
                {
                    writeImageData(data, mime: item.blobMime, to: pb)
                }
                return true
            }
            // 本机没有可用的文件路径——通常是跨设备同步过来的 file item（对端用户从
            // Finder / 截图工具 / 聊天软件复制了一个本地图片文件）。如果是单 image
            // 文件且我们有 blob 字节，按"图片"语义粘贴：写图片字节让聊天/图片 app
            // 拿到图，再落一份 temp 文件并写 file URL 让 Finder / 上传控件也能用。
            // 不命中（非 image / 无 blob 字节）→ 兜底纯路径字符串（旧行为）
            if let sha = item.blobSha256,
               isImageMime(item.blobMime),
               let data = try? blobs.read(sha256: sha) ?? nil
            {
                if let tempURL = materializeTempCopy(data: data, originalPath: raw, mime: item.blobMime) {
                    _ = pb.writeObjects([NSURL(fileURLWithPath: tempURL.path)])
                }
                writeImageData(data, mime: item.blobMime, to: pb)
                return true
            }
            pb.setString(raw, forType: .string)
        }

        return true
    }

    /// 合并写多项到 NSPasteboard 单次粘贴。调用方已通过 `PasteMerge.strategy(for:)` 判定走
    /// mergedText / mergedFile 路径。本函数只负责副作用:FileManager.fileExists 校验 + 写 pb。
    /// - 全 text/url/rtf/html → 拼成单字符串(\n 分隔),写 .string 一份
    /// - 全 file → 收集所有 NSURL writeObjects 一次,Finder paste 多文件
    ///
    /// 返回 false = 没数据可写(textFull 全空 / file URL 全失效)
    @MainActor
    @discardableResult
    static func writeMerged(items: [Item], blobs: BlobStore) -> Bool {
        guard !items.isEmpty else { return false }

        let allFile = items.allSatisfy { $0.kind == .file }
        if allFile {
            // 纯函数展平 + 这里加 FileManager.fileExists 兜底——路径可能在库里但磁盘已删
            let paths = PasteMerge.flattenFilePaths(items)
            let urls: [NSURL] = paths.compactMap { p in
                guard FileManager.default.fileExists(atPath: p) else { return nil }
                return NSURL(fileURLWithPath: p)
            }
            guard !urls.isEmpty else { return false }
            let pb = NSPasteboard.general
            pb.clearContents()
            _ = pb.writeObjects(urls)
            return true
        }

        // 文本类(text/url/rtf/html)——只取 textFull,拼 \n。
        // 多选合并丢掉 rtf/html 的富文本表示,只输出 plain(多份 rtf 拼起来未必合法,plain 是安全降级)
        guard let joined = PasteMerge.joinTextual(items, separator: "\n") else {
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(joined, forType: .string)
        return true
    }

    /// 多 image 多选 paste 入口。每张 image blob 字节落 temp 文件 + writeObjects 多 file URL。
    /// 接收端把它当"多文件 paste"——Finder/iMessage/微信/浏览器 input[type=file] 原生支持,
    /// Word 显示成多 attachment。
    ///
    /// **前提**:所有 image 字节本机已就绪(调用方负责先 lazy 拉缺的)。
    /// 返回 `(wrote, missingShas)`:
    /// - wrote = true: 至少写了一张到 pasteboard
    /// - missingShas: 没本机字节的 sha 列表;wrote=true 时调用方可 banner 提示用户"已 paste N 张
    ///   (共 M,余 K 张未拉到)"。空数组 = 全部 paste 成功
    ///
    /// **文件名 dedupe**:用 sha 前 16 位 + mime ext 作文件名(不用 originalPath basename),
    /// 避免 N 张同源 image(比如同一聊天工具截图缓存目录的 mac_xxx.png 列表)走 materializeTempCopy
    /// 的 basename 推理会冲突。代价:用户在 Finder paste 后看到的是 "abc123def456...png"
    /// 而非原文件名——多图 paste 场景下接受这个权衡(语义是"多文件",不是单文件复刻)
    @MainActor
    static func writeMergedImages(items: [Item], blobs: BlobStore) -> (wrote: Bool, missingShas: [String]) {
        var urls: [NSURL] = []
        var missing: [String] = []
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("duo-paste-paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for it in items {
            guard let sha = it.blobSha256 else { continue }
            guard let data = try? blobs.read(sha256: sha) ?? nil else {
                missing.append(sha)
                continue
            }
            let ext = extFromMime(it.blobMime ?? "") ?? "png"
            let name = "\(sha.prefix(16)).\(ext)"
            let url = dir.appendingPathComponent(String(name))
            do {
                try data.write(to: url, options: .atomic)
                urls.append(NSURL(fileURLWithPath: url.path))
            } catch {
                missing.append(sha)
            }
        }
        guard !urls.isEmpty else { return (false, missing) }
        let pb = NSPasteboard.general
        pb.clearContents()
        _ = pb.writeObjects(urls)
        return (true, missing)
    }

    private static func isImageMime(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.hasPrefix("image/")
    }

    private static func writeImageData(_ data: Data, mime: String?, to pb: NSPasteboard) {
        let m = mime ?? ""
        if m.contains("png") {
            pb.setData(data, forType: .png)
        } else if m.contains("tiff") {
            pb.setData(data, forType: .tiff)
        } else {
            // jpeg/heic/gif/webp 等：声明专属 type，让支持的接收者按 UTI 自取；
            // 同时落一份 .tiff fallback 给只识 image 通用 type 的旧 app
            let utType = NSPasteboard.PasteboardType(rawValue: "public." + (extFromMime(m) ?? "data"))
            pb.setData(data, forType: utType)
            pb.setData(data, forType: .tiff)
        }
    }

    /// 把 blob 字节落到 NSTemporaryDirectory 下，文件名沿用原 path 的 basename（让接收
    /// 端拿到原文件名而不是 <sha>.<ext>）。失败返回 nil，调用方继续走只写字节的路径。
    private static func materializeTempCopy(data: Data, originalPath: String, mime: String?) -> URL? {
        let firstLine = originalPath.split(separator: "\n").first.map(String.init) ?? originalPath
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let basename = (trimmed as NSString).lastPathComponent
        let safeName: String = {
            if !basename.isEmpty, basename != "/" { return basename }
            if let ext = extFromMime(mime ?? "") { return "image.\(ext)" }
            return "image"
        }()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("duo-paste-paste", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(safeName)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func extFromMime(_ mime: String) -> String? {
        switch mime {
        case "image/png":  return "png"
        case "image/jpeg": return "jpg"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/gif":  return "gif"
        case "image/webp": return "webp"
        case "image/tiff": return "tiff"
        case "image/bmp":  return "bmp"
        default:           return nil
        }
    }

    /// 朴素 RTF 转纯文本——抽 NSAttributedString 拿 string。
    private static func stripRTF(_ rtf: String) -> String? {
        guard let data = rtf.data(using: .utf8),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              )
        else { return nil }
        return attr.string
    }
}

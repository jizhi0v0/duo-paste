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
            let urls = raw.split(separator: "\n").compactMap { (s: Substring) -> NSURL? in
                let path = String(s).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
                return NSURL(fileURLWithPath: path)
            }
            if !urls.isEmpty {
                _ = pb.writeObjects(urls)
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

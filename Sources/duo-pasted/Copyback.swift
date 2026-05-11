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
            if urls.isEmpty {
                pb.setString(raw, forType: .string)
            } else {
                _ = pb.writeObjects(urls)
            }
        }

        return true
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

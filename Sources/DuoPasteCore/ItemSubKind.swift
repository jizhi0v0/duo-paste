import Foundation

/// `.file` kind 的虚拟 sub-kind——给 UI filter chip / footer label / preview 路由用。
///
/// 不是数据库列。`.file` kind 的所有信号(mime / 路径后缀)在读时再分类——既要避开 schema
/// 改动(已经在 v8),又让对端 mirror 来的 file 项也能就地分类(它们可能没 blob_mime,只有
/// textFull 路径)
public enum FileSubKind: String, Codable, Sendable, CaseIterable {
    case video
    case pdf
    case audio
    case imageFile
}

public enum ItemClassifier {
    /// `.file` kind 的细分类——优先 mime,退化到 textFull 路径后缀。
    /// 多 sub-kind 互斥优先级:video > pdf > audio > imageFile。一个 mp4 不会同时算视频+音频
    public static func fileSubKind(_ item: Item) -> FileSubKind? {
        guard item.kind == .file else { return nil }
        if isVideo(item) { return .video }
        if isPDF(item) { return .pdf }
        if isAudio(item) { return .audio }
        if isImageFile(item) { return .imageFile }
        return nil
    }

    public static func isVideo(_ item: Item) -> Bool {
        if let mime = item.blobMime, mime.hasPrefix("video/") { return true }
        guard let raw = item.textFull,
              let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return false
        }
        return fileLooksLikeVideo(path: String(first))
    }

    public static func isPDF(_ item: Item) -> Bool {
        if let mime = item.blobMime, mime == "application/pdf" { return true }
        guard let raw = item.textFull,
              let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return false
        }
        return fileLooksLikePDF(path: String(first))
    }

    public static func isAudio(_ item: Item) -> Bool {
        if let mime = item.blobMime, mime.hasPrefix("audio/") { return true }
        guard let raw = item.textFull,
              let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return false
        }
        return fileLooksLikeAudio(path: String(first))
    }

    public static func isImageFile(_ item: Item) -> Bool {
        if let mime = item.blobMime, mime.hasPrefix("image/") { return true }
        guard let raw = item.textFull,
              let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return false
        }
        return fileLooksLikeImage(path: String(first))
    }
}

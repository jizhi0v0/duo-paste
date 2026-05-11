import Foundation

/// Watcher → CaptureService 的传输对象。
/// 不依赖 AppKit，让 CaptureService 在 DuoPasteCore 里可单元测试。
public struct CapturedPasteboard: Sendable {
    public var kind: ItemKind
    /// kind=text/rtf/html/url 时填
    public var text: String?
    /// kind=image/file 时填
    public var blob: Data?
    /// blob 文件扩展名（不带点），用于落到 BlobStore 路径
    public var blobExt: String?
    public var blobMime: String?
    /// 文件类型时的原始文件名（可选）
    public var fileName: String?
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    /// 捕获的精确时刻（纳秒）
    public var capturedAtNs: Int64

    public init(
        kind: ItemKind,
        text: String? = nil,
        blob: Data? = nil,
        blobExt: String? = nil,
        blobMime: String? = nil,
        fileName: String? = nil,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        capturedAtNs: Int64 = Clock.nowNs()
    ) {
        self.kind = kind
        self.text = text
        self.blob = blob
        self.blobExt = blobExt
        self.blobMime = blobMime
        self.fileName = fileName
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.capturedAtNs = capturedAtNs
    }
}

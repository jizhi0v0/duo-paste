import Foundation
import DuoPasteCore

/// `POST /ingest` 请求体的线上格式。显式列出来而不是直接复用 Item，
/// 这样：
/// - `push_state / push_attempts / last_push_error` 是 client 内部状态，不上线
/// - `ingested_at_ns` 由 primary 在收到瞬间打，client 不该提供
/// - 字段语义变化时 wire format 可独立演进，不打扰已落盘的 Item
public struct IngestRequest: Codable, Sendable {
    public var id: String
    public var originDevice: String
    public var capturedAtNs: Int64
    public var kind: ItemKind
    public var sourceApp: String?
    public var sourceAppName: String?
    public var preview: String?
    public var textFull: String?
    public var blobSha256: String?
    public var blobSize: Int64?
    public var blobMime: String?
    public var pinned: Bool?
    public var deletedAtNs: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case originDevice = "origin_device"
        case capturedAtNs = "captured_at_ns"
        case kind
        case sourceApp = "source_app"
        case sourceAppName = "source_app_name"
        case preview
        case textFull = "text_full"
        case blobSha256 = "blob_sha256"
        case blobSize = "blob_size"
        case blobMime = "blob_mime"
        case pinned
        case deletedAtNs = "deleted_at_ns"
    }

    /// 提升为 Item，由 primary 补齐 `ingested_at_ns` 和把 `push_state` 钉成 acked
    /// （primary 是源头，不再往外推）。
    public func toItem(ingestedAtNs: Int64) -> Item {
        Item(
            id: id,
            originDevice: originDevice,
            capturedAtNs: capturedAtNs,
            ingestedAtNs: ingestedAtNs,
            kind: kind,
            sourceApp: sourceApp,
            sourceAppName: sourceAppName,
            preview: preview,
            textFull: textFull,
            blobSha256: blobSha256,
            blobSize: blobSize,
            blobMime: blobMime,
            pinned: pinned ?? false,
            deletedAtNs: deletedAtNs,
            pushState: .acked,
            pushAttempts: 0,
            lastPushError: nil
        )
    }

    /// 基本字段校验。注意：不校验内容业务逻辑（比如 image 必须带 blob_sha256），
    /// 让 client 自由发，server 只拦明显非法的（空 id、负时间戳）。
    public func validate() throws {
        if id.isEmpty || id.count > 128 {
            throw IngestError.invalidField("id 长度必须 1-128")
        }
        if originDevice.isEmpty || originDevice.count > 128 {
            throw IngestError.invalidField("origin_device 长度必须 1-128")
        }
        if capturedAtNs <= 0 {
            throw IngestError.invalidField("captured_at_ns 必须 > 0")
        }
        if let s = blobSha256, !s.isEmpty, s.count != 64 {
            throw IngestError.invalidField("blob_sha256 必须 64 字符 hex")
        }
    }
}

public enum IngestError: Error, CustomStringConvertible, Sendable {
    case bodyHashMismatch
    case bodyTooLarge(actual: Int, limit: Int)
    case decodeFailed(String)
    case invalidField(String)

    public var description: String {
        switch self {
        case .bodyHashMismatch: return "body sha256 不匹配 header"
        case .bodyTooLarge(let a, let l): return "body 太大 (\(a) > \(l))"
        case .decodeFailed(let m): return "JSON 解码失败: \(m)"
        case .invalidField(let m): return "字段非法: \(m)"
        }
    }
}

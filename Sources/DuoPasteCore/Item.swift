import Foundation
import GRDB

public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case rtf
    case html
    case url
    case image
    case file
}

public enum PushState: String, Codable, Sendable {
    case pending
    case acked
    case failed
}

public struct Item: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item"

    public var id: String
    public var originDevice: String
    public var capturedAtNs: Int64
    public var ingestedAtNs: Int64?
    public var kind: ItemKind
    public var sourceApp: String?
    public var sourceAppName: String?
    public var preview: String?
    public var textFull: String?
    public var blobSha256: String?
    public var blobSize: Int64?
    public var blobMime: String?
    public var pinned: Bool
    public var deletedAtNs: Int64?
    public var pushState: PushState
    public var pushAttempts: Int
    public var lastPushError: String?

    public init(
        id: String,
        originDevice: String,
        capturedAtNs: Int64,
        ingestedAtNs: Int64? = nil,
        kind: ItemKind,
        sourceApp: String? = nil,
        sourceAppName: String? = nil,
        preview: String? = nil,
        textFull: String? = nil,
        blobSha256: String? = nil,
        blobSize: Int64? = nil,
        blobMime: String? = nil,
        pinned: Bool = false,
        deletedAtNs: Int64? = nil,
        pushState: PushState = .pending,
        pushAttempts: Int = 0,
        lastPushError: String? = nil
    ) {
        self.id = id
        self.originDevice = originDevice
        self.capturedAtNs = capturedAtNs
        self.ingestedAtNs = ingestedAtNs
        self.kind = kind
        self.sourceApp = sourceApp
        self.sourceAppName = sourceAppName
        self.preview = preview
        self.textFull = textFull
        self.blobSha256 = blobSha256
        self.blobSize = blobSize
        self.blobMime = blobMime
        self.pinned = pinned
        self.deletedAtNs = deletedAtNs
        self.pushState = pushState
        self.pushAttempts = pushAttempts
        self.lastPushError = lastPushError
    }

    enum CodingKeys: String, CodingKey {
        case id
        case originDevice = "origin_device"
        case capturedAtNs = "captured_at_ns"
        case ingestedAtNs = "ingested_at_ns"
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
        case pushState = "push_state"
        case pushAttempts = "push_attempts"
        case lastPushError = "last_push_error"
    }
}

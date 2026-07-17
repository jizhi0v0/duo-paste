import Foundation

/// 一个保存视图的完整搜索条件快照。这里保留 GUI chip 和 slash qualifier 两条独立状态，
/// 应用时可原样恢复 UI，而不是只保存它们合并后的 SQL kinds。
public struct SavedSearchFilter: Codable, Sendable, Equatable {
    public var query: String
    public var qualifiers: [QueryQualifier]
    public var kinds: [ItemKind]
    public var fileSubKinds: [FileSubKind]
    public var timeRange: SearchTimeRange
    public var pinnedOnly: Bool

    public init(
        query: String,
        qualifiers: [QueryQualifier],
        kinds: [ItemKind],
        fileSubKinds: [FileSubKind],
        timeRange: SearchTimeRange,
        pinnedOnly: Bool
    ) {
        self.query = query
        self.qualifiers = qualifiers
        self.kinds = kinds
        self.fileSubKinds = fileSubKinds
        self.timeRange = timeRange
        self.pinnedOnly = pinnedOnly
    }

    enum CodingKeys: String, CodingKey {
        case query
        case qualifiers
        case kinds
        case fileSubKinds = "file_sub_kinds"
        case timeRange = "time_range"
        case pinnedOnly = "pinned_only"
    }
}

public struct SavedSearchView: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var filter: SavedSearchFilter

    public init(id: String, name: String, filter: SavedSearchFilter) {
        self.id = id
        self.name = name
        self.filter = filter
    }
}

public struct SavedSearchViewSaveOutcome: Sendable, Equatable {
    public var view: SavedSearchView
    public var wasUpdate: Bool

    public init(view: SavedSearchView, wasUpdate: Bool) {
        self.view = view
        self.wasUpdate = wasUpdate
    }
}

public enum SavedSearchViewError: Error, Sendable, Equatable, LocalizedError {
    case emptyName
    case nameTooLong(maximum: Int)
    case libraryFull(maximum: Int)
    case invalidLibrary(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "视图名称不能为空"
        case .nameTooLong(let maximum):
            "视图名称不能超过 \(maximum) 个字符"
        case .libraryFull(let maximum):
            "最多保存 \(maximum) 个视图"
        case .invalidLibrary(let reason):
            "保存视图文件无效：\(reason)"
        case .unsupportedVersion(let version):
            "保存视图文件版本 \(version) 暂不支持"
        }
    }
}

/// 内存中的命名视图库。同名（trim 后、忽略大小写）是 update，不新增第二条；ID 保持稳定，
/// 让菜单栏持有的 representedObject 不会因为改名/更新筛选而失效。
public struct SavedSearchViewLibrary: Sendable, Equatable {
    public static let maximumNameLength = 60
    public static let maximumViewCount = 50

    public private(set) var views: [SavedSearchView]

    public init(views: [SavedSearchView] = []) {
        self.views = views
    }

    @discardableResult
    public mutating func upsert(
        name: String,
        filter: SavedSearchFilter,
        makeID: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> SavedSearchViewSaveOutcome {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw SavedSearchViewError.emptyName }
        guard normalizedName.count <= Self.maximumNameLength else {
            throw SavedSearchViewError.nameTooLong(maximum: Self.maximumNameLength)
        }

        if let index = views.firstIndex(where: {
            $0.name.compare(normalizedName, options: .caseInsensitive) == .orderedSame
        }) {
            let saved = SavedSearchView(
                id: views[index].id,
                name: normalizedName,
                filter: filter
            )
            views[index] = saved
            return SavedSearchViewSaveOutcome(view: saved, wasUpdate: true)
        }

        guard views.count < Self.maximumViewCount else {
            throw SavedSearchViewError.libraryFull(maximum: Self.maximumViewCount)
        }
        let id = makeID().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !views.contains(where: { $0.id == id }) else {
            throw SavedSearchViewError.invalidLibrary("视图 ID 为空或重复")
        }
        let saved = SavedSearchView(id: id, name: normalizedName, filter: filter)
        views.append(saved)
        return SavedSearchViewSaveOutcome(view: saved, wasUpdate: false)
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard let index = views.firstIndex(where: { $0.id == id }) else { return false }
        views.remove(at: index)
        return true
    }

    fileprivate func validate() throws {
        guard views.count <= Self.maximumViewCount else {
            throw SavedSearchViewError.libraryFull(maximum: Self.maximumViewCount)
        }
        var ids = Set<String>()
        var names = Set<String>()
        for view in views {
            let name = view.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = view.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id == view.id, ids.insert(id).inserted else {
                throw SavedSearchViewError.invalidLibrary("视图 ID 为空或重复")
            }
            guard !name.isEmpty, name == view.name, name.count <= Self.maximumNameLength else {
                throw SavedSearchViewError.invalidLibrary("视图名称为空或过长")
            }
            let nameKey = name.folding(options: .caseInsensitive, locale: nil)
            guard names.insert(nameKey).inserted else {
                throw SavedSearchViewError.invalidLibrary("视图名称重复")
            }
        }
    }
}

/// 每台设备自己的版本化保存视图文件。成功写盘前调用方不应发布新的 Library。
public struct SavedSearchViewStore: Sendable {
    public static let currentVersion = 1
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> SavedSearchViewLibrary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SavedSearchViewLibrary()
        }
        let data = try Data(contentsOf: fileURL)
        let header: VersionHeader
        do {
            header = try JSONDecoder().decode(VersionHeader.self, from: data)
        } catch {
            throw SavedSearchViewError.invalidLibrary("JSON 无法解码")
        }
        guard header.version == Self.currentVersion else {
            throw SavedSearchViewError.unsupportedVersion(header.version)
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw SavedSearchViewError.invalidLibrary("JSON 无法解码")
        }
        let library = SavedSearchViewLibrary(views: envelope.views)
        try library.validate()
        return library
    }

    public func save(_ library: SavedSearchViewLibrary) throws {
        try library.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: Self.currentVersion, views: library.views))
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private struct Envelope: Codable {
        var version: Int
        var views: [SavedSearchView]
    }

    private struct VersionHeader: Decodable {
        var version: Int
    }
}

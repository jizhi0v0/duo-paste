import Foundation
import Testing
@testable import DuoPasteCore

private func savedFilter(seed: Int = 0) -> SavedSearchFilter {
    SavedSearchFilter(
        query: "release \(seed)",
        qualifiers: [
            .kind(.text),
            .fileSubKind(.pdf),
            .textSuffix(".swift"),
            .imageMerged,
        ],
        kinds: [.text, .url],
        fileSubKinds: [.pdf, .video],
        timeRange: .custom(
            start: Date(timeIntervalSince1970: 1_783_622_400),
            end: Date(timeIntervalSince1970: 1_783_795_200)
        ),
        pinnedOnly: seed.isMultiple(of: 2)
    )
}

@Test("保存视图完整筛选字段 Codable round-trip")
func savedSearchFilterCodableRoundTrip() throws {
    let original = SavedSearchView(
        id: "view-1",
        name: "发布资料",
        filter: savedFilter()
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SavedSearchView.self, from: data)
    let json = String(decoding: data, as: UTF8.self)

    #expect(decoded == original)
    #expect(decoded.filter.qualifiers.count == 4)
    #expect(decoded.filter.timeRange == original.filter.timeRange)
    #expect(json.contains("file_sub_kinds"))
    #expect(json.contains("image_merged"))
    #expect(json.contains("start_ms"))
}

@Test("全部预设时间范围也能稳定 round-trip")
func savedSearchPresetTimeRangesRoundTrip() throws {
    for range in SearchTimeRange.presets {
        let data = try JSONEncoder().encode(range)
        #expect(try JSONDecoder().decode(SearchTimeRange.self, from: data) == range)
    }
}

@Test("同名保存忽略大小写更新并保留稳定 ID")
func savedSearchLibraryUpsertsByNormalizedName() throws {
    var library = SavedSearchViewLibrary()
    let inserted = try library.upsert(
        name: "  Work  ",
        filter: savedFilter(),
        makeID: { "stable-id" }
    )
    let updated = try library.upsert(
        name: "work",
        filter: savedFilter(seed: 1),
        makeID: { "must-not-be-used" }
    )

    #expect(inserted.wasUpdate == false)
    #expect(updated.wasUpdate == true)
    #expect(library.views.count == 1)
    #expect(library.views[0].id == "stable-id")
    #expect(library.views[0].name == "work")
    #expect(library.views[0].filter == savedFilter(seed: 1))
}

@Test("名称校验、容量上限与删除行为")
func savedSearchLibraryValidatesAndDeletes() throws {
    var library = SavedSearchViewLibrary()
    #expect(throws: SavedSearchViewError.self) {
        try library.upsert(name: "   ", filter: savedFilter())
    }
    #expect(throws: SavedSearchViewError.self) {
        try library.upsert(name: String(repeating: "长", count: 61), filter: savedFilter())
    }

    for index in 0..<SavedSearchViewLibrary.maximumViewCount {
        _ = try library.upsert(
            name: "view-\(index)",
            filter: savedFilter(seed: index),
            makeID: { "id-\(index)" }
        )
    }
    #expect(throws: SavedSearchViewError.self) {
        try library.upsert(name: "overflow", filter: savedFilter())
    }

    #expect(library.remove(id: "id-20") == true)
    #expect(library.remove(id: "missing") == false)
    #expect(library.views.count == SavedSearchViewLibrary.maximumViewCount - 1)
}

@Test("缺文件为空；原子保存后重开内容顺序一致且权限 0600")
func savedSearchStoreRoundTripAndPermissions() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-saved-search-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("saved-search-views.json")
    let store = SavedSearchViewStore(fileURL: file)

    #expect(try store.load().views.isEmpty)

    var library = SavedSearchViewLibrary()
    _ = try library.upsert(name: "First", filter: savedFilter(), makeID: { "one" })
    _ = try library.upsert(name: "Second", filter: savedFilter(seed: 1), makeID: { "two" })
    try store.save(library)

    let reopened = try SavedSearchViewStore(fileURL: file).load()
    #expect(reopened == library)
    #expect(reopened.views.map(\.id) == ["one", "two"])
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test("未来 schema version 明确失败")
func savedSearchStoreRejectsFutureVersion() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-saved-search-version-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("saved-search-views.json")
    // future payload 即使已改变 views 形态，也要先读 header 明确报 unsupportedVersion，
    // 不能先按 v1 全量解码后只得到模糊的 corrupt JSON。
    try Data("{\"version\":99,\"views\":{\"future\":true}}".utf8).write(to: file)

    #expect(throws: SavedSearchViewError.self) {
        try SavedSearchViewStore(fileURL: file).load()
    }
}

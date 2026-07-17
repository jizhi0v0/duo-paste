import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

private func nanoseconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1_000_000_000)
}

private func calendar(timeZone identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
}

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 0,
    calendar: Calendar
) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

@Test("全部时间与滚动预设保持原有语义")
func searchTimeRangePresets() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(SearchTimeRange.all.bounds(now: now) == SearchTimeBounds(fromNs: nil, toNs: nil))
    #expect(SearchTimeRange.day.bounds(now: now).fromNs == nanoseconds(now.addingTimeInterval(-24 * 3600)))
    #expect(SearchTimeRange.week.bounds(now: now).fromNs == nanoseconds(now.addingTimeInterval(-7 * 24 * 3600)))
    #expect(SearchTimeRange.month.bounds(now: now).fromNs == nanoseconds(now.addingTimeInterval(-30 * 24 * 3600)))
    #expect(SearchTimeRange.day.bounds(now: now).toNs == nil)
}

@Test("自定义日期按本地日界线解释并正确覆盖 DST 23 小时日")
func customSearchTimeRangeUsesCalendarDayBoundaries() {
    let losAngeles = calendar(timeZone: "America/Los_Angeles")
    let selected = date(2026, 3, 8, hour: 12, calendar: losAngeles)
    let nextDay = date(2026, 3, 9, calendar: losAngeles)

    let bounds = SearchTimeRange.custom(start: selected, end: selected)
        .bounds(calendar: losAngeles)

    #expect(bounds.fromNs == nanoseconds(date(2026, 3, 8, calendar: losAngeles)))
    #expect(bounds.toNs == nanoseconds(nextDay) - 1)
    #expect((bounds.toNs! + 1 - bounds.fromNs!) == 23 * 3600 * 1_000_000_000)
}

@Test("跨日自定义范围包含首尾整天，倒序输入也归一化")
func customSearchTimeRangeNormalizesCrossDaySelection() {
    let shanghai = calendar(timeZone: "Asia/Shanghai")
    let earlier = date(2026, 7, 10, hour: 18, calendar: shanghai)
    let later = date(2026, 7, 12, hour: 8, calendar: shanghai)
    let expected = SearchTimeBounds(
        fromNs: nanoseconds(date(2026, 7, 10, calendar: shanghai)),
        toNs: nanoseconds(date(2026, 7, 13, calendar: shanghai)) - 1
    )

    #expect(SearchTimeRange.custom(start: earlier, end: later).bounds(calendar: shanghai) == expected)
    #expect(SearchTimeRange.custom(start: later, end: earlier).bounds(calendar: shanghai) == expected)
}

@Test("清除自定义范围恢复无边界查询")
func clearingCustomSearchTimeRangeRemovesBothBounds() {
    let shanghai = calendar(timeZone: "Asia/Shanghai")
    let selected = date(2026, 7, 10, calendar: shanghai)
    var range = SearchTimeRange.custom(start: selected, end: selected)
    #expect(range.bounds(calendar: shanghai).fromNs != nil)
    #expect(range.bounds(calendar: shanghai).toNs != nil)

    range = .all
    #expect(range.bounds(calendar: shanghai) == SearchTimeBounds(fromNs: nil, toNs: nil))
}

@Test("自定义边界下列表、总数和类型 chip 使用同一时间窗")
func customSearchTimeRangeKeepsHitsTotalAndChipCountsConsistent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-search-time-range-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    defer { try? FileManager.default.removeItem(at: root) }

    let database = try DuoPasteCore.Database(path: paths.mainDB)
    let api = SearchAPI(database: database)
    let shanghai = calendar(timeZone: "Asia/Shanghai")
    let bounds = SearchTimeRange.custom(
        start: date(2026, 7, 10, calendar: shanghai),
        end: date(2026, 7, 11, calendar: shanghai)
    ).bounds(calendar: shanghai)

    let fixtures: [(String, ItemKind, Int64)] = [
        ("before", .text, bounds.fromNs! - 1),
        ("at-start", .text, bounds.fromNs!),
        ("middle", .image, bounds.fromNs! + 12 * 3600 * 1_000_000_000),
        ("at-end", .text, bounds.toNs!),
        ("after", .file, bounds.toNs! + 1),
    ]
    try database.pool.write { db in
        for (id, kind, capturedAtNs) in fixtures {
            let item = Item(
                id: id,
                originDevice: "time-range-test",
                capturedAtNs: capturedAtNs,
                ingestedAtNs: capturedAtNs,
                kind: kind,
                preview: id,
                textFull: id
            )
            try item.insert(db)
        }
    }

    let query = SearchQuery(fromNs: bounds.fromNs, toNs: bounds.toNs, limit: 200)
    let result = try api.searchHitsAndCount(query)
    let separateCount = try api.count(query)
    let kindCounts = try api.countByKind(query)

    #expect(Set(result.hits.map(\.0.id)) == ["at-start", "middle", "at-end"])
    #expect(result.total == 3)
    #expect(separateCount == result.total)
    #expect(kindCounts[.text] == 2)
    #expect(kindCounts[.image] == 1)
    #expect(kindCounts.values.reduce(0, +) == result.total)
}

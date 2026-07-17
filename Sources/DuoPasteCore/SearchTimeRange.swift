import Foundation

/// `SearchQuery` 可直接消费的纳秒级时间边界。
///
/// SQLite 查询使用 inclusive `>= fromNs` / `<= toNs`，所以自定义日期范围的
/// `toNs` 会落在结束日本地次日 00:00 前 1ns。
public struct SearchTimeBounds: Sendable, Equatable {
    public var fromNs: Int64?
    public var toNs: Int64?

    public init(fromNs: Int64?, toNs: Int64?) {
        self.fromNs = fromNs
        self.toNs = toNs
    }
}

/// 搜索面板支持的时间范围。
///
/// 预设范围保留原有滚动时长语义；`.custom` 按调用方注入的 Calendar 解释为完整本地日，
/// 避免用固定 24h 算术切坏 DST 的 23/25 小时日期。
public enum SearchTimeRange: Sendable, Equatable, Hashable, Identifiable {
    case all
    case day
    case week
    case month
    case custom(start: Date, end: Date)

    /// 菜单中固定展示的四个预设；自定义范围由 DatePicker 单独产生。
    public static let presets: [SearchTimeRange] = [.all, .day, .week, .month]

    public var id: String { filterKey }

    /// 给 UI refresh task 使用的稳定指纹。不会把动态 `now` 编入 key，避免时间流逝本身
    /// 触发无意义 refresh；自定义日期变化则一定产生新 key。
    public var filterKey: String {
        switch self {
        case .all: "all"
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .custom(let start, let end):
            "custom:\(start.timeIntervalSinceReferenceDate):\(end.timeIntervalSinceReferenceDate)"
        }
    }

    public func bounds(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SearchTimeBounds {
        switch self {
        case .all:
            return SearchTimeBounds(fromNs: nil, toNs: nil)
        case .day:
            return rollingBounds(seconds: 24 * 3600, now: now)
        case .week:
            return rollingBounds(seconds: 7 * 24 * 3600, now: now)
        case .month:
            return rollingBounds(seconds: 30 * 24 * 3600, now: now)
        case .custom(let start, let end):
            let firstSelectedDay = calendar.startOfDay(for: start)
            let secondSelectedDay = calendar.startOfDay(for: end)
            let lowerDay = min(firstSelectedDay, secondSelectedDay)
            let upperDay = max(firstSelectedDay, secondSelectedDay)
            guard let dayAfterUpper = calendar.date(byAdding: .day, value: 1, to: upperDay) else {
                return SearchTimeBounds(fromNs: Self.nanoseconds(lowerDay), toNs: Self.nanoseconds(upperDay))
            }
            return SearchTimeBounds(
                fromNs: Self.nanoseconds(lowerDay),
                toNs: Self.nanoseconds(dayAfterUpper) - 1
            )
        }
    }

    private func rollingBounds(seconds: TimeInterval, now: Date) -> SearchTimeBounds {
        SearchTimeBounds(
            fromNs: Self.nanoseconds(now.addingTimeInterval(-seconds)),
            toNs: nil
        )
    }

    private static func nanoseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000_000_000
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }
}

extension SearchTimeRange: Codable {
    private enum RangeType: String, Codable {
        case all
        case day
        case week
        case month
        case custom
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case startMs = "start_ms"
        case endMs = "end_ms"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(RangeType.self, forKey: .type) {
        case .all:
            self = .all
        case .day:
            self = .day
        case .week:
            self = .week
        case .month:
            self = .month
        case .custom:
            let startMs = try container.decode(Int64.self, forKey: .startMs)
            let endMs = try container.decode(Int64.self, forKey: .endMs)
            self = .custom(
                start: Date(timeIntervalSince1970: Double(startMs) / 1_000),
                end: Date(timeIntervalSince1970: Double(endMs) / 1_000)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try container.encode(RangeType.all, forKey: .type)
        case .day:
            try container.encode(RangeType.day, forKey: .type)
        case .week:
            try container.encode(RangeType.week, forKey: .type)
        case .month:
            try container.encode(RangeType.month, forKey: .type)
        case .custom(let start, let end):
            try container.encode(RangeType.custom, forKey: .type)
            try container.encode(Self.milliseconds(start), forKey: .startMs)
            try container.encode(Self.milliseconds(end), forKey: .endMs)
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }
}

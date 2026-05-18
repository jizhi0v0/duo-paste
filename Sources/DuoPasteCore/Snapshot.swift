import Foundation

public enum Snapshot {
    public static let filenamePrefix = "duo-paste-"
    public static let filenameSuffix = ".sqlite"

    /// 文件名时间格式：yyyyMMdd-HHmmss，本地时区。
    /// 例：duo-paste-20260511-180300.sqlite
    public static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func filename(for date: Date) -> String {
        "\(filenamePrefix)\(nameFormatter.string(from: date))\(filenameSuffix)"
    }

    /// 从文件名反解时间。无法解析返回 nil。
    public static func parseDate(from filename: String) -> Date? {
        guard filename.hasPrefix(filenamePrefix), filename.hasSuffix(filenameSuffix) else {
            return nil
        }
        let middle = String(
            filename.dropFirst(filenamePrefix.count).dropLast(filenameSuffix.count)
        )
        return nameFormatter.date(from: middle)
    }

    /// 把当前主库 VACUUM INTO 到 snapshots 目录，返回快照文件 URL。
    @discardableResult
    public static func takeSnapshot(
        database: Database,
        paths: Paths,
        now: Date = Date()
    ) throws -> URL {
        let url = paths.snapshotsDir.appendingPathComponent(filename(for: now))
        // VACUUM INTO 要求事务外执行
        _ = try database.pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
        return url
    }

    /// 按保留策略清理快照目录，返回被删除的文件 URL 列表。
    /// 策略：
    /// - 最近 24h 内：全保留
    /// - 24h ~ 30d 内：每天保留最新一份
    /// - 30d 之外：每月保留最新一份
    @discardableResult
    public static func prune(
        snapshotsDir: URL,
        now: Date = Date(),
        calendar: Calendar = Calendar.current
    ) throws -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: snapshotsDir.path) else {
            return []
        }

        struct Entry {
            let url: URL
            let date: Date
        }

        let parsed: [Entry] = entries.compactMap { name in
            guard let date = parseDate(from: name) else { return nil }
            return Entry(url: snapshotsDir.appendingPathComponent(name), date: date)
        }.sorted { $0.date > $1.date }   // 新 → 旧

        let dayCutoff = now.addingTimeInterval(-24 * 3600)
        let monthCutoff = now.addingTimeInterval(-30 * 24 * 3600)

        var keptDayKeys = Set<String>()    // 在 24h~30d 段，已经为这一天保留过
        var keptMonthKeys = Set<String>()  // 在 30d+ 段，已经为这一月保留过
        // locale=en_US_POSIX 与 nameFormatter 对齐，杜绝极端 locale + 自定义 calendar
        // 配置下 yyyy-MM-dd / yyyy-MM 输出走非公历（如 ja_JP 配 Japanese calendar）导致
        // 同一日期产出不同 key
        let dayKeyFmt: DateFormatter = {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
        let monthKeyFmt: DateFormatter = {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM"
            return f
        }()

        var toDelete: [URL] = []
        for entry in parsed {
            if entry.date >= dayCutoff {
                // 最近 24h：全保留
                continue
            } else if entry.date >= monthCutoff {
                let key = dayKeyFmt.string(from: entry.date)
                if keptDayKeys.contains(key) {
                    toDelete.append(entry.url)
                } else {
                    keptDayKeys.insert(key)
                }
            } else {
                let key = monthKeyFmt.string(from: entry.date)
                if keptMonthKeys.contains(key) {
                    toDelete.append(entry.url)
                } else {
                    keptMonthKeys.insert(key)
                }
            }
        }

        for url in toDelete {
            try? fm.removeItem(at: url)
        }
        return toDelete
    }
}

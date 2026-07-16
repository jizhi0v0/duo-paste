import Foundation
import Darwin
import GRDB

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

    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let date: Date
        public let sizeBytes: Int64
    }

    public struct VerificationReport: Sendable, Equatable {
        public let url: URL
        public let sizeBytes: Int64
        public let itemCount: Int
        public let activeItemCount: Int
        public let tombstoneCount: Int
        public let activeBlobCount: Int
        public let missingBlobCount: Int
        public let missingBlobSamples: [String]
        public let integrityResult: String
    }

    public struct PreparedRecovery: Sendable {
        public let sourceSnapshot: URL
        public let livePaths: Paths
        public let stagingPaths: Paths
        public let sourceReport: VerificationReport
    }

    public struct CommitReport: Sendable, Equatable {
        public let safetyBackup: URL
        public let restored: VerificationReport
        public let mergedBlobCount: Int
    }

    public enum RecoveryError: Error, CustomStringConvertible, Sendable {
        case noSnapshots(URL)
        case invalidSnapshotName(String)
        case integrityFailed(path: URL, result: String)
        case missingItemTable(URL)
        case daemonRunning(String)
        case liveDatabaseDirectoryMissing(URL)
        case atomicSwapFailed(String)
        case postCommitVerificationFailed(String)

        public var description: String {
            switch self {
            case .noSnapshots(let dir):
                return "没有可用 snapshot：\(dir.path)"
            case .invalidSnapshotName(let value):
                return "找不到 snapshot：\(value)"
            case .integrityFailed(let path, let result):
                return "snapshot integrity_check 失败：\(path.path) · \(result)"
            case .missingItemTable(let path):
                return "snapshot 缺 item 表：\(path.path)"
            case .daemonRunning(let label):
                return "恢复中止：daemon (\(label)) 仍 loaded；先 launchctl bootout"
            case .liveDatabaseDirectoryMissing(let path):
                return "恢复中止：live DB 目录不存在：\(path.path)"
            case .atomicSwapFailed(let reason):
                return "原子换库失败：\(reason)"
            case .postCommitVerificationFailed(let reason):
                return "换库后验证失败，已回滚：\(reason)"
            }
        }
    }

    /// 只列合法 snapshot 文件，不把 recovery safety 目录或临时文件混进来。
    public static func list(snapshotsDir: URL) throws -> [Entry] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url -> Entry? in
            guard let date = parseDate(from: url.lastPathComponent) else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            return Entry(url: url, date: date, sizeBytes: Int64(values.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    public static func resolve(_ value: String?, snapshotsDir: URL) throws -> URL {
        if value == nil || value == "latest" {
            guard let latest = try list(snapshotsDir: snapshotsDir).first else {
                throw RecoveryError.noSnapshots(snapshotsDir)
            }
            return latest.url
        }
        let raw = value!
        let direct = URL(fileURLWithPath: raw)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let named = snapshotsDir.appendingPathComponent(raw)
        if FileManager.default.fileExists(atPath: named.path) { return named }
        throw RecoveryError.invalidSnapshotName(raw)
    }

    /// 对 snapshot / 恢复后的 DB 做只读完整性与可恢复性报告。`blobStores` 按优先级视作
    /// 可用字节集合；恢复 staging 时传 `[live, staged]`，普通 verify 只传 live。
    public static func verify(
        at url: URL,
        blobStores: [BlobStore] = [],
        missingSampleLimit: Int = 10
    ) throws -> VerificationReport {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let raw = try queue.read { db -> (String, Int, Int, [String]) in
            let hasItem = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='item'
            """) ?? 0
            guard hasItem == 1 else { throw RecoveryError.missingItemTable(url) }
            let integrityRows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            let integrity = integrityRows.joined(separator: "; ")
            guard integrityRows == ["ok"] else {
                throw RecoveryError.integrityFailed(path: url, result: integrity)
            }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0
            let tombstones = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM item WHERE deleted_at_ns IS NOT NULL"
            ) ?? 0
            let shas = try String.fetchAll(db, sql: """
                SELECT DISTINCT blob_sha256 FROM item
                WHERE blob_sha256 IS NOT NULL
                  AND deleted_at_ns IS NULL
                  AND kind IN ('image', 'file')
                ORDER BY blob_sha256
            """)
            return (integrity, total, tombstones, shas)
        }
        let missing = raw.3.filter { sha in
            !blobStores.contains(where: { $0.exists(sha256: sha) })
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return VerificationReport(
            url: url,
            sizeBytes: size,
            itemCount: raw.1,
            activeItemCount: raw.1 - raw.2,
            tombstoneCount: raw.2,
            activeBlobCount: raw.3.count,
            missingBlobCount: missing.count,
            missingBlobSamples: Array(missing.prefix(max(0, missingSampleLimit))),
            integrityResult: raw.0
        )
    }

    /// 把 source snapshot 复制到独立 staging root，并用当前二进制跑完 migration。
    /// 此阶段绝不打开或改写 live DB，适合 dry-run 和网络恢复失败的安全回退。
    public static func prepareRecovery(
        from sourceSnapshot: URL,
        livePaths: Paths
    ) throws -> PreparedRecovery {
        let sourceReport = try verify(
            at: sourceSnapshot,
            blobStores: [BlobStore(root: livePaths.blobsDir)]
        )
        let stagingRoot = livePaths.root.appendingPathComponent(
            ".snapshot-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let staging = Paths(root: stagingRoot)
        staging.ensureExists()
        do {
            try FileManager.default.copyItem(at: sourceSnapshot, to: staging.mainDB)
            let candidate = try Database(path: staging.mainDB)
            _ = try candidate.pool.read { db in
                let rows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                guard rows == ["ok"] else {
                    throw RecoveryError.integrityFailed(
                        path: staging.mainDB,
                        result: rows.joined(separator: "; ")
                    )
                }
            }
            try candidate.pool.close()
            return PreparedRecovery(
                sourceSnapshot: sourceSnapshot,
                livePaths: livePaths,
                stagingPaths: staging,
                sourceReport: sourceReport
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
    }

    public static func discardRecovery(_ prepared: PreparedRecovery) {
        try? FileManager.default.removeItem(at: prepared.stagingPaths.root)
    }

    /// 候选库/网络回填都完成后的唯一 live mutation 入口。
    /// blob 先以 content-addressed 校验合并；随后 copy safety backup；最后同卷原子 swap DB 目录。
    public static func commitRecovery(
        _ prepared: PreparedRecovery,
        daemonRunning: Bool,
        daemonLabel: String,
        now: Date = Date()
    ) throws -> CommitReport {
        guard !daemonRunning else { throw RecoveryError.daemonRunning(daemonLabel) }
        let fm = FileManager.default
        let live = prepared.livePaths
        let staged = prepared.stagingPaths
        guard fm.fileExists(atPath: live.dbDir.path) else {
            throw RecoveryError.liveDatabaseDirectoryMissing(live.dbDir)
        }

        // migration + integrity 必须在 live mutation 之前完成；close 后目录才可安全 swap。
        let candidate = try Database(path: staged.mainDB)
        _ = try candidate.pool.read { db in
            let rows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            guard rows == ["ok"] else {
                throw RecoveryError.integrityFailed(
                    path: staged.mainDB,
                    result: rows.joined(separator: "; ")
                )
            }
        }
        try candidate.pool.close()

        let mergedBlobCount = try mergeStagedBlobs(
            staged: BlobStore(root: staged.blobsDir),
            live: BlobStore(root: live.blobsDir)
        )

        let safety = live.snapshotsDir.appendingPathComponent(
            "recovery-safety-\(nameFormatter.string(from: now))-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: safety, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: live.dbDir, to: safety.appendingPathComponent("db"))
        } catch {
            try? fm.removeItem(at: safety)
            throw error
        }

        do {
            try atomicSwapDirectories(staged.dbDir, live.dbDir)
        } catch {
            throw RecoveryError.atomicSwapFailed("\(error)")
        }

        do {
            let installed = try Database(path: live.mainDB)
            _ = try installed.pool.read { db in
                let rows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                guard rows == ["ok"] else {
                    throw RecoveryError.integrityFailed(
                        path: live.mainDB,
                        result: rows.joined(separator: "; ")
                    )
                }
            }
            try installed.pool.close()
            let report = try verify(
                at: live.mainDB,
                blobStores: [BlobStore(root: live.blobsDir)]
            )
            // swap 后 staged.dbDir 装的是旧 live DB；safety 已完整保留它，清掉 staging。
            try? fm.removeItem(at: staged.root)
            return CommitReport(
                safetyBackup: safety,
                restored: report,
                mergedBlobCount: mergedBlobCount
            )
        } catch {
            do {
                try atomicSwapDirectories(staged.dbDir, live.dbDir)
            } catch let rollbackError {
                throw RecoveryError.postCommitVerificationFailed(
                    "\(error)；且原子回滚失败：\(rollbackError)；safety=\(safety.path)"
                )
            }
            throw RecoveryError.postCommitVerificationFailed("\(error)")
        }
    }

    private static func mergeStagedBlobs(staged: BlobStore, live: BlobStore) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: staged.root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var merged = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let name = file.lastPathComponent
            guard name.count >= 64 else { continue }
            let sha = String(name.prefix(64))
            guard sha.allSatisfy({ $0.isHexDigit }) else { continue }
            if live.exists(sha256: sha) { continue }
            let data = try Data(contentsOf: file)
            let ext = file.pathExtension.isEmpty ? nil : file.pathExtension
            _ = try live.putVerified(data, expectedSha256: sha, ext: ext)
            merged += 1
        }
        return merged
    }

    private static func atomicSwapDirectories(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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

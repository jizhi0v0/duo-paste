import Foundation
import GRDB

public enum ExportFormat: String, Sendable, CaseIterable {
    case json
    case markdown
    case sqlite
}

public struct ExportOptions: Sendable {
    public var format: ExportFormat
    public var query: SearchQuery
    public var includeBlobs: Bool

    public init(format: ExportFormat, query: SearchQuery = SearchQuery(limit: 1_000_000), includeBlobs: Bool = true) {
        self.format = format
        self.query = query
        self.includeBlobs = includeBlobs
    }
}

public struct ExportResult: Sendable {
    public let destination: URL
    public let itemCount: Int
    public let blobCount: Int
}

public struct Exporter: Sendable {
    public let database: Database
    public let blobs: BlobStore

    public init(database: Database, blobs: BlobStore) {
        self.database = database
        self.blobs = blobs
    }

    /// 把数据导出到目录 `dir`，已存在则覆盖其中内容。
    public func export(to dir: URL, options: ExportOptions) throws -> ExportResult {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let items = try database.pool.read { db in
            try SearchAPI.fetch(db, query: options.query)
        }

        switch options.format {
        case .json:
            return try writeJSON(items: items, to: dir, includeBlobs: options.includeBlobs)
        case .markdown:
            return try writeMarkdown(items: items, to: dir, includeBlobs: options.includeBlobs)
        case .sqlite:
            return try writeSQLite(items: items, to: dir, includeBlobs: options.includeBlobs)
        }
    }

    // MARK: - JSON

    private func writeJSON(items: [Item], to dir: URL, includeBlobs: Bool) throws -> ExportResult {
        let payload: [String: Any] = [
            "schema_version": 1,
            "exported_at_ns": Clock.nowNs(),
            "item_count": items.count,
            "items": try items.map { try itemDict($0) },
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let file = dir.appendingPathComponent("duo-paste-export.json")
        try data.write(to: file, options: [.atomic])

        let blobCount = includeBlobs ? try copyReferencedBlobs(items: items, to: dir) : 0
        return ExportResult(destination: file, itemCount: items.count, blobCount: blobCount)
    }

    private func itemDict(_ item: Item) throws -> [String: Any] {
        let data = try JSONEncoder().encode(item)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    // MARK: - Markdown

    private func writeMarkdown(items: [Item], to dir: URL, includeBlobs: Bool) throws -> ExportResult {
        let blobCount = includeBlobs ? try copyReferencedBlobs(items: items, to: dir) : 0

        // 按天分组（本地时区）
        let grouped = Dictionary(grouping: items) { item -> String in
            let date = Date(timeIntervalSince1970: TimeInterval(item.capturedAtNs) / 1_000_000_000)
            return dayKey(date)
        }

        var md = "# duo-paste 导出\n\n"
        md += "导出时间：\(humanDate(Date())) · 共 \(items.count) 条\n\n"

        for day in grouped.keys.sorted(by: >) {
            md += "## \(day)\n\n"
            let dayItems = grouped[day]!.sorted { $0.capturedAtNs > $1.capturedAtNs }
            for item in dayItems {
                md += render(item) + "\n"
            }
        }

        let file = dir.appendingPathComponent("duo-paste-export.md")
        try md.write(to: file, atomically: true, encoding: .utf8)
        return ExportResult(destination: file, itemCount: items.count, blobCount: blobCount)
    }

    private func render(_ item: Item) -> String {
        let t = humanDate(Date(timeIntervalSince1970: TimeInterval(item.capturedAtNs) / 1_000_000_000))
        let src = item.sourceAppName ?? item.sourceApp ?? "?"
        let header = "**\(t)** · \(item.kind.rawValue) · \(src)"
        switch item.kind {
        case .text, .url:
            let body = item.textFull ?? item.preview ?? ""
            return header + "\n\n```\n\(body)\n```\n"
        case .rtf, .html:
            let body = item.textFull ?? item.preview ?? ""
            return header + "\n\n```\n\(body)\n```\n"
        case .image:
            if let sha = item.blobSha256 {
                let rel = relativeBlobPath(sha: sha)
                return header + "\n\n![\(item.preview ?? "")](\(rel))\n"
            }
            return header + "\n\n[image missing blob]\n"
        case .file:
            return header + "\n\n```\n\(item.textFull ?? item.preview ?? "")\n```\n"
        }
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func humanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: - Raw SQLite

    private func writeSQLite(items: [Item], to dir: URL, includeBlobs: Bool) throws -> ExportResult {
        let target = dir.appendingPathComponent("duo-paste-export.sqlite")
        try? FileManager.default.removeItem(at: target)

        // VACUUM INTO 必须在事务外执行，会产生一份不含 WAL/SHM 的完整副本
        _ = try database.pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [target.path])
        }

        let blobCount = includeBlobs ? try copyReferencedBlobs(items: items, to: dir) : 0
        return ExportResult(destination: target, itemCount: items.count, blobCount: blobCount)
    }

    // MARK: - Blob 复制

    private func relativeBlobPath(sha: String) -> String {
        let a = String(sha.prefix(2))
        let b = String(sha.dropFirst(2).prefix(2))
        return "blobs/\(a)/\(b)/\(sha)"
    }

    private func copyReferencedBlobs(items: [Item], to dir: URL) throws -> Int {
        let fm = FileManager.default
        let destRoot = dir.appendingPathComponent("blobs", isDirectory: true)
        var copied = 0
        var seen: Set<String> = []
        for item in items {
            guard let sha = item.blobSha256, !seen.contains(sha) else { continue }
            seen.insert(sha)
            guard let src = blobs.locate(sha256: sha) else { continue }
            let a = String(sha.prefix(2))
            let b = String(sha.dropFirst(2).prefix(2))
            let destDir = destRoot
                .appendingPathComponent(a, isDirectory: true)
                .appendingPathComponent(b, isDirectory: true)
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: src, to: dest)
            }
            copied += 1
        }
        return copied
    }
}

import Foundation
import GRDB

public enum ExportFormat: String, Sendable, CaseIterable {
    case json
    case markdown
    case sqlite

    public var filename: String {
        switch self {
        case .json: "duo-paste-export.json"
        case .markdown: "duo-paste-export.md"
        case .sqlite: "duo-paste-export.sqlite"
        }
    }
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

public struct ExportProgress: Sendable {
    public let phase: Phase
    public let current: Int
    public let total: Int

    public enum Phase: Sendable {
        case exporting
        case vacuuming
        case copyingBlobs
    }
}

public struct Exporter: Sendable {
    public let database: Database
    public let blobs: BlobStore

    public init(database: Database, blobs: BlobStore) {
        self.database = database
        self.blobs = blobs
    }

    public func export(
        to dir: URL,
        options: ExportOptions,
        progress: (@Sendable (ExportProgress) -> Void)? = nil
    ) throws -> ExportResult {
        let fm = FileManager.default
        let dirExisted = fm.fileExists(atPath: dir.path)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            switch options.format {
            case .json, .markdown:
                try Task.checkCancellation()
                let api = SearchAPI(database: database)
                let items = try api.searchHits(options.query).map(\.0)
                try Task.checkCancellation()
                if options.format == .json {
                    return try writeJSON(items: items, to: dir, includeBlobs: options.includeBlobs, progress: progress)
                } else {
                    return try writeMarkdown(items: items, to: dir, includeBlobs: options.includeBlobs, progress: progress)
                }
            case .sqlite:
                return try writeSQLite(to: dir, includeBlobs: options.includeBlobs, progress: progress)
            }
        } catch {
            if !dirExisted {
                try? fm.removeItem(at: dir)
            } else {
                try? fm.removeItem(at: dir.appendingPathComponent(options.format.filename))
                try? fm.removeItem(at: dir.appendingPathComponent("blobs"))
            }
            throw error
        }
    }

    // MARK: - Buffered write

    private static let writeBufferSize = 256 * 1024

    private func makeBufferedWriter(to file: URL) throws -> (
        append: (Data) throws -> Void, flush: () throws -> Void, close: () -> Void
    ) {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        var buf = Data()
        buf.reserveCapacity(Self.writeBufferSize)
        let append: (Data) throws -> Void = { data in
            buf.append(data)
            if buf.count >= Self.writeBufferSize {
                try handle.write(contentsOf: buf)
                buf.removeAll(keepingCapacity: true)
            }
        }
        let flush: () throws -> Void = {
            if !buf.isEmpty { try handle.write(contentsOf: buf) }
            try handle.close()
        }
        let close: () -> Void = { try? handle.close() }
        return (append, flush, close)
    }

    // MARK: - JSON (streaming)

    private func writeJSON(
        items: [Item], to dir: URL, includeBlobs: Bool,
        progress: (@Sendable (ExportProgress) -> Void)?
    ) throws -> ExportResult {
        let file = dir.appendingPathComponent(ExportFormat.json.filename)
        let (append, flush, close) = try makeBufferedWriter(to: file)
        defer { close() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        try append(Data(
            "{\n  \"schema_version\": 1,\n  \"exported_at_ns\": \(Clock.nowNs()),\n  \"item_count\": \(items.count),\n  \"items\": [\n".utf8
        ))

        let total = items.count
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            var line = Data()
            line.reserveCapacity(512)
            line.append(contentsOf: "    ".utf8)
            line.append(try encoder.encode(item))
            if i < total - 1 { line.append(contentsOf: ",".utf8) }
            line.append(contentsOf: "\n".utf8)
            try append(line)
            if (i + 1) % 100 == 0 {
                progress?(ExportProgress(phase: .exporting, current: i + 1, total: total))
            }
        }
        progress?(ExportProgress(phase: .exporting, current: total, total: total))

        try append(Data("  ]\n}\n".utf8))
        try flush()

        let blobCount = includeBlobs ? try copyReferencedBlobs(items: items, to: dir, progress: progress) : 0
        return ExportResult(destination: file, itemCount: items.count, blobCount: blobCount)
    }

    // MARK: - Markdown (streaming)

    private func writeMarkdown(
        items: [Item], to dir: URL, includeBlobs: Bool,
        progress: (@Sendable (ExportProgress) -> Void)?
    ) throws -> ExportResult {
        let file = dir.appendingPathComponent(ExportFormat.markdown.filename)
        let (append, flush, close) = try makeBufferedWriter(to: file)
        defer { close() }

        try append(Data(
            "# duo-paste 导出\n\n导出时间：\(humanDate(Date())) · 共 \(items.count) 条\n\n".utf8
        ))

        // Re-sort by time DESC for day-grouped output; intentionally drops searchHits' pinned/prefix ordering
        let sorted = items.sorted { $0.capturedAtNs > $1.capturedAtNs }
        var currentDay = ""
        let total = sorted.count

        for (i, item) in sorted.enumerated() {
            try Task.checkCancellation()
            let day = dayKey(Date(timeIntervalSince1970: TimeInterval(item.capturedAtNs) / 1_000_000_000))
            if day != currentDay {
                try append(Data("## \(day)\n\n".utf8))
                currentDay = day
            }
            try append(Data((render(item) + "\n").utf8))
            if (i + 1) % 100 == 0 {
                progress?(ExportProgress(phase: .exporting, current: i + 1, total: total))
            }
        }
        progress?(ExportProgress(phase: .exporting, current: total, total: total))
        try flush()

        let blobCount = includeBlobs ? try copyReferencedBlobs(items: items, to: dir, progress: progress) : 0
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
            if let sha = item.blobSha256, blobs.locate(sha256: sha) != nil {
                let rel = relativeBlobPath(sha: sha)
                return header + "\n\n![\(item.preview ?? "")](\(rel))\n"
            }
            return header + "\n\n[image missing blob]\n"
        case .file:
            return header + "\n\n```\n\(item.textFull ?? item.preview ?? "")\n```\n"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private static let humanFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    private func dayKey(_ date: Date) -> String { Self.dayFormatter.string(from: date) }
    private func humanDate(_ date: Date) -> String { Self.humanFormatter.string(from: date) }

    // MARK: - Raw SQLite

    private func writeSQLite(
        to dir: URL, includeBlobs: Bool,
        progress: (@Sendable (ExportProgress) -> Void)?
    ) throws -> ExportResult {
        try Task.checkCancellation()
        let target = dir.appendingPathComponent(ExportFormat.sqlite.filename)
        try? FileManager.default.removeItem(at: target)

        progress?(ExportProgress(phase: .vacuuming, current: 0, total: 0))

        // VACUUM INTO is atomic and not interruptible — cancel only takes effect after it completes.
        // rawCount = all physical rows (including tombstones), NOT fold-aware, NOT query-filtered.
        // Matches what the user sees running SELECT COUNT(*) on the exported sqlite.
        let (rawCount, allBlobShas) = try database.pool.writeWithoutTransaction { db -> (Int, [String]) in
            try db.execute(sql: "VACUUM INTO ?", arguments: [target.path])
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0
            let shas = try String.fetchAll(db, sql:
                "SELECT DISTINCT blob_sha256 FROM item WHERE blob_sha256 IS NOT NULL")
            return (count, shas)
        }

        try Task.checkCancellation()

        let blobCount = includeBlobs ? try copyReferencedBlobsBySha(shas: allBlobShas, to: dir, progress: progress) : 0
        return ExportResult(destination: target, itemCount: rawCount, blobCount: blobCount)
    }

    // MARK: - Blob 复制

    private func relativeBlobPath(sha: String) -> String {
        let a = String(sha.prefix(2))
        let b = String(sha.dropFirst(2).prefix(2))
        let filename = blobs.locate(sha256: sha)?.lastPathComponent ?? sha
        return "blobs/\(a)/\(b)/\(filename)"
    }

    private func copyReferencedBlobs(
        items: [Item], to dir: URL,
        progress: (@Sendable (ExportProgress) -> Void)?
    ) throws -> Int {
        let shas = Array(Set(items.compactMap(\.blobSha256)))
        return try copyReferencedBlobsBySha(shas: shas, to: dir, progress: progress)
    }

    private func copyReferencedBlobsBySha(
        shas: [String], to dir: URL,
        progress: (@Sendable (ExportProgress) -> Void)?
    ) throws -> Int {
        let fm = FileManager.default
        let destRoot = dir.appendingPathComponent("blobs", isDirectory: true)
        var copied = 0
        let total = shas.count

        for (i, sha) in shas.enumerated() {
            try Task.checkCancellation()
            if (i + 1) % 50 == 0 {
                progress?(ExportProgress(phase: .copyingBlobs, current: i + 1, total: total))
            }
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
        if total > 0 {
            progress?(ExportProgress(phase: .copyingBlobs, current: total, total: total))
        }
        return copied
    }
}

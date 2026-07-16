import Foundation
import GRDB

/// 安全诊断导出。与 Exporter（历史正文/blob 导出）刻意完全分离：公开 API 不接收
/// SharedSecret、私钥 Data 或 BlobStore，输出文件名也是固定白名单。
public enum DiagnosticBundleExporter {
    public struct VersionInfo: Codable, Equatable, Sendable {
        public let appVersion: String
        public let buildVersion: String
        public let osVersion: String
        public let architecture: String

        public init(
            appVersion: String,
            buildVersion: String,
            osVersion: String,
            architecture: String
        ) {
            self.appVersion = appVersion
            self.buildVersion = buildVersion
            self.osVersion = osVersion
            self.architecture = architecture
        }
    }

    public struct Result: Equatable, Sendable {
        public let directory: URL
        public let relativeFiles: [String]
    }

    public enum ExportError: Error, CustomStringConvertible, Sendable {
        case destinationExists(URL)

        public var description: String {
            switch self {
            case .destinationExists(let url):
                "诊断包目标已存在：\(url.path)"
            }
        }
    }

    private struct QuickCheck: Codable {
        let result: String
        let rows: [String]
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let generatedAt: Date
        let relativeFiles: [String]
        let deliberatelyExcluded: [String]
        let logPolicy: String
    }

    private static let safeLogPrefixes = [
        "duo-paste UI ready",
        "snapshot ",
        "snapshot ok",
        "sync server ",
        "[HummingbirdCore] Server started",
        "pull:",
        "mesh:",
        "mesh-endpoints-cache:",
        "ocr:",
        "blob-evict:",
        "fetch-missing:",
        "accessibility ",
        "hotkey ",
        "capture skipped (too large):",
        "capture exclusions reloaded:",
        "startup-migration ",
    ]

    private static let maxLogBytes = 256 * 1024

    @discardableResult
    public static func export(
        to directory: URL,
        config: Config,
        meshDoctorReport: Admin.MeshDoctorReport,
        databasePath: URL,
        logFiles: [URL],
        version: VersionInfo,
        now: Date = Date()
    ) throws -> Result {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else {
            throw ExportError.destinationExists(directory)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try secureDirectory(directory, fileManager: fm)

        do {
            var files: [String] = []

            try writeJSON(redacted(config), to: directory.appendingPathComponent("config.redacted.json"))
            files.append("config.redacted.json")

            try Admin.encodeMeshDoctorJSON(redacted(meshDoctorReport))
                .write(to: directory.appendingPathComponent("mesh-doctor.json"), options: .atomic)
            files.append("mesh-doctor.json")

            let rows = try quickCheck(databasePath: databasePath)
            let quick = QuickCheck(
                result: rows.count == 1 && rows[0].lowercased() == "ok" ? "ok" : "failed",
                rows: rows
            )
            try writeJSON(quick, to: directory.appendingPathComponent("quick-check.json"))
            files.append("quick-check.json")

            try writeJSON(version, to: directory.appendingPathComponent("version.json"))
            files.append("version.json")

            if !logFiles.isEmpty {
                let logsDirectory = directory.appendingPathComponent("logs", isDirectory: true)
                try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
                try secureDirectory(logsDirectory, fileManager: fm)
                var usedNames = Set<String>()
                for source in logFiles where fm.fileExists(atPath: source.path) {
                    let base = safeFilename(source.lastPathComponent, used: &usedNames)
                    let relative = "logs/\(base)"
                    let raw = try recentData(from: source, limit: maxLogBytes)
                    let sanitized = sanitizeLog(raw)
                    try sanitized.write(
                        to: logsDirectory.appendingPathComponent(base),
                        options: .atomic
                    )
                    files.append(relative)
                }
            }

            files.sort()
            let manifestRelative = "manifest.json"
            let manifestFiles = (files + [manifestRelative]).sorted()
            let manifest = Manifest(
                schemaVersion: 1,
                generatedAt: now,
                relativeFiles: manifestFiles,
                deliberatelyExcluded: [
                    "shared-secret, device credentials/tokens, and authentication headers",
                    "TLS private keys and tls_key_path",
                    "SQLite database copies and item text/preview",
                    "blob and thumbnail bytes",
                    "content-bearing or unknown log lines",
                ],
                logPolicy: "Only allowlisted operational prefixes are retained; every other line is replaced."
            )
            try writeJSON(manifest, to: directory.appendingPathComponent(manifestRelative))
            for relative in manifestFiles {
                try secureFile(directory.appendingPathComponent(relative), fileManager: fm)
            }
            return Result(directory: directory, relativeFiles: manifestFiles)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    public static func sanitizeLog(_ data: Data) -> Data {
        let input = String(decoding: data, as: UTF8.self)
        var output = ["# duo-paste sanitized operational log"]
        var previousWasRedacted = false
        for rawLine in input.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            let allowed = safeLogPrefixes.contains { line.hasPrefix($0) }
            if allowed {
                output.append(redactCredentialLikeTokens(line))
                previousWasRedacted = false
            } else if !previousWasRedacted {
                output.append("[redacted non-operational log line]")
                previousWasRedacted = true
            }
        }
        return Data((output.joined(separator: "\n") + "\n").utf8)
    }

    private static func quickCheck(databasePath: URL) throws -> [String] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databasePath.path, configuration: configuration)
        return try queue.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check")
        }
    }

    private static func redacted(_ source: Config) -> Config {
        var config = source
        if config.tlsKeyPath != nil {
            config.tlsKeyPath = "<redacted-private-key-path>"
        }
        if let cert = config.tlsCertPath {
            config.tlsCertPath = (cert as NSString).lastPathComponent
        }
        config.peers = config.peers.map { peer in
            Config.PeerConfig(
                url: removingCredentials(from: peer.url),
                deviceID: peer.deviceID,
                pullURL: peer.pullURL.map(removingCredentials)
            )
        }
        return config
    }

    private static func redacted(_ source: Admin.MeshDoctorReport) -> Admin.MeshDoctorReport {
        let peers = source.peers.map { peer in
            let health: Admin.PeerDoctorReport.HealthOutcome
            switch peer.health {
            case .ok:
                health = peer.health
            case .unreachable(let reason):
                health = .unreachable(reason: redactCredentialLikeTokens(reason))
            case .rejected(let reason):
                health = .rejected(reason: redactCredentialLikeTokens(reason))
            }
            return Admin.PeerDoctorReport(
                url: removingCredentials(from: peer.url),
                expectedDeviceID: peer.expectedDeviceID,
                health: health,
                deviceIDMatches: peer.deviceIDMatches,
                pullCursor: peer.pullCursor,
                currentTransport: peer.currentTransport.map(redactCredentialLikeTokens)
            )
        }
        return Admin.MeshDoctorReport(
            selfDeviceID: source.selfDeviceID,
            tlsCertificate: source.tlsCertificate,
            peers: peers,
            selfMaxIngestedNs: source.selfMaxIngestedNs,
            missingBlobsTotal: source.missingBlobsTotal,
            missingBlobsSamples: source.missingBlobsSamples
        )
    }

    private static func removingCredentials(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URL(string: "https://redacted.invalid")!
        }
        components.user = nil
        components.password = nil
        return components.url ?? URL(string: "https://redacted.invalid")!
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func secureDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private static func secureFile(_ url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private static func recentData(from url: URL, limit: Int) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > limit else { return data }
        return Data(data.suffix(limit))
    }

    private static func safeFilename(_ raw: String, used: inout Set<String>) -> String {
        let cleaned = raw.map { character -> Character in
            character.isLetter || character.isNumber || ".-_".contains(character) ? character : "_"
        }
        var candidate = cleaned.isEmpty ? "daemon.log" : String(cleaned)
        var suffix = 2
        while !used.insert(candidate).inserted {
            candidate = "\(String(cleaned)).\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func redactCredentialLikeTokens(_ line: String) -> String {
        var output = line
        let replacements = [
            (#"(?i)(authorization|x-dp-auth|x-dp-signature|x-dp-credential|shared[-_ ]secret|device[-_ ]credential)\s*[:=]\s*\S+"#, "<redacted-credential>"),
            (#"\bdpc1\.[A-Za-z0-9_-]+\b"#, "<redacted-credential>"),
            (#"\b[0-9a-fA-F]{64}\b"#, "<redacted-credential>"),
            (#"(https?://)[^\s/@:]+:[^\s/@]+@"#, "$1<redacted-credentials>@"),
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: replacement
            )
        }
        return output
    }
}

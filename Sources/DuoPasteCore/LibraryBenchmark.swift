import CryptoKit
import Darwin
import Foundation
import GRDB

/// R4.1 manual/nightly large-library benchmark support.
///
/// This code is linked into the CLI so it can exercise the exact production `Database` and
/// `SearchAPI`, but nothing runs unless `duo-pasted benchmark-library` is explicitly invoked.
public enum LibraryBenchmark {
    public static let selectiveSearchToken = "benchmarkneedle"
    public static let alternateSelectiveSearchToken = "benchmarkneedlealt"
    public static let commonSearchToken = "corpuscommon"
    public static let markerFilename = ".duo-paste-benchmark.json"
    public static let manifestFilename = "dataset-manifest.json"
    public static let schemaVersion = 1

    public enum ExecutionPolicy: String, Codable, Sendable {
        case explicitManualOrNightlyOnly
    }

    public static let executionPolicy: ExecutionPolicy = .explicitManualOrNightlyOnly

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        case emptySamples
        case invalidConfiguration(String)
        case unsafeWorkspace(String)
        case unmarkedWorkspace(String)
        case incompatibleDataset(String)
        case integrityCheck(String)

        public var description: String {
            switch self {
            case .emptySamples:
                return "benchmark samples must not be empty"
            case .invalidConfiguration(let message):
                return "invalid benchmark configuration: \(message)"
            case .unsafeWorkspace(let path):
                return "refusing benchmark workspace near production data: \(path)"
            case .unmarkedWorkspace(let path):
                return "refusing to rebuild unmarked workspace: \(path)"
            case .incompatibleDataset(let message):
                return "benchmark dataset does not match: \(message)"
            case .integrityCheck(let result):
                return "benchmark database integrity_check failed: \(result)"
            }
        }
    }

    public struct Configuration: Codable, Sendable, Equatable {
        public var rowCount: Int
        public var logicalBlobBytes: Int64
        public var blobFileCount: Int
        public var seed: UInt64

        public init(rowCount: Int, logicalBlobBytes: Int64, blobFileCount: Int, seed: UInt64) {
            self.rowCount = rowCount
            self.logicalBlobBytes = logicalBlobBytes
            self.blobFileCount = blobFileCount
            self.seed = seed
        }

        public static let `default` = Configuration(
            rowCount: 1_000_000,
            logicalBlobBytes: 8 * 1_024 * 1_024 * 1_024,
            blobFileCount: 256,
            seed: 4_241
        )

        fileprivate func validate() throws {
            guard rowCount > 0 else { throw Error.invalidConfiguration("rowCount must be > 0") }
            guard logicalBlobBytes >= 0 else {
                throw Error.invalidConfiguration("logicalBlobBytes must be >= 0")
            }
            guard blobFileCount > 0 else {
                throw Error.invalidConfiguration("blobFileCount must be > 0")
            }
            guard logicalBlobBytes >= Int64(blobFileCount) else {
                throw Error.invalidConfiguration("logicalBlobBytes must be >= blobFileCount")
            }
            guard rowCount <= Int(Int32.max) else {
                throw Error.invalidConfiguration("rowCount is too large")
            }
        }
    }

    public struct DatasetManifest: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let configuration: Configuration
        public let fingerprint: String
        public let rowCount: Int
        public let kindCounts: [String: Int]
        public let ocrStateCounts: [String: Int]
        public let pinnedCount: Int
        public let deletedCount: Int
        public let foldSiblingCount: Int
        public let selectiveTokenCount: Int
        public let databaseBytes: Int64
        public let blobLogicalBytes: Int64
        public let blobAllocatedBytes: Int64
        public let blobFileCount: Int
        public let sampleBlobSHA256s: [String]
        public let blobMode: String
        public let integrityCheck: String

        public init(
            schemaVersion: Int,
            configuration: Configuration,
            fingerprint: String,
            rowCount: Int,
            kindCounts: [String: Int],
            ocrStateCounts: [String: Int],
            pinnedCount: Int,
            deletedCount: Int,
            foldSiblingCount: Int,
            selectiveTokenCount: Int,
            databaseBytes: Int64,
            blobLogicalBytes: Int64,
            blobAllocatedBytes: Int64,
            blobFileCount: Int,
            sampleBlobSHA256s: [String],
            blobMode: String,
            integrityCheck: String
        ) {
            self.schemaVersion = schemaVersion
            self.configuration = configuration
            self.fingerprint = fingerprint
            self.rowCount = rowCount
            self.kindCounts = kindCounts
            self.ocrStateCounts = ocrStateCounts
            self.pinnedCount = pinnedCount
            self.deletedCount = deletedCount
            self.foldSiblingCount = foldSiblingCount
            self.selectiveTokenCount = selectiveTokenCount
            self.databaseBytes = databaseBytes
            self.blobLogicalBytes = blobLogicalBytes
            self.blobAllocatedBytes = blobAllocatedBytes
            self.blobFileCount = blobFileCount
            self.sampleBlobSHA256s = sampleBlobSHA256s
            self.blobMode = blobMode
            self.integrityCheck = integrityCheck
        }

        /// `--reuse` 打开旧 benchmark DB 时 migration 可能增加派生索引；workspace manifest
        /// 仍描述固定生成数据，最终 report 则必须记录测量当下的真实 DB 大小，不能沿用旧值。
        public func replacingDatabaseBytes(_ bytes: Int64) -> DatasetManifest {
            DatasetManifest(
                schemaVersion: schemaVersion,
                configuration: configuration,
                fingerprint: fingerprint,
                rowCount: rowCount,
                kindCounts: kindCounts,
                ocrStateCounts: ocrStateCounts,
                pinnedCount: pinnedCount,
                deletedCount: deletedCount,
                foldSiblingCount: foldSiblingCount,
                selectiveTokenCount: selectiveTokenCount,
                databaseBytes: bytes,
                blobLogicalBytes: blobLogicalBytes,
                blobAllocatedBytes: blobAllocatedBytes,
                blobFileCount: blobFileCount,
                sampleBlobSHA256s: sampleBlobSHA256s,
                blobMode: blobMode,
                integrityCheck: integrityCheck
            )
        }

        /// Small in-memory value used by report serialization tests. It never creates a dataset.
        public static func fixture(configuration: Configuration) -> DatasetManifest {
            DatasetManifest(
                schemaVersion: LibraryBenchmark.schemaVersion,
                configuration: configuration,
                fingerprint: LibraryBenchmark.fingerprint(for: configuration),
                rowCount: configuration.rowCount,
                kindCounts: Dictionary(uniqueKeysWithValues: ItemKind.allCases.map { ($0.rawValue, 1) }),
                ocrStateCounts: [OCRState.done.rawValue: 1, OCRState.pending.rawValue: 1],
                pinnedCount: 1,
                deletedCount: 1,
                foldSiblingCount: 2,
                selectiveTokenCount: 1,
                databaseBytes: 1,
                blobLogicalBytes: configuration.logicalBlobBytes,
                blobAllocatedBytes: 1,
                blobFileCount: configuration.blobFileCount,
                sampleBlobSHA256s: [LibraryBenchmark.fakeSHA(seed: configuration.seed, index: 0)],
                blobMode: "sparse_placeholder",
                integrityCheck: "ok"
            )
        }
    }

    public struct Summary: Codable, Sendable, Equatable {
        public let count: Int
        public let p50Ms: Double
        public let p95Ms: Double
        public let maxMs: Double
    }

    public enum MetricName: String, Codable, Sendable, CaseIterable {
        case coldFTS = "cold_fts"
        case warmFTS = "warm_fts"
        case emptyQuery = "empty_query"
        case qualifier
        case countByKind = "count_by_kind"
        case deepPagination = "deep_pagination"
        case firstScreenData = "first_screen_data"
        case firstScreenRender = "first_screen_render"
    }

    public struct MetricResult: Codable, Sendable, Equatable {
        public let name: MetricName
        public let samplesMs: [Double]
        public let summary: Summary
        public let peakFootprintBytes: UInt64

        public init(
            name: MetricName,
            samplesMs: [Double],
            summary: Summary,
            peakFootprintBytes: UInt64
        ) {
            self.name = name
            self.samplesMs = samplesMs
            self.summary = summary
            self.peakFootprintBytes = peakFootprintBytes
        }
    }

    public struct Gate: Codable, Sendable, Equatable {
        public let metric: MetricName
        public let thresholdMs: Double
        public let actualP95Ms: Double
        public let passed: Bool

        public init(metric: MetricName, thresholdMs: Double, actualP95Ms: Double) {
            self.metric = metric
            self.thresholdMs = thresholdMs
            self.actualP95Ms = actualP95Ms
            self.passed = actualP95Ms < thresholdMs
        }
    }

    public struct Environment: Codable, Sendable, Equatable {
        public let generatedAt: String
        public let osVersion: String
        public let architecture: String
        public let hardwareModel: String
        public let physicalMemoryBytes: UInt64
        public let swiftVersion: String
        public let buildConfiguration: String
        public let coldCachePolicy: String

        public init(
            generatedAt: String,
            osVersion: String,
            architecture: String,
            hardwareModel: String,
            physicalMemoryBytes: UInt64,
            swiftVersion: String,
            buildConfiguration: String,
            coldCachePolicy: String
        ) {
            self.generatedAt = generatedAt
            self.osVersion = osVersion
            self.architecture = architecture
            self.hardwareModel = hardwareModel
            self.physicalMemoryBytes = physicalMemoryBytes
            self.swiftVersion = swiftVersion
            self.buildConfiguration = buildConfiguration
            self.coldCachePolicy = coldCachePolicy
        }
    }

    public struct Report: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let environment: Environment
        public let dataset: DatasetManifest
        public let metrics: [MetricResult]
        public let gates: [Gate]

        public init(environment: Environment, dataset: DatasetManifest, metrics: [MetricResult], gates: [Gate]) {
            self.schemaVersion = LibraryBenchmark.schemaVersion
            self.environment = environment
            self.dataset = dataset
            self.metrics = metrics
            self.gates = gates
        }
    }

    private struct Marker: Codable {
        let magic: String
        let schemaVersion: Int
    }

    public static func summarize(milliseconds: [Double]) throws -> Summary {
        guard !milliseconds.isEmpty else { throw Error.emptySamples }
        let sorted = milliseconds.sorted()
        func nearestRank(_ percentile: Double) -> Double {
            let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
            return sorted[min(sorted.count - 1, rank - 1)]
        }
        return Summary(
            count: sorted.count,
            p50Ms: nearestRank(0.50),
            p95Ms: nearestRank(0.95),
            maxMs: sorted[sorted.count - 1]
        )
    }

    public static func encodeReport(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    /// Measures all production search stages that do not require the macOS view hierarchy.
    /// The caller appends `first_screen_render`, which lives in the executable target so it can
    /// instantiate the real internal `AppState` and `SearchView` types.
    public static func runCoreMetrics(
        databaseURL: URL,
        samples: Int,
        warmups: Int = 2,
        progress: @Sendable (String) -> Void = { _ in }
    ) throws -> [MetricResult] {
        guard samples > 0 else { throw Error.invalidConfiguration("samples must be > 0") }
        guard warmups >= 0 else { throw Error.invalidConfiguration("warmups must be >= 0") }

        let database = try Database(path: databaseURL)
        let api = SearchAPI(database: database)
        let selective = SearchQuery(text: selectiveSearchToken, limit: 200)
        var metrics: [MetricResult] = []

        func append(_ name: MetricName, _ operation: @escaping () throws -> Void) throws {
            progress("measuring \(name.rawValue)")
            metrics.append(try measureMetric(
                name: name,
                samples: samples,
                warmups: warmups,
                operation: operation
            ))
        }

        try append(.coldFTS) {
            let coldDatabase = try Database(path: databaseURL)
            _ = try SearchAPI(database: coldDatabase).searchHits(selective)
        }
        try append(.warmFTS) {
            _ = try api.searchHits(selective)
        }
        try append(.emptyQuery) {
            _ = try api.searchHits(SearchQuery(limit: 200))
        }
        try append(.qualifier) {
            _ = try api.searchHits(SearchQuery(kinds: [.image], limit: 200))
        }
        try append(.countByKind) {
            _ = try api.searchSummary(SearchQuery())
        }
        try append(.deepPagination) {
            _ = try api.searchHits(SearchQuery(limit: 200, offset: 100_000))
        }
        try append(.firstScreenData) {
            _ = try makeFirstScreenData(api: api, query: selective)
        }
        return metrics
    }

    /// SearchProvider's exact single-summary local data path, exposed for the real UI render probe.
    public static func makeFirstScreenData(api: SearchAPI, query: SearchQuery) throws -> FirstScreenData {
        let summary = try api.searchSummary(query)
        return FirstScreenData(
            items: summary.hits.map(\.0),
            snippets: Dictionary(uniqueKeysWithValues: summary.hits.compactMap { item, snippet in
                snippet.map { (item.id, $0) }
            }),
            totalCount: summary.totalCount,
            kindCounts: summary.kindCounts,
            fileSubKindCounts: summary.fileSubKindCounts
        )
    }

    public struct FirstScreenData: Sendable {
        public let items: [Item]
        public let snippets: [String: String]
        public let totalCount: Int
        public let kindCounts: [ItemKind: Int]
        public let fileSubKindCounts: [FileSubKind: Int]

        public init(
            items: [Item],
            snippets: [String: String],
            totalCount: Int,
            kindCounts: [ItemKind: Int],
            fileSubKindCounts: [FileSubKind: Int]
        ) {
            self.items = items
            self.snippets = snippets
            self.totalCount = totalCount
            self.kindCounts = kindCounts
            self.fileSubKindCounts = fileSubKindCounts
        }
    }

    public static func measureMetric(
        name: MetricName,
        samples: Int,
        warmups: Int,
        operation: () throws -> Void
    ) throws -> MetricResult {
        guard samples > 0 else { throw Error.invalidConfiguration("samples must be > 0") }
        guard warmups >= 0 else { throw Error.invalidConfiguration("warmups must be >= 0") }
        for _ in 0..<warmups { try autoreleasepool { try operation() } }

        let memory = ProcessPeakFootprintSampler()
        memory.start()
        var timings: [Double] = []
        timings.reserveCapacity(samples)
        do {
            for _ in 0..<samples {
                let start = DispatchTime.now().uptimeNanoseconds
                try autoreleasepool { try operation() }
                let end = DispatchTime.now().uptimeNanoseconds
                timings.append(Double(end - start) / 1_000_000)
                memory.sampleNow()
            }
        } catch {
            _ = memory.stop()
            throw error
        }
        let peak = memory.stop()
        return MetricResult(
            name: name,
            samplesMs: timings,
            summary: try summarize(milliseconds: timings),
            peakFootprintBytes: peak
        )
    }

    /// Pure safety check. This never creates or removes files.
    @discardableResult
    public static func validateWorkspace(_ rawURL: URL, rebuilding: Bool) throws -> URL {
        let workspace = rawURL.standardizedFileURL.resolvingSymlinksInPath()
        let production = Paths.defaultRoot().standardizedFileURL.resolvingSymlinksInPath()
        func contains(_ ancestor: URL, _ candidate: URL) -> Bool {
            let base = ancestor.path.hasSuffix("/") ? ancestor.path : ancestor.path + "/"
            return candidate.path == ancestor.path || candidate.path.hasPrefix(base)
        }
        guard !contains(workspace, production), !contains(production, workspace) else {
            throw Error.unsafeWorkspace(workspace.path)
        }
        guard !workspace.path.isEmpty, workspace.path != "/" else {
            throw Error.unsafeWorkspace(workspace.path)
        }
        if rebuilding, FileManager.default.fileExists(atPath: workspace.path) {
            let markerURL = workspace.appendingPathComponent(markerFilename)
            guard let data = try? Data(contentsOf: markerURL),
                  let marker = try? JSONDecoder().decode(Marker.self, from: data),
                  marker.magic == "duo-paste-library-benchmark",
                  marker.schemaVersion == schemaVersion else {
                throw Error.unmarkedWorkspace(workspace.path)
            }
        }
        return workspace
    }

    /// Creates or reuses an isolated deterministic dataset.
    public static func prepareWorkspace(
        at rawURL: URL,
        configuration: Configuration,
        rebuild: Bool,
        materializeBlobs: Bool,
        progress: @Sendable (String) -> Void = { _ in }
    ) throws -> DatasetManifest {
        try configuration.validate()
        let workspace = try validateWorkspace(rawURL, rebuilding: rebuild)
        let fm = FileManager.default
        let markerURL = workspace.appendingPathComponent(markerFilename)
        let manifestURL = workspace.appendingPathComponent(manifestFilename)

        if rebuild, fm.fileExists(atPath: workspace.path) {
            try fm.removeItem(at: workspace)
        } else if fm.fileExists(atPath: markerURL.path) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(DatasetManifest.self, from: data) else {
                throw Error.incompatibleDataset("marked workspace has no readable manifest; rerun with --rebuild")
            }
            guard manifest.schemaVersion == schemaVersion,
                  manifest.configuration == configuration,
                  manifest.blobMode == (materializeBlobs ? "materialized_placeholder" : "sparse_placeholder") else {
                throw Error.incompatibleDataset("configuration or blob mode differs; rerun with --rebuild")
            }
            return manifest
        } else if fm.fileExists(atPath: workspace.path) {
            let entries = try fm.contentsOfDirectory(atPath: workspace.path)
            guard entries.isEmpty else { throw Error.unmarkedWorkspace(workspace.path) }
        }

        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let marker = Marker(magic: "duo-paste-library-benchmark", schemaVersion: schemaVersion)
        let markerEncoder = JSONEncoder()
        markerEncoder.outputFormatting = [.sortedKeys]
        try markerEncoder.encode(marker).write(to: markerURL, options: .atomic)

        let paths = Paths(root: workspace)
        paths.ensureExists()
        progress("creating deterministic metadata")
        let database = try Database(path: paths.mainDB)
        try populate(database: database, configuration: configuration)

        progress(materializeBlobs ? "materializing blob placeholders" : "creating sparse blob placeholders")
        let blobAccounting = try createBlobPlaceholders(
            root: paths.blobsDir,
            configuration: configuration,
            materialize: materializeBlobs
        )

        let stats = try collectDatasetStats(database: database)
        let databaseBytes = fileLogicalSize(paths.mainDB)
        let manifest = DatasetManifest(
            schemaVersion: schemaVersion,
            configuration: configuration,
            fingerprint: fingerprint(for: configuration),
            rowCount: stats.rowCount,
            kindCounts: stats.kindCounts,
            ocrStateCounts: stats.ocrStateCounts,
            pinnedCount: stats.pinnedCount,
            deletedCount: stats.deletedCount,
            foldSiblingCount: stats.foldSiblingCount,
            selectiveTokenCount: stats.selectiveTokenCount,
            databaseBytes: databaseBytes,
            blobLogicalBytes: blobAccounting.logical,
            blobAllocatedBytes: blobAccounting.allocated,
            blobFileCount: configuration.blobFileCount,
            sampleBlobSHA256s: (0..<min(8, configuration.blobFileCount)).map {
                fakeSHA(seed: configuration.seed, index: $0)
            },
            blobMode: materializeBlobs ? "materialized_placeholder" : "sparse_placeholder",
            integrityCheck: stats.integrityCheck
        )
        guard manifest.integrityCheck == "ok" else {
            throw Error.integrityCheck(manifest.integrityCheck)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        return manifest
    }

    private static func populate(database: Database, configuration: Configuration) throws {
        let seedBase = Int64(bitPattern: configuration.seed & 0x3fff_ffff)
        let blobBytes = configuration.logicalBlobBytes / Int64(configuration.blobFileCount)
        try database.pool.write { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS item_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS item_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS item_au")
            try db.execute(sql: "DELETE FROM item")
            try db.execute(sql: "INSERT INTO item_fts(item_fts) VALUES('delete-all')")
            try db.execute(
                sql: """
                    WITH RECURSIVE counter(i) AS (
                        SELECT 0
                        UNION ALL
                        SELECT i + 1 FROM counter WHERE i + 1 < ?
                    ), synthetic AS (
                        SELECT
                            i,
                            CASE
                                WHEN (i % 40) IN (38, 39) THEN 'text'
                                WHEN (i % 20) <= 9 THEN 'text'
                                WHEN (i % 20) IN (10, 11) THEN 'url'
                                WHEN (i % 20) = 12 THEN 'rtf'
                                WHEN (i % 20) = 13 THEN 'html'
                                WHEN (i % 20) IN (14, 15) THEN 'image'
                                ELSE 'file'
                            END AS synthetic_kind
                        FROM counter
                    )
                    INSERT INTO item (
                        id, origin_device, captured_at_ns, ingested_at_ns, kind,
                        source_app, source_app_name, preview, text_full,
                        blob_sha256, blob_size, blob_mime, pinned, deleted_at_ns,
                        ocr_state, extracted_text, extracted_text_source
                    )
                    SELECT
                        printf('bench-%08d', i),
                        CASE
                            WHEN (i % 40) = 39 THEN 'peer-b'
                            WHEN (i % 3) = 0 THEN 'local-a'
                            WHEN (i % 3) = 1 THEN 'peer-b'
                            ELSE 'peer-c'
                        END,
                        1700000000000000000 + i * 1000000,
                        1700000000000000000 + i * 1000000,
                        synthetic_kind,
                        CASE (i % 4)
                            WHEN 0 THEN 'com.apple.Terminal'
                            WHEN 1 THEN 'com.apple.Safari'
                            WHEN 2 THEN 'com.todesktop.230313mzl4w4u92'
                            ELSE 'com.apple.finder'
                        END,
                        CASE (i % 4)
                            WHEN 0 THEN 'Terminal'
                            WHEN 1 THEN 'Safari'
                            WHEN 2 THEN 'Cursor'
                            ELSE 'Finder'
                        END,
                        CASE
                            WHEN (i % 40) IN (38, 39) THEN 'fold sibling ' || (i / 40) || ' corpuscommon'
                            WHEN synthetic_kind = 'url' THEN 'https://example.test/benchmark/' || i || ' corpuscommon'
                            WHEN synthetic_kind = 'file' THEN '/synthetic/archive/document-' || i ||
                                CASE (i % 4) WHEN 0 THEN '.pdf' WHEN 1 THEN '.mp4' WHEN 2 THEN '.png' ELSE '.zip' END
                            ELSE 'synthetic clipboard row ' || i || ' corpuscommon'
                        END || CASE WHEN synthetic_kind = 'text' AND (i % 997) = 0 THEN ' benchmarkneedle' ELSE '' END
                            || CASE WHEN synthetic_kind = 'text' AND (i % 991) = 1 THEN ' benchmarkneedlealt' ELSE '' END,
                        CASE
                            WHEN (i % 40) IN (38, 39) THEN 'fold sibling ' || (i / 40) || ' corpuscommon'
                            WHEN synthetic_kind = 'url' THEN 'https://example.test/benchmark/' || i || ' corpuscommon'
                            WHEN synthetic_kind = 'file' THEN '/synthetic/archive/document-' || i ||
                                CASE (i % 4) WHEN 0 THEN '.pdf' WHEN 1 THEN '.mp4' WHEN 2 THEN '.png' ELSE '.zip' END
                            ELSE 'synthetic clipboard row ' || i || ' corpuscommon'
                        END || CASE WHEN synthetic_kind = 'text' AND (i % 997) = 0 THEN ' benchmarkneedle' ELSE '' END
                            || CASE WHEN synthetic_kind = 'text' AND (i % 991) = 1 THEN ' benchmarkneedlealt' ELSE '' END,
                        CASE WHEN synthetic_kind IN ('image', 'file')
                            THEN printf('%064x', ? + (i % ?)) ELSE NULL END,
                        CASE WHEN synthetic_kind IN ('image', 'file') THEN ? ELSE NULL END,
                        CASE
                            WHEN synthetic_kind = 'image' THEN 'image/png'
                            WHEN synthetic_kind = 'file' THEN
                                CASE (i % 4) WHEN 0 THEN 'application/pdf' WHEN 1 THEN 'video/mp4'
                                    WHEN 2 THEN 'image/png' ELSE 'application/zip' END
                            ELSE NULL
                        END,
                        CASE WHEN (i % 97) = 0 THEN 1 ELSE 0 END,
                        CASE WHEN (i % 113) = 112 THEN 1700000000000000000 + i * 1000000 + 1 ELSE NULL END,
                        CASE WHEN synthetic_kind = 'image'
                            THEN CASE WHEN (i % 20) = 14 THEN 'done' ELSE 'pending' END
                            ELSE NULL END,
                        CASE WHEN synthetic_kind = 'image' AND (i % 20) = 14
                            THEN 'ocr receipt benchmarkocr corpuscommon row ' || i ELSE NULL END,
                        CASE WHEN synthetic_kind = 'image' AND (i % 20) = 14 THEN 'ocr' ELSE NULL END
                    FROM synthetic
                    """,
                arguments: [
                    configuration.rowCount,
                    seedBase * 1_000_000 + 1,
                    configuration.blobFileCount,
                    blobBytes,
                ]
            )
            try db.execute(sql: "INSERT INTO item_fts(item_fts) VALUES('rebuild')")
            try createCurrentFTSTriggers(db)
        }
        try database.pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    private static func createCurrentFTSTriggers(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN
                INSERT INTO item_fts(rowid, text_full, preview, source_app_name, extracted_text)
                VALUES (new.rowid, new.text_full, new.preview, new.source_app_name, new.extracted_text);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER item_ad AFTER DELETE ON item BEGIN
                INSERT INTO item_fts(item_fts, rowid, text_full, preview, source_app_name, extracted_text)
                VALUES ('delete', old.rowid, old.text_full, old.preview, old.source_app_name, old.extracted_text);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER item_au AFTER UPDATE ON item BEGIN
                INSERT INTO item_fts(item_fts, rowid, text_full, preview, source_app_name, extracted_text)
                VALUES ('delete', old.rowid, old.text_full, old.preview, old.source_app_name, old.extracted_text);
                INSERT INTO item_fts(rowid, text_full, preview, source_app_name, extracted_text)
                VALUES (new.rowid, new.text_full, new.preview, new.source_app_name, new.extracted_text);
            END;
            """)
    }

    private struct DatasetStats {
        let rowCount: Int
        let kindCounts: [String: Int]
        let ocrStateCounts: [String: Int]
        let pinnedCount: Int
        let deletedCount: Int
        let foldSiblingCount: Int
        let selectiveTokenCount: Int
        let integrityCheck: String
    }

    private static func collectDatasetStats(database: Database) throws -> DatasetStats {
        try database.pool.read { db in
            let kindRows = try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM item GROUP BY kind")
            let ocrRows = try Row.fetchAll(
                db,
                sql: "SELECT ocr_state, COUNT(*) AS n FROM item WHERE ocr_state IS NOT NULL GROUP BY ocr_state"
            )
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "missing"
            return DatasetStats(
                rowCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0,
                kindCounts: Dictionary(uniqueKeysWithValues: kindRows.map { row in
                    (row["kind"] as String, row["n"] as Int)
                }),
                ocrStateCounts: Dictionary(uniqueKeysWithValues: ocrRows.map { row in
                    (row["ocr_state"] as String, row["n"] as Int)
                }),
                pinnedCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE pinned = 1") ?? 0,
                deletedCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE deleted_at_ns IS NOT NULL") ?? 0,
                foldSiblingCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM item WHERE text_full LIKE 'fold sibling %'"
                ) ?? 0,
                selectiveTokenCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM item_fts WHERE item_fts MATCH ?",
                    arguments: [selectiveSearchToken]
                ) ?? 0,
                integrityCheck: integrity
            )
        }
    }

    private static func createBlobPlaceholders(
        root: URL,
        configuration: Configuration,
        materialize: Bool
    ) throws -> (logical: Int64, allocated: Int64) {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BlobStore(root: root)
        let baseSize = configuration.logicalBlobBytes / Int64(configuration.blobFileCount)
        let remainder = configuration.logicalBlobBytes % Int64(configuration.blobFileCount)
        let materializedChunk = Data(repeating: 0xA5, count: 1_048_576)
        var logical: Int64 = 0
        var allocated: Int64 = 0

        for index in 0..<configuration.blobFileCount {
            let size = baseSize + (Int64(index) < remainder ? 1 : 0)
            let sha = fakeSHA(seed: configuration.seed, index: index)
            let target = store.path(for: sha, ext: "bin")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            if materialize {
                var remaining = size
                while remaining > 0 {
                    let count = Int(min(Int64(materializedChunk.count), remaining))
                    try handle.write(contentsOf: materializedChunk.prefix(count))
                    remaining -= Int64(count)
                }
            } else {
                try handle.truncate(atOffset: UInt64(size))
            }
            logical += fileLogicalSize(target)
            allocated += fileAllocatedSize(target)
        }
        return (logical, allocated)
    }

    fileprivate static func fingerprint(for configuration: Configuration) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(configuration)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func fakeSHA(seed: UInt64, index: Int) -> String {
        let normalizedSeed = seed & 0x3fff_ffff
        return String(format: "%064llx", normalizedSeed &* 1_000_000 &+ UInt64(index) &+ 1)
    }

    private static func fileLogicalSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func fileAllocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }
}

private final class ProcessPeakFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.duopaste.benchmark.memory", qos: .userInitiated)

    func start() {
        sampleNow()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sampleNow() }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func sampleNow() {
        guard let current = Self.currentFootprint() else { return }
        lock.lock()
        peak = max(peak, current)
        lock.unlock()
    }

    func stop() -> UInt64 {
        sampleNow()
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    private static func currentFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}

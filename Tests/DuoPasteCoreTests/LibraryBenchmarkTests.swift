import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

@Suite("R4.1 library benchmark support", .serialized)
struct LibraryBenchmarkTests {
    private func temporaryRoot(_ suffix: String = "") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "duo-library-benchmark-tests-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    @Test("nearest-rank p50/p95 and gate evaluation are stable")
    func percentileAndGate() throws {
        let summary = try LibraryBenchmark.summarize(milliseconds: [1, 2, 3, 4, 100])
        #expect(summary.count == 5)
        #expect(summary.p50Ms == 3)
        #expect(summary.p95Ms == 100)
        #expect(summary.maxMs == 100)

        let passing = LibraryBenchmark.Gate(
            metric: .warmFTS,
            thresholdMs: 101,
            actualP95Ms: summary.p95Ms
        )
        let failing = LibraryBenchmark.Gate(
            metric: .warmFTS,
            thresholdMs: 100,
            actualP95Ms: summary.p95Ms
        )
        #expect(passing.passed)
        #expect(!failing.passed, "gate is strict: p95 must be below the threshold")
        #expect(throws: LibraryBenchmark.Error.self) {
            _ = try LibraryBenchmark.summarize(milliseconds: [])
        }
    }

    @Test("fixed seed produces deterministic mixed metadata and search tokens")
    func deterministicDataset() throws {
        let firstRoot = temporaryRoot("first")
        let secondRoot = temporaryRoot("second")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let configuration = LibraryBenchmark.Configuration(
            rowCount: 120,
            logicalBlobBytes: 1_048_576,
            blobFileCount: 8,
            seed: 42
        )

        let first = try LibraryBenchmark.prepareWorkspace(
            at: firstRoot,
            configuration: configuration,
            rebuild: false,
            materializeBlobs: false
        )
        let second = try LibraryBenchmark.prepareWorkspace(
            at: secondRoot,
            configuration: configuration,
            rebuild: false,
            materializeBlobs: false
        )

        #expect(first.configuration == configuration)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.rowCount == 120)
        #expect(Set(first.kindCounts.keys) == Set(ItemKind.allCases.map(\.rawValue)))
        #expect(first.kindCounts.values.allSatisfy { $0 > 0 })
        #expect(first.ocrStateCounts[OCRState.done.rawValue, default: 0] > 0)
        #expect(first.ocrStateCounts[OCRState.pending.rawValue, default: 0] > 0)
        #expect(first.pinnedCount > 0)
        #expect(first.deletedCount > 0)
        #expect(first.foldSiblingCount > 0)
        #expect(first.selectiveTokenCount > 0)
        #expect(first.integrityCheck == "ok")

        let db = try Database(path: Paths(root: firstRoot).mainDB)
        let tokens = try db.pool.read { sql in
            try Int.fetchOne(
                sql,
                sql: "SELECT COUNT(*) FROM item_fts WHERE item_fts MATCH ?",
                arguments: [LibraryBenchmark.selectiveSearchToken]
            ) ?? 0
        }
        #expect(tokens == first.selectiveTokenCount)
    }

    @Test("sparse blobs report logical and allocated bytes in BlobStore layout")
    func sparseBlobAccountingAndLayout() throws {
        let root = temporaryRoot("blobs")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibraryBenchmark.Configuration(
            rowCount: 40,
            logicalBlobBytes: 8 * 1_048_576,
            blobFileCount: 8,
            seed: 1 << 50
        )
        let manifest = try LibraryBenchmark.prepareWorkspace(
            at: root,
            configuration: configuration,
            rebuild: false,
            materializeBlobs: false
        )

        #expect(manifest.blobLogicalBytes == configuration.logicalBlobBytes)
        #expect(manifest.blobAllocatedBytes <= manifest.blobLogicalBytes)
        #expect(manifest.blobFileCount == configuration.blobFileCount)

        let blobs = BlobStore(root: Paths(root: root).blobsDir)
        for sha in manifest.sampleBlobSHA256s {
            let located = try #require(blobs.locate(sha256: sha))
            let components = located.pathComponents
            #expect(components.suffix(3).first == String(sha.prefix(2)))
            #expect(components.suffix(2).first == String(sha.dropFirst(2).prefix(2)))
        }
        let database = try Database(path: Paths(root: root).mainDB)
        let referenced = try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT blob_sha256 FROM item WHERE blob_sha256 IS NOT NULL"
            )
        }
        #expect(referenced.allSatisfy { blobs.exists(sha256: $0) })
    }

    @Test("production root and unmarked rebuild are refused")
    func workspaceSafety() throws {
        let production = Paths.defaultRoot()
        #expect(throws: LibraryBenchmark.Error.self) {
            _ = try LibraryBenchmark.validateWorkspace(production, rebuilding: false)
        }

        let root = temporaryRoot("unmarked")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("user-owned".utf8).write(to: root.appendingPathComponent("keep.txt"))
        #expect(throws: LibraryBenchmark.Error.self) {
            _ = try LibraryBenchmark.validateWorkspace(root, rebuilding: true)
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path))
    }

    @Test("JSON report round-trip retains samples, environment, dataset and gates")
    func reportRoundTrip() throws {
        let configuration = LibraryBenchmark.Configuration(
            rowCount: 1_000_000,
            logicalBlobBytes: 8 * 1_024 * 1_024 * 1_024,
            blobFileCount: 256,
            seed: 4_241
        )
        let manifest = LibraryBenchmark.DatasetManifest.fixture(configuration: configuration)
        let metric = LibraryBenchmark.MetricResult(
            name: .warmFTS,
            samplesMs: [8, 9, 10],
            summary: try LibraryBenchmark.summarize(milliseconds: [8, 9, 10]),
            peakFootprintBytes: 123_456
        )
        let report = LibraryBenchmark.Report(
            environment: .init(
                generatedAt: "2026-07-17T00:00:00Z",
                osVersion: "macOS test",
                architecture: "arm64",
                hardwareModel: "Mac test / Apple test",
                physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
                swiftVersion: "Swift test",
                buildConfiguration: "release",
                coldCachePolicy: "connection_cold_os_cache_uncontrolled"
            ),
            dataset: manifest,
            metrics: [metric],
            gates: [.init(metric: .warmFTS, thresholdMs: 100, actualP95Ms: 10)]
        )

        let data = try LibraryBenchmark.encodeReport(report)
        let decoded = try JSONDecoder().decode(LibraryBenchmark.Report.self, from: data)
        #expect(decoded == report)
        #expect(manifest.replacingDatabaseBytes(99).databaseBytes == 99)
        #expect(manifest.replacingDatabaseBytes(99).fingerprint == manifest.fingerprint)
    }

    @Test("default scale is manual-only million rows and eight GiB")
    func manualScaleDefaults() {
        let defaults = LibraryBenchmark.Configuration.default
        #expect(defaults.rowCount == 1_000_000)
        #expect(defaults.logicalBlobBytes == 8 * 1_024 * 1_024 * 1_024)
        #expect(defaults.blobFileCount == 256)
        #expect(LibraryBenchmark.executionPolicy == .explicitManualOrNightlyOnly)
    }

    @Test("small smoke executes every non-UI production metric")
    func coreMetricSmoke() throws {
        let root = temporaryRoot("metrics")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = LibraryBenchmark.Configuration(
            rowCount: 240,
            logicalBlobBytes: 1_048_576,
            blobFileCount: 8,
            seed: 99
        )
        _ = try LibraryBenchmark.prepareWorkspace(
            at: root,
            configuration: configuration,
            rebuild: false,
            materializeBlobs: false
        )
        let metrics = try LibraryBenchmark.runCoreMetrics(
            databaseURL: Paths(root: root).mainDB,
            samples: 2,
            warmups: 1
        )

        let expected: Set<LibraryBenchmark.MetricName> = [
            .coldFTS, .warmFTS, .emptyQuery, .qualifier,
            .countByKind, .deepPagination, .firstScreenData,
        ]
        #expect(Set(metrics.map(\.name)) == expected)
        #expect(metrics.allSatisfy { $0.samplesMs.count == 2 })
        #expect(metrics.allSatisfy { $0.summary.count == 2 })
        #expect(metrics.allSatisfy { $0.peakFootprintBytes > 0 })
    }

    @Test("CLI owns an explicit real SearchView render probe")
    func cliAndRealRenderContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cli = try String(contentsOf: root.appendingPathComponent("Sources/duo-pasted/CLI.swift"))
        let ui = try String(contentsOf: root.appendingPathComponent("Sources/duo-pasted/LibraryBenchmarkUI.swift"))
        let searchView = try String(contentsOf: root.appendingPathComponent("Sources/duo-pasted/SearchView.swift"))

        #expect(cli.contains("case \"benchmark-library\""))
        #expect(cli.contains("LibraryBenchmarkUI.run"))
        #expect(ui.contains("NSHostingView"))
        #expect(ui.contains("SearchView("))
        #expect(ui.contains("firstScreenRender"))
        #expect(ui.contains("metric(.countByKind"))
        #expect(ui.contains("thresholdMs: 150"))
        #expect(ui.contains("LibraryBenchmark.selectiveSearchToken"))
        #expect(ui.contains("SearchRefreshPolicy.delayNanoseconds"))
        #expect(searchView.contains("SearchRefreshPolicy.delayNanoseconds(for: state.query)"))
    }
}

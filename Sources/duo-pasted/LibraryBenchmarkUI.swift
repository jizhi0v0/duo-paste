import AppKit
import Foundation
import QuartzCore
import SwiftUI
import DuoPasteCore

/// Explicit manual/nightly entry point for R4.1. This lives in the app target so the render metric
/// uses the real internal `AppState` and `SearchView`, not a proxy card view.
@MainActor
enum LibraryBenchmarkUI {
    private struct Options {
        var workspace: URL
        var configuration: LibraryBenchmark.Configuration
        var samples: Int
        var warmups: Int
        var rebuild: Bool
        var reuse: Bool
        var renderOnly: Bool
        var materializeBlobs: Bool
        var output: URL
    }

    private enum OptionsError: Swift.Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    static func run(args: [String]) -> Int32 {
        do {
            if args.contains("--help") || args.contains("-h") {
                printUsage()
                return 0
            }
            let options = try parse(args)
            let marker = options.workspace.appendingPathComponent(LibraryBenchmark.markerFilename)
            if options.reuse, !FileManager.default.fileExists(atPath: marker.path) {
                throw OptionsError.message("--reuse requires an existing marked benchmark workspace")
            }
            if !options.rebuild, !options.reuse,
               FileManager.default.fileExists(atPath: marker.path) {
                throw OptionsError.message("workspace already exists; choose --reuse or --rebuild")
            }

            let manifest = try LibraryBenchmark.prepareWorkspace(
                at: options.workspace,
                configuration: options.configuration,
                rebuild: options.rebuild,
                materializeBlobs: options.materializeBlobs,
                progress: progress
            )
            let paths = Paths(root: options.workspace)
            var metrics: [LibraryBenchmark.MetricResult] = []
            if !options.renderOnly {
                metrics = try LibraryBenchmark.runCoreMetrics(
                    databaseURL: paths.mainDB,
                    samples: options.samples,
                    warmups: options.warmups,
                    progress: progress
                )
            }
            progress("measuring \(LibraryBenchmark.MetricName.firstScreenRender.rawValue)")
            metrics.append(try measureRealSearchView(
                paths: paths,
                samples: options.samples,
                warmups: options.warmups
            ))

            let renderP95 = try metric(.firstScreenRender, in: metrics).summary.p95Ms
            var gates: [LibraryBenchmark.Gate] = []
            if !options.renderOnly {
                let warmP95 = try metric(.warmFTS, in: metrics).summary.p95Ms
                gates.append(.init(metric: .warmFTS, thresholdMs: 100, actualP95Ms: warmP95))
                let summaryP95 = try metric(.countByKind, in: metrics).summary.p95Ms
                gates.append(.init(
                    metric: .countByKind,
                    thresholdMs: 150,
                    actualP95Ms: summaryP95
                ))
            }
            gates.append(.init(metric: .firstScreenRender, thresholdMs: 150, actualP95Ms: renderP95))
            let currentDatabaseBytes = try databaseFileSize(paths.mainDB)
            let report = LibraryBenchmark.Report(
                environment: environment(),
                dataset: manifest.replacingDatabaseBytes(currentDatabaseBytes),
                metrics: metrics,
                gates: gates
            )
            let data = try LibraryBenchmark.encodeReport(report)
            try FileManager.default.createDirectory(
                at: options.output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: options.output, options: .atomic)
            printReport(report, output: options.output)
            return gates.allSatisfy(\.passed) ? 0 : 2
        } catch {
            FileHandle.standardError.write(Data("benchmark-library failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func measureRealSearchView(
        paths: Paths,
        samples: Int,
        warmups: Int
    ) throws -> LibraryBenchmark.MetricResult {
        _ = NSApplication.shared
        let dependencies = try AppDependencies(paths: paths)
        let state = AppState(deps: dependencies, bootstrapSearch: false)
        let root = SearchView(
            state: state,
            onPaste: { _ in },
            onPastePlainText: { _ in },
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_100, height: 410)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        var iteration = 0
        let result = try LibraryBenchmark.measureMetric(
            name: .firstScreenRender,
            samples: samples,
            warmups: warmups
        ) {
            // The roadmap gate is keypress-to-first-screen, so include the exact production
            // debounce. Sleeping synchronously here models elapsed latency; production uses an
            // async sleep and leaves the main actor free during the same interval.
            Thread.sleep(
                forTimeInterval: Double(
                    SearchRefreshPolicy.delayNanoseconds(for: LibraryBenchmark.selectiveSearchToken)
                ) / 1_000_000_000
            )
            let token = iteration.isMultiple(of: 2)
                ? LibraryBenchmark.selectiveSearchToken
                : LibraryBenchmark.alternateSelectiveSearchToken
            let query = SearchQuery(text: token, limit: AppState.listLimit)
            let data = try LibraryBenchmark.makeFirstScreenData(
                api: dependencies.searchAPI,
                query: query
            )
            apply(data, query: token, to: state)
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            iteration += 1
        }
        window.orderOut(nil)
        return result
    }

    private static func databaseFileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw OptionsError.message("cannot read database size: \(url.path)")
        }
        return size.int64Value
    }

    private static func apply(
        _ data: LibraryBenchmark.FirstScreenData,
        query: String,
        to state: AppState
    ) {
        var kindCounts = data.kindCounts
        for kind in ItemKind.allCases where kindCounts[kind] == nil { kindCounts[kind] = 0 }
        var subKindCounts = data.fileSubKindCounts
        for kind in FileSubKind.allCases where subKindCounts[kind] == nil { subKindCounts[kind] = 0 }

        state.query = query
        state.results = data.items
        state.snippets = data.snippets
        state.totalCount = data.totalCount
        state.kindCounts = kindCounts
        state.fileSubKindCounts = subKindCounts
        state.selectedIDs = data.items.first.map { [$0.id] } ?? []
        state.anchorID = data.items.first?.id
    }

    private static func metric(
        _ name: LibraryBenchmark.MetricName,
        in metrics: [LibraryBenchmark.MetricResult]
    ) throws -> LibraryBenchmark.MetricResult {
        guard let result = metrics.first(where: { $0.name == name }) else {
            throw OptionsError.message("missing metric \(name.rawValue)")
        }
        return result
    }

    private static func parse(_ args: [String]) throws -> Options {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        let valueFlags: Set<String> = [
            "--workspace", "--rows", "--blob-gib", "--blob-mib", "--blob-files",
            "--seed", "--samples", "--warmups", "--output",
        ]
        let boolFlags: Set<String> = [
            "--rebuild", "--reuse", "--render-only", "--materialize-blobs",
        ]
        var index = 0
        while index < args.count {
            let arg = args[index]
            if boolFlags.contains(arg) {
                flags.insert(arg)
                index += 1
            } else if valueFlags.contains(arg) {
                guard index + 1 < args.count else {
                    throw OptionsError.message("\(arg) requires a value")
                }
                values[arg] = args[index + 1]
                index += 2
            } else {
                throw OptionsError.message("unknown option: \(arg)")
            }
        }
        guard let workspaceRaw = values["--workspace"] else {
            throw OptionsError.message("--workspace is required")
        }
        guard !(flags.contains("--rebuild") && flags.contains("--reuse")) else {
            throw OptionsError.message("--rebuild and --reuse are mutually exclusive")
        }

        func intValue(_ flag: String, default fallback: Int) throws -> Int {
            guard let raw = values[flag] else { return fallback }
            guard let value = Int(raw) else { throw OptionsError.message("invalid \(flag): \(raw)") }
            return value
        }
        let defaults = LibraryBenchmark.Configuration.default
        let rows = try intValue("--rows", default: defaults.rowCount)
        let blobFiles = try intValue("--blob-files", default: defaults.blobFileCount)
        let samples = try intValue("--samples", default: 20)
        let warmups = try intValue("--warmups", default: 2)
        let seed: UInt64
        if let raw = values["--seed"] {
            guard let parsed = UInt64(raw) else { throw OptionsError.message("invalid --seed: \(raw)") }
            seed = parsed
        } else {
            seed = defaults.seed
        }
        var blobBytes = defaults.logicalBlobBytes
        if let raw = values["--blob-gib"] {
            guard let gib = Double(raw), gib >= 0 else {
                throw OptionsError.message("invalid --blob-gib: \(raw)")
            }
            blobBytes = Int64(gib * 1_024 * 1_024 * 1_024)
        }
        if let raw = values["--blob-mib"] {
            guard values["--blob-gib"] == nil else {
                throw OptionsError.message("choose only one of --blob-gib and --blob-mib")
            }
            guard let mib = Double(raw), mib >= 0 else {
                throw OptionsError.message("invalid --blob-mib: \(raw)")
            }
            blobBytes = Int64(mib * 1_024 * 1_024)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let workspace = URL(
            fileURLWithPath: (workspaceRaw as NSString).expandingTildeInPath,
            relativeTo: cwd
        ).standardizedFileURL
        let output: URL
        if let raw = values["--output"] {
            output = URL(
                fileURLWithPath: (raw as NSString).expandingTildeInPath,
                relativeTo: cwd
            ).standardizedFileURL
        } else {
            output = cwd
                .appendingPathComponent("benchmarks/results", isDirectory: true)
                .appendingPathComponent("r4-1-\(timestamp()).json")
        }
        return Options(
            workspace: workspace,
            configuration: .init(
                rowCount: rows,
                logicalBlobBytes: blobBytes,
                blobFileCount: blobFiles,
                seed: seed
            ),
            samples: samples,
            warmups: warmups,
            rebuild: flags.contains("--rebuild"),
            reuse: flags.contains("--reuse"),
            renderOnly: flags.contains("--render-only"),
            materializeBlobs: flags.contains("--materialize-blobs"),
            output: output
        )
    }

    private static func environment() -> LibraryBenchmark.Environment {
        LibraryBenchmark.Environment(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture(),
            hardwareModel: hardwareModel(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            swiftVersion: swiftVersion(),
            buildConfiguration: buildConfiguration,
            coldCachePolicy: "connection_cold_os_cache_uncontrolled"
        )
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func swiftVersion() -> String {
        commandOutput(executable: "/usr/bin/xcrun", arguments: ["swift", "--version"])
            .split(separator: "\n")
            .first.map(String.init) ?? "unknown"
    }

    private static func hardwareModel() -> String {
        let lines = commandOutput(
            executable: "/usr/sbin/sysctl",
            arguments: ["-n", "hw.model", "machdep.cpu.brand_string"]
        ).split(separator: "\n").map(String.init)
        return lines.isEmpty ? "unknown" : lines.joined(separator: " / ")
    }

    private static func commandOutput(executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    private static func printReport(_ report: LibraryBenchmark.Report, output: URL) {
        print("benchmark-library · \(report.dataset.rowCount) rows · \(formatBytes(report.dataset.blobLogicalBytes)) logical blobs")
        for metric in report.metrics {
            print(String(
                format: "  %-20@ p50=%8.2fms  p95=%8.2fms  max=%8.2fms  peak=%@",
                metric.name.rawValue as NSString,
                metric.summary.p50Ms,
                metric.summary.p95Ms,
                metric.summary.maxMs,
                formatBytes(Int64(metric.peakFootprintBytes)) as NSString
            ))
        }
        for gate in report.gates {
            print(String(
                format: "  %@ gate %@ · p95 %.2fms < %.0fms",
                gate.passed ? "✓" : "✗",
                gate.metric.rawValue,
                gate.actualP95Ms,
                gate.thresholdMs
            ))
        }
        print("  report: \(output.path)")
        print("  cold policy: connection-cold; macOS page cache uncontrolled")
        print("  blobs: \(report.dataset.blobMode), allocated \(formatBytes(report.dataset.blobAllocatedBytes))")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    nonisolated private static func progress(_ message: String) {
        FileHandle.standardError.write(Data("benchmark-library: \(message)\n".utf8))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func printUsage() {
        print("""
        duo-pasted benchmark-library --workspace PATH [options]

          --rows N                 metadata rows (default 1000000)
          --blob-gib N             logical blob GiB (default 8)
          --blob-mib N             small smoke override
          --blob-files N           placeholder file count (default 256)
          --samples N              measured samples per metric (default 20)
          --warmups N              warm-up runs per metric (default 2)
          --seed N                 deterministic seed (default 4241)
          --rebuild                recreate an already marked workspace
          --reuse                  require and reuse an exact matching manifest
          --render-only            rerun only the real keypress-to-SearchView metric
          --materialize-blobs      physically write placeholders (default sparse)
          --output PATH            JSON report path
        """)
    }
}

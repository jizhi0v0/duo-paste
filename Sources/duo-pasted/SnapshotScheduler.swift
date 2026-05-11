import Foundation
import DuoPasteCore

/// 小时级触发的快照调度器。启动时若距上次快照已 > interval 则立即先跑一次。
@MainActor
final class SnapshotScheduler {
    private let deps: AppDependencies
    private let interval: TimeInterval
    private var timer: Timer?

    init(deps: AppDependencies, interval: TimeInterval = 3600) {
        self.deps = deps
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }

        // 启动时若需要补一次（首次或上次距今太久）
        if shouldRunImmediately() {
            runOnce()
        }

        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runOnce()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func shouldRunImmediately() -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: deps.paths.snapshotsDir.path) else {
            return true
        }
        let latest = entries
            .compactMap { Snapshot.parseDate(from: $0) }
            .max()
        guard let latest else { return true }
        return Date().timeIntervalSince(latest) > interval
    }

    private func runOnce() {
        do {
            let url = try Snapshot.takeSnapshot(database: deps.database, paths: deps.paths)
            let deleted = try Snapshot.prune(snapshotsDir: deps.paths.snapshotsDir)
            fputs("snapshot ok: \(url.lastPathComponent), pruned \(deleted.count)\n", stderr)
        } catch {
            fputs("snapshot failed: \(error)\n", stderr)
        }
    }
}

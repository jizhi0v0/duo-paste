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
        // 水位预防档：tick 末尾顺路跑一次 blob LRU GC。snapshot 失败不影响这条路径——
        // 反而磁盘满导致 snapshot 失败时这里腾空间是最有用的（下个 tick snapshot 就成功）
        runBlobWatermarkGC()
    }

    /// blob GC 阈值——可用空间低于 lowBytes 时驱逐 LRU 直到 highBytes。
    /// 双水位 hysteresis 避免阈值上下抖动反复触发
    private static let lowWatermarkBytes: Int64 = 5 * 1024 * 1024 * 1024   // 5 GB
    private static let highWatermarkBytes: Int64 = 10 * 1024 * 1024 * 1024 // 10 GB

    private func runBlobWatermarkGC() {
        do {
            let blobsDir = deps.paths.blobsDir
            let result = try deps.evictor.evictToWatermark(
                lowBytes: Self.lowWatermarkBytes,
                highBytes: Self.highWatermarkBytes,
                availableBytes: { Volume.availableBytes(at: blobsDir) }
            )
            if result.freed > 0 {
                fputs("blob-evict: freed \(result.freed) blobs capHit=\(result.capHit)\n", stderr)
            }
        } catch {
            fputs("blob-evict failed: \(error)\n", stderr)
        }
    }
}

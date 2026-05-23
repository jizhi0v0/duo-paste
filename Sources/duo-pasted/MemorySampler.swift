import Foundation
import Darwin
import DuoPasteCore

/// 周期采样进程内存写 stderr。日志格式：
/// `[mem] uptime=<s>s rss=<MB> footprint=<MB> items=<n>`
/// phys_footprint 是 macOS 算"内存压力"的标准字段，跟 Activity Monitor "Memory" 列对齐
@MainActor
final class MemorySampler {
    private let deps: AppDependencies
    private let interval: TimeInterval
    private var timer: Timer?
    private let startedAt = Date()

    init(deps: AppDependencies, interval: TimeInterval = 300) {
        self.deps = deps
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        runOnce()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runOnce() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func runOnce() {
        guard let s = Self.sample() else { return }
        let uptime = Int(Date().timeIntervalSince(startedAt))
        let items = (try? deps.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE deleted_at_ns IS NULL") ?? -1
        }) ?? -1
        let rssMB = Double(s.rss) / 1024 / 1024
        let footMB = Double(s.footprint) / 1024 / 1024
        fputs(String(format: "[mem] uptime=%ds rss=%.1fMB footprint=%.1fMB items=%d\n",
                     uptime, rssMB, footMB, items), stderr)
    }

    /// Mach task_info 读自身进程。比 fork `ps`/`footprint` 子进程便宜数个数量级
    private static func sample() -> (rss: UInt64, footprint: UInt64)? {
        var basic = mach_task_basic_info()
        var bCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let bKr = withUnsafeMutablePointer(to: &basic) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(bCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &bCount)
            }
        }
        guard bKr == KERN_SUCCESS else { return nil }

        var vmInfo = task_vm_info_data_t()
        var vCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let vKr = withUnsafeMutablePointer(to: &vmInfo) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &vCount)
            }
        }
        guard vKr == KERN_SUCCESS else { return nil }

        return (basic.resident_size, UInt64(vmInfo.phys_footprint))
    }
}

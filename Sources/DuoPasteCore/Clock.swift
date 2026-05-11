import Foundation

public enum Clock {
    /// 当前 wall-clock 时间的纳秒（CLOCK_REALTIME），用作捕获时间戳。
    /// 跨进程/跨设备可比，作为 item 全局排序键。
    public static func nowNs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }
}

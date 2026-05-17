import Foundation

/// iOS 内存日志环形缓冲。给 endpoint picker / coordinator / WS 等关键路径用,
/// Settings 一键导出全文本通过 share sheet 分享。
///
/// 容量:1000 行,够看半小时活动。线程安全:NSLock 守 buffer 写入。
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    private let lock = NSLock()
    private var entries: [String] = []
    private let capacity = 1000

    private init() {}

    func append(_ msg: String) {
        let ts = ISO8601DateFormatter.shared.string(from: Date())
        let line = "\(ts) \(msg)"
        // 同时打 stderr 让 Xcode console 看到(开发期),无 console 时只进 buffer
        FileHandle.standardError.write(Data((line + "\n").utf8))
        lock.lock()
        entries.append(line)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    /// 导出整个 buffer 为单字符串。Settings "导出日志" 按钮调,share sheet 用
    func snapshot() -> String {
        lock.lock()
        let copy = entries
        lock.unlock()
        let header = """
        DuoPaste iOS Debug Log
        Exported: \(ISO8601DateFormatter.shared.string(from: Date()))
        Entries: \(copy.count)

        """
        return header + copy.joined(separator: "\n") + "\n"
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

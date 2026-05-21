import Foundation

/// iOS 内存日志环形缓冲。给 endpoint picker / coordinator / WS 等关键路径用,
/// Settings 一键导出全文本通过 share sheet 分享。
///
/// 容量:1000 行,够看半小时活动。线程安全:NSLock 守 buffer 写入。
final class DebugLog: @unchecked Sendable {
    nonisolated static let shared = DebugLog()

    private let lock = NSLock()
    nonisolated(unsafe) private var entries: [String] = []
    private let stderrQueue = DispatchQueue(
        label: "io.duopaste.debuglog.stderr",
        qos: .utility
    )
    private let capacity = 1000

    nonisolated private init() {}

    nonisolated func append(_ msg: String) {
        let ts = Self.timestamp()
        let line = "\(ts) \(msg)"
        lock.lock()
        entries.append(line)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()

        // Xcode attached 时 stderr 可能被 Console / debugger 背压拖慢；同步写会卡住
        // MainActor。内存 ring buffer 仍同步更新，stderr 只做后台旁路诊断。
        //
        // **必须**走 POSIX write(2) 而不是 FileHandle.standardError.write(_:)——后者
        // 是 ObjC -[NSFileHandle writeData:] bridge,stderr fd EPIPE/EBADF/背压时抛
        // NSFileHandleOperationException,Swift 接不住直接 SIGABRT。release / 非 debugger
        // attached / 沙箱里 stderr 无消费者时这条路径会随机崩,断网后日志风暴必踩
        stderrQueue.async {
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBufferPointer { buf in
                Darwin.write(2, buf.baseAddress, buf.count)
            }
        }
    }

    /// 导出整个 buffer 为单字符串。Settings "导出日志" 按钮调,share sheet 用
    nonisolated func snapshot() -> String {
        lock.lock()
        let copy = entries
        lock.unlock()
        let header = """
        DuoPaste iOS Debug Log
        Exported: \(Self.timestamp())
        Entries: \(copy.count)

        """
        return header + copy.joined(separator: "\n") + "\n"
    }

    nonisolated func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    nonisolated private static func timestamp() -> String {
        String(format: "%.3f", Date().timeIntervalSince1970)
    }
}

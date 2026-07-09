import AppKit
import Foundation
import ObjectiveC
import OSLog

/// 布局期 / 事件循环里逃逸的未捕获 ObjC 异常,`.ips` 里通常**不带 reason**
/// (走 `+[NSApplication _crashOnException:]` → EXC_BREAKPOINT),unified log 又会滚掉。
/// 这里在崩之前把 name + reason + 栈落盘到 App Support,熬过日志滚动,下次能直接定位。
///
/// 装两道钩子:
///   1. `NSSetUncaughtExceptionHandler` —— 展开到线程顶的异常;
///   2. swizzle `-[NSApplication reportException:]` —— AppKit 在显示周期 / 事件循环里
///      抓到异常时**先**调它再决定 `_crashOnException:` 硬崩;正是那个"布局期崩溃"走的路,
///      顶层 handler 未必能收到,所以这道更关键。
enum CrashDiagnostics {
    private static let logger = Logger(subsystem: "io.duopaste.daemon", category: "UncaughtException")

    static func install() {
        NSSetUncaughtExceptionHandler { ex in
            CrashDiagnostics.record(exception: ex, source: "NSUncaughtExceptionHandler")
        }
        installReportExceptionHook()
    }

    private static func installReportExceptionHook() {
        let sel = NSSelectorFromString("reportException:")
        guard let method = class_getInstanceMethod(NSApplication.self, sel) else {
            logger.error("reportException: hook 未安装——找不到方法")
            return
        }
        let originalIMP = method_getImplementation(method)
        typealias OriginalFn = @convention(c) (AnyObject, Selector, NSException) -> Void
        let callOriginal = unsafeBitCast(originalIMP, to: OriginalFn.self)

        let replacement: @convention(block) (AnyObject, NSException) -> Void = { app, ex in
            CrashDiagnostics.record(exception: ex, source: "NSApplication.reportException:")
            callOriginal(app, sel, ex)   // 保留原行为(记录 + 视情况崩溃)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// 崩溃路径里跑,尽量少依赖:os_log 一条(live)+ 追加写文件(持久)。
    private static func record(exception ex: NSException, source: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        logger.fault("[\(source, privacy: .public)] \(ex.name.rawValue, privacy: .public): \(ex.reason ?? "(nil)", privacy: .public)")

        let text = """
        ===== UNCAUGHT via \(source) @ \(ts) =====
        name:   \(ex.name.rawValue)
        reason: \(ex.reason ?? "(nil)")
        callStack:
        \(ex.callStackSymbols.joined(separator: "\n"))

        """
        // 和 Paths.defaultRoot() 同一个根(~/Library/Application Support/duo-paste),
        // 但这里不复用 Paths 的 try!——崩溃路径里宁可 try? 静默失败也别二次崩。
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return }
        let dir = support.appendingPathComponent("duo-paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("uncaught-exception.log")
        guard let data = text.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}

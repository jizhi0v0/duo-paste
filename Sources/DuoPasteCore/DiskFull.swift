import Foundation

/// 识别 "磁盘满" 错误。`Data.write(to:options:[.atomic])` 跟 `FileManager.moveItem`
/// 在 ENOSPC 时抛 NSError，但封装层不同——直接抛 POSIXError 28、或包成 CocoaError
/// 640 `NSFileWriteOutOfSpaceError`、或在 userInfo 里挂 underlying POSIXError。
/// 这个 helper 三路都识别
public enum DiskFull {
    public static func isOutOfSpace(_ error: Error) -> Bool {
        let nsErr = error as NSError
        // 直接 POSIXError ENOSPC = 28
        if nsErr.domain == NSPOSIXErrorDomain && nsErr.code == 28 { return true }
        if nsErr.domain == NSCocoaErrorDomain {
            // NSFileWriteOutOfSpaceError
            if nsErr.code == 640 { return true }
            if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain, underlying.code == 28 {
                return true
            }
        }
        return false
    }
}

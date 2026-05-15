import Foundation

/// 磁盘卷可用空间查询。`URLResourceValues.volumeAvailableCapacityForImportantUsage` 是
/// Apple 推荐 API——比朴素 `availableCapacity` 准确，会扣掉系统 purgeable 缓存声明（让
/// 你看到的"真正可用"跟 Finder 显示的口径一致）。
///
/// 用于 BlobEvictor 水位判断：低于 watermark 时驱逐 oldest，高于 ceiling 时停手。
public enum Volume {
    /// 给定路径所在卷的"重要数据可用字节"。失败返回 nil（路径不存在 / 不在本地卷 / API
    /// 拿不到值）—— caller 应该把 nil 视为"水位不可知，跳过驱逐"，**不要**当作 0 触发
    /// aggressive GC，否则启动早期临时目录卷查不到值就误删整个 BlobStore
    public static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 递归 sum 目录下所有常规文件的字节总数。失败（路径不存在 / 权限）返回 nil。
    /// 大目录走 enumerator 不一次性加载，10k 个 blob 也 < 1s。**调用方应跑在后台**——
    /// 主线程同步调用会阻塞 UI。
    public static func directorySize(at root: URL) -> Int64? {
        let fm = FileManager.default
        // 显式 existence 预检：FileManager.enumerator 对不存在路径返回的是空 enumerator
        // 不是 nil，会让 caller 分不清"目录空"和"目录没了"两种情况
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else {
            return nil
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { continue }
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

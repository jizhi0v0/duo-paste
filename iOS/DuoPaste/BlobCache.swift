import Foundation
import ImageIO
import Observation
import UIKit

/// SHA-256 → bytes 的 iOS 端 cache。
///
/// 三层存储:
/// - 内存 `loaded` dictionary (SwiftUI 同步 lookup,zero-latency)
/// - 磁盘 `Caches/Blobs/v<N>/<ab>/<cd>/<sha>.bin` 跨启动持久化 + peer 重连秒命中
/// - 网络(PeerClient.fetchBlob 经 fetcher 注入)兜底
///
/// **LRU eviction**:磁盘超 `maxDiskBytes` (默 500MB) 时按文件 mtime 升序删旧文件。
/// 每次写盘后触发一次,扫 diskDir 算总 size 决定是否要删。
///
/// **diskFormatVersion**:encoder / 路径 layout 改了同步 bump,老 cache 自然 orphan(iOS
/// 在内存压力下回收 Caches/)。当前 v1。
///
/// **NSCachesDirectory 选址**:不进 iCloud backup,系统可在压力下回收。可接受——下次启动重拉。
///
/// **不在 init 时 wipe**:重启 app 仍命中磁盘 cache。peer 切换走 resetAll() 清两层运行时态
/// 但保留磁盘文件(下次同 peer 重连可秒命中);wipeDisk() 是测试用真删。
@Observable
@MainActor
final class BlobCache {
    private(set) var loaded: [String: Data] = [:]
    private(set) var loadingShas: Set<String> = []
    private(set) var failedReasons: [String: String] = [:]

    /// 已 cancel 的 sha 暂时进黑名单——避免 cell 重新出现在 viewport 自动重 fetch。
    /// reset / user 再 tap 时清。
    private(set) var cancelled: Set<String> = []

    private var inflight: [String: Task<Data, Error>] = [:]
    /// coordinator reconfigure 时注入。nil → fetch 抛 notConfigured
    var fetcher: (@Sendable (String) async throws -> Data)?

    /// 磁盘 cap(字节)。超 → evictIfNeeded 按 mtime 升序删旧文件。
    nonisolated let maxDiskBytes: Int

    /// 内存 cache 软上限。长度按字节计 (loaded 各 Data 的 .count 之和)。
    /// 超过 cap 时按 FIFO(insertOrder)删旧条目。**仅删 loaded 字典条目,磁盘文件不动**——
    /// 下次访问从磁盘 readFromDisk 自然恢复。
    /// 默认 64MB:够装一屏 LazyVGrid 自动预取的 image 缩略图字节(200KB × ~300 张),
    /// 又不会让长列表全部图片字节累积爆内存
    nonisolated let maxMemoryBytes: Int

    /// 解码后的 UIImage 缩略图 cache。卡片 view body 直接读这里,
    /// 避免每次 SwiftUI re-render 都同步在 main thread 重新 CGImageSource decode。
    /// FIFO 顺序按 insertOrderThumb 维护
    private(set) var thumbnails: [String: UIImage] = [:]

    /// 缩略图内存软上限。每张 ~320×320 decoded ≈ 400KB,16MB ≈ 40 张视区缓存
    nonisolated let maxThumbnailBytes: Int

    /// loaded 字典插入顺序队列。**不**在读访问时 mutate(避免 view body 评估期间改 @Observable
    /// 状态触发 SwiftUI 警告 / 潜在 re-render loop)。evict 时从队首删,语义=FIFO 而非 LRU——
    /// 对图片字节 cache 而言足够,代价是滚回视区的旧图可能从磁盘重读一次
    private var insertOrder: [String] = []
    /// 当前 loaded 字节数总和。每次 set/remove loaded 时维护,evict 时按 cap 触发删
    private var currentMemoryBytes: Int = 0
    /// thumbnails 字典 FIFO 顺序
    private var insertOrderThumb: [String] = []
    /// 当前 thumbnails 解码后估算字节数总和(UIImage 像素估算 w*h*4)
    private var currentThumbnailBytes: Int = 0
    /// 上次成功跑完 disk evictIfNeeded 的时间。多个并发 fetch 同时完成时只让一次 eviction
    /// 真跑,其它 fire-and-forget Task 命中 30s cool-down 直接 skip
    private var lastDiskEvictionAt: Date = .distantPast
    /// disk eviction cool-down(秒)——两次 evictIfNeeded 之间的最小间隔
    private static let diskEvictionMinInterval: TimeInterval = 30

    private static let diskFormatVersion = 1
    private let diskDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("Blobs", isDirectory: true)
            .appendingPathComponent("v\(BlobCache.diskFormatVersion)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(
        maxDiskBytes: Int = 500 * 1024 * 1024,
        maxMemoryBytes: Int = 64 * 1024 * 1024,
        maxThumbnailBytes: Int = 16 * 1024 * 1024
    ) {
        self.maxDiskBytes = maxDiskBytes
        self.maxMemoryBytes = maxMemoryBytes
        self.maxThumbnailBytes = maxThumbnailBytes
    }

    /// **不要**在这里 mutate LRU/insertOrder——view body 评估期间读 cached() 不能改 @Observable
    /// 状态,否则 SwiftUI 触发 "Modifying state during view update" 警告 + 潜在 re-render loop
    func cached(_ sha: String) -> Data? { loaded[sha] }
    func thumbnail(_ sha: String) -> UIImage? { thumbnails[sha] }
    func isLoading(_ sha: String) -> Bool { loadingShas.contains(sha) }
    func error(_ sha: String) -> String? { failedReasons[sha] }
    func isCancelled(_ sha: String) -> Bool { cancelled.contains(sha) }

    /// 重置运行时态——peer 换 / 断开时调。**不删磁盘**:下次同 peer 重连可秒命中
    /// (sha 是内容寻址,跨 peer 也安全复用)。
    func resetAll() {
        for t in inflight.values { t.cancel() }
        inflight.removeAll()
        loaded.removeAll()
        loadingShas.removeAll()
        failedReasons.removeAll()
        cancelled.removeAll()
        thumbnails.removeAll()
        insertOrder.removeAll()
        insertOrderThumb.removeAll()
        currentMemoryBytes = 0
        currentThumbnailBytes = 0
    }

    /// 写 loaded 的唯一入口——维护 insertOrder + currentMemoryBytes,
    /// 超 maxMemoryBytes 时按 FIFO 从队首删 loaded 条目(磁盘文件不动,下次访问从 disk 恢复)。
    /// **保留 count > 1 兜底**:单条 data 大于 cap 时不能把自己 evict 掉,否则 fetch 返回但
    /// loaded[sha] 立刻成 nil,caller 看不到字节
    private func setLoaded(_ sha: String, _ data: Data) {
        if let old = loaded[sha] {
            currentMemoryBytes -= old.count
            if let i = insertOrder.firstIndex(of: sha) {
                insertOrder.remove(at: i)
            }
        }
        loaded[sha] = data
        currentMemoryBytes += data.count
        insertOrder.append(sha)
        while currentMemoryBytes > maxMemoryBytes,
              insertOrder.count > 1,
              let oldest = insertOrder.first {
            insertOrder.removeFirst()
            if let removed = loaded.removeValue(forKey: oldest) {
                currentMemoryBytes -= removed.count
            }
        }
    }

    /// 写 thumbnails 的唯一入口——FIFO + 字节估算 cap。
    /// 像素字节估算用 w*h*4 (RGBA8);UIImage 实际可能是别的 format,但估算够用让 cap 不爆
    func setThumbnail(_ sha: String, _ img: UIImage) {
        let estBytes = Int(img.size.width * img.size.height * 4)
        if let old = thumbnails[sha] {
            currentThumbnailBytes -= Int(old.size.width * old.size.height * 4)
            if let i = insertOrderThumb.firstIndex(of: sha) {
                insertOrderThumb.remove(at: i)
            }
        }
        thumbnails[sha] = img
        currentThumbnailBytes += estBytes
        insertOrderThumb.append(sha)
        while currentThumbnailBytes > maxThumbnailBytes,
              insertOrderThumb.count > 1,
              let oldest = insertOrderThumb.first {
            insertOrderThumb.removeFirst()
            if let removed = thumbnails.removeValue(forKey: oldest) {
                currentThumbnailBytes -= Int(removed.size.width * removed.size.height * 4)
            }
        }
    }

    /// 缩略图解码 entry——bytes 已在 loaded[sha],kick 后台 task 用 ImageIO 降采样到 maxPx,
    /// 结果回 main actor 进 thumbnails dict。已在解码 / 已有结果都跳过。
    /// view body 读 thumbnail(sha) 是 nil → 显占位 + spinner,decode 完成 SwiftUI 自然 reflow
    func requestThumbnail(sha: String, maxPx: Int) {
        if thumbnails[sha] != nil { return }
        guard let data = loaded[sha] else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let img = Self.decodeThumbnail(data: data, maxPx: maxPx)
            guard let img else { return }
            await self?.setThumbnail(sha, img)
        }
    }

    /// 后台 detached 用——ImageIO 降采样,只解到 maxPx,不进 UIImage(data:) 全解。
    /// kCGImageSourceShouldCacheImmediately 让像素在 thumbnail 创建时就 decode 完,
    /// 后续显示不再在 main thread render 时 lazy decode 卡顿
    nonisolated static func decodeThumbnail(data: Data, maxPx: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    /// 真删磁盘——测试 / debug。生产路径不调
    func wipeDisk() {
        let dir = diskDir
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 触发或复用 fetch。同 sha 重复 fetch 共享同一个 inflight task。
    /// 缓存命中(内存)直接返回 wrap 好的 task(立即 ready);磁盘命中进 task 异步读盘。
    @discardableResult
    func fetch(_ sha: String) -> Task<Data, Error> {
        if let d = loaded[sha] { return Task { d } }
        if let existing = inflight[sha] { return existing }
        cancelled.remove(sha)
        failedReasons.removeValue(forKey: sha)
        loadingShas.insert(sha)
        let task = Task<Data, Error> { [weak self] in
            try await self?.performFetch(sha: sha) ?? Data()
        }
        inflight[sha] = task
        return task
    }

    private func performFetch(sha: String) async throws -> Data {
        let path = Self.diskPath(in: diskDir, sha: sha)

        // 1) 磁盘命中——detach 出 main actor 读字节(大图 32MB 同步读会卡 UI)
        if let data = await Self.readFromDisk(path: path) {
            setLoaded(sha, data)
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            return data
        }

        // 2) 网络
        guard let fetcher else {
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            throw BlobCacheError.notConfigured
        }
        DebugLog.shared.append("blob fetch begin sha=\(sha.prefix(8))")
        do {
            let data = try await fetcher(sha)
            DebugLog.shared.append("blob fetch ok sha=\(sha.prefix(8)) bytes=\(data.count)")
            // 内存 cache 必须**先**填，再 fire-and-forget 落盘 + LRU。
            // 旧版 await writeToDisk + await evictIfNeeded 串行进 hot path，evictIfNeeded
            // 会枚举整个磁盘 cache 目录读每文件 resourceValues（数千文件时 3-4s），
            // 让 loaded[sha] = data 的 Observation 更新被拖在 SwiftUI 视图外。直接表现：
            // 长按图片首次预览要等几秒才出图，第二次（cache 命中）才秒开。
            setLoaded(sha, data)
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            scheduleBackgroundPersist(path: path, data: data)
            return data
        } catch is CancellationError {
            DebugLog.shared.append("blob fetch cancelled sha=\(sha.prefix(8))")
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            cancelled.insert(sha)
            throw CancellationError()
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            DebugLog.shared.append("blob fetch URLError.cancelled sha=\(sha.prefix(8))")
            // URLSession invalidateAndCancel / reconfigure 路径下 fetcher 抛
            // URLError.cancelled 而非 CancellationError；视同用户主动 cancel 进黑名单，
            // 而不是 generic 失败写 failedReasons。resetAll 会清 cancelled，让重连后能重拉
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            cancelled.insert(sha)
            throw CancellationError()
        } catch {
            DebugLog.shared.append("blob fetch failed sha=\(sha.prefix(8)) error=\(error.localizedDescription)")
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            failedReasons[sha] = error.localizedDescription
            throw error
        }
    }

    /// fire-and-forget 落盘 + LRU eviction。eviction 走 30s cool-down——
    /// 多 fetch 并发完成时只让一次 eviction 真扫盘,其它 skip。落盘本身不去重(覆盖写
    /// 同 sha 等同 no-op,代价极小)
    private func scheduleBackgroundPersist(path: URL, data: Data) {
        let dirForBg = diskDir
        let maxForBg = maxDiskBytes
        let now = Date()
        let shouldEvict: Bool
        if now.timeIntervalSince(lastDiskEvictionAt) > Self.diskEvictionMinInterval {
            lastDiskEvictionAt = now
            shouldEvict = true
        } else {
            shouldEvict = false
        }
        Task.detached(priority: .utility) {
            await Self.writeToDisk(path: path, data: data)
            if shouldEvict {
                await Self.evictIfNeeded(diskDir: dirForBg, maxBytes: maxForBg)
            }
        }
    }

    /// 用户主动取消(滑出视区 / 再点)。inflight task cancel,黑名单挡住自动重拉。
    func cancel(_ sha: String) {
        inflight[sha]?.cancel()
        inflight.removeValue(forKey: sha)
        loadingShas.remove(sha)
        cancelled.insert(sha)
    }

    // MARK: - IO helpers (offload from MainActor)

    /// SHA → `<diskDir>/<sha[0..2]>/<sha[2..4]>/<sha>.bin`。三层避免单目录文件数过多。
    nonisolated static func diskPath(in diskDir: URL, sha: String) -> URL {
        let p1 = String(sha.prefix(2))
        let p2 = String(sha.dropFirst(2).prefix(2))
        return diskDir
            .appendingPathComponent(p1, isDirectory: true)
            .appendingPathComponent(p2, isDirectory: true)
            .appendingPathComponent(sha + ".bin")
    }

    /// 读盘 + touch mtime(LRU 用)。文件不存在 / 读失败返 nil。
    nonisolated static func readFromDisk(path: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            guard let data = try? Data(contentsOf: path) else { return nil }
            // touch mtime——让 LRU 知道这条最近被用
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: path.path
            )
            return data
        }.value
    }

    /// 落盘原子写。父目录不存在自动建。失败 swallow(磁盘 cache 不是 critical path)
    nonisolated static func writeToDisk(path: URL, data: Data) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: path, options: .atomic)
        }.value
    }

    /// LRU eviction:扫 diskDir 算总 size,超 cap 按 mtime 升序删到不超。
    nonisolated static func evictIfNeeded(diskDir: URL, maxBytes: Int) async {
        await Task.detached(priority: .utility) {
            evictIfNeededSync(diskDir: diskDir, maxBytes: maxBytes)
        }.value
    }

    /// Swift 6 async 上下文里不能直接 for-case-let enumerator——拆 sync helper 跑同步遍历
    nonisolated private static func evictIfNeededSync(diskDir: URL, maxBytes: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: diskDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        var entries: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey
            ]),
                  vals.isRegularFile == true,
                  let size = vals.fileSize,
                  let mtime = vals.contentModificationDate else { continue }
            entries.append((url, size, mtime))
            total += size
        }
        guard total > maxBytes else { return }
        entries.sort { $0.mtime < $1.mtime }
        for e in entries {
            if total <= maxBytes { break }
            try? fm.removeItem(at: e.url)
            total -= e.size
        }
    }
}

enum BlobCacheError: LocalizedError {
    case notConfigured
    var errorDescription: String? { "未配置 peer,无法拉取 blob" }
}

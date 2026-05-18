import Foundation
import Observation

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

    private static let diskFormatVersion = 1
    private let diskDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("Blobs", isDirectory: true)
            .appendingPathComponent("v\(BlobCache.diskFormatVersion)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(maxDiskBytes: Int = 500 * 1024 * 1024) {
        self.maxDiskBytes = maxDiskBytes
    }

    func cached(_ sha: String) -> Data? { loaded[sha] }
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
            loaded[sha] = data
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
        do {
            let data = try await fetcher(sha)
            // 3) 落盘 + LRU 清理——同样 detach。落盘失败不影响内存 cache 返回。
            await Self.writeToDisk(path: path, data: data)
            await Self.evictIfNeeded(diskDir: diskDir, maxBytes: maxDiskBytes)
            loaded[sha] = data
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            return data
        } catch is CancellationError {
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            cancelled.insert(sha)
            throw CancellationError()
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            // URLSession invalidateAndCancel / reconfigure 路径下 fetcher 抛
            // URLError.cancelled 而非 CancellationError；视同用户主动 cancel 进黑名单，
            // 而不是 generic 失败写 failedReasons。resetAll 会清 cancelled，让重连后能重拉
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            cancelled.insert(sha)
            throw CancellationError()
        } catch {
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            failedReasons[sha] = error.localizedDescription
            throw error
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

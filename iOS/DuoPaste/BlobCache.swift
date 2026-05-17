import Foundation
import Observation

/// SHA-256 → bytes 的内存缓存,带 in-flight task 去重 + 取消能力。
///
/// 只在 user 主动触发(tap image / share)时 fetch。fetcher 由 PeerSyncCoordinator
/// 在 reconfigure() 时注入,断开 / 换 peer → resetAll() 把缓存 + inflight task 全清。
///
/// 不是 LRU,纯 append-only 内存字典。MVP 阶段够用——image 通常 < 几 MB,正常使用
/// 累积一两百张才到 ~几百 MB,iOS 给应用的内存上限够。后续 OOM 再加 cap。
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

    func cached(_ sha: String) -> Data? { loaded[sha] }
    func isLoading(_ sha: String) -> Bool { loadingShas.contains(sha) }
    func error(_ sha: String) -> String? { failedReasons[sha] }
    func isCancelled(_ sha: String) -> Bool { cancelled.contains(sha) }

    /// 重置全部状态——peer 换 / 断开时调。inflight task 全取消。
    func resetAll() {
        for t in inflight.values { t.cancel() }
        inflight.removeAll()
        loaded.removeAll()
        loadingShas.removeAll()
        failedReasons.removeAll()
        cancelled.removeAll()
    }

    /// 触发或复用 fetch。同 sha 重复 fetch 共享同一个 inflight task。
    /// 缓存命中直接返回 wrap 好的 task(立即 ready)。
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
        guard let fetcher else {
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            throw BlobCacheError.notConfigured
        }
        do {
            let data = try await fetcher(sha)
            loaded[sha] = data
            loadingShas.remove(sha)
            inflight.removeValue(forKey: sha)
            return data
        } catch is CancellationError {
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
}

enum BlobCacheError: LocalizedError {
    case notConfigured
    var errorDescription: String? { "未配置 peer,无法拉取 blob" }
}

import Foundation
import UIKit
import Observation

/// bundleID → macOS app icon UIImage 的 iOS 端 cache。
///
/// 两层存储:
/// - 内存 `loaded` dictionary 给 SwiftUI 直接 lookup(同步,zero-latency)
/// - 磁盘 `Caches/AppIcons/<bundleID>.png` 持久化跨启动 — peer 重连 / 重启 app 不重拉
///
/// 已知缺失(server 404)进 `notFound`,后续不再发请求 — 防止 cell 反复触发 .task
/// 拉同一个永远 404 的 bundleID。peer 换 → resetAll() 清两层 + notFound 黑名单。
@Observable
@MainActor
final class AppIconCache {
    /// 命中 = UIImage 实例已就绪(从内存或刚解码完磁盘字节)
    private(set) var loaded: [String: UIImage] = [:]
    /// inflight 请求 — 同 bundleID 并发触发只起一份 task
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    /// server 返 404 / disk 解码失败 / fetcher 错过 — 已知缺失,后续 cell render 不再触发
    private(set) var notFound: Set<String> = []

    /// PeerSyncCoordinator.reconfigure 注入 — 拿 PeerClient.fetchAppIcon。
    /// nil → fetch 直接返 nil(等价"未配置")
    var fetcher: (@Sendable (String) async throws -> Data?)?

    /// 磁盘持久化目录 — Caches/AppIcons/v<N>/。系统在内存压力时会清掉,可接受
    /// (下次启动重拉)。NSCachesDirectory 不进 iCloud backup。
    ///
    /// 路径里的 v<N> 是 encoder 格式版本 — daemon 端 encoder 升级(e.g. v2 干掉 dock
    /// baseline shadow)时同步 bump 这个版本,老文件自然 orphan(iOS 会回收 Caches),
    /// 新请求走新子目录 = 一定 miss → 拉新字节
    private static let diskFormatVersion = 2
    private let diskDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("AppIcons", isDirectory: true)
            .appendingPathComponent("v\(AppIconCache.diskFormatVersion)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 同步快路径:内存命中直接给。SwiftUI render 阶段调,不挂任何 async
    func cached(_ bundleID: String) -> UIImage? { loaded[bundleID] }

    /// 触发或复用 fetch。disk 命中算 inflight task 起一份 sync 加载;
    /// 已 known-missing 立即返 nil;否则起 network task。
    /// 同 bundleID 并发触发(grid 多个 cell 同 app)共享同一 inflight。
    @discardableResult
    func fetch(_ bundleID: String) -> Task<UIImage?, Never> {
        if let img = loaded[bundleID] {
            return Task { img }
        }
        if notFound.contains(bundleID) {
            return Task { nil }
        }
        if let existing = inflight[bundleID] {
            return existing
        }
        let task = Task<UIImage?, Never> { [weak self] in
            await self?.performFetch(bundleID: bundleID) ?? nil
        }
        inflight[bundleID] = task
        return task
    }

    /// peer 切换 / 断开时调 — 清两层 cache + notFound 黑名单 + 取消 inflight。
    /// 磁盘文件不删(下次同 peer 重连可秒命中);要彻底清得用 wipeDisk()
    func resetAll() {
        for t in inflight.values { t.cancel() }
        inflight.removeAll()
        loaded.removeAll()
        notFound.removeAll()
    }

    /// 测试 / debug — 真删磁盘文件
    func wipeDisk() {
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    // MARK: - 内部

    private func performFetch(bundleID: String) async -> UIImage? {
        defer { inflight.removeValue(forKey: bundleID) }

        // disk 命中
        let diskPath = diskDir.appendingPathComponent(safeFilename(bundleID) + ".png")
        if FileManager.default.fileExists(atPath: diskPath.path),
           let data = try? Data(contentsOf: diskPath),
           let img = UIImage(data: data) {
            loaded[bundleID] = img
            return img
        }

        // network
        guard let fetcher else {
            // 不进 notFound — 等 peer 配好后下一次 fetch 仍要尝试
            return nil
        }
        do {
            guard let data = try await fetcher(bundleID) else {
                notFound.insert(bundleID)
                return nil
            }
            guard let img = UIImage(data: data) else {
                notFound.insert(bundleID)
                return nil
            }
            // 写盘 + 内存
            try? data.write(to: diskPath, options: .atomic)
            loaded[bundleID] = img
            return img
        } catch {
            // 网络错 / HTTP 5xx — 不进 notFound,下次重试。只 404 → fetcher 返 nil 进 notFound
            return nil
        }
    }

    /// bundleID 一般只含 [a-zA-Z0-9.-_],跟文件名兼容。兜底 replace "/" 防意外
    private func safeFilename(_ bundleID: String) -> String {
        bundleID.replacingOccurrences(of: "/", with: "_")
    }
}

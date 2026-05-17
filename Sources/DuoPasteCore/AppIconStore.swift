import Foundation
import GRDB

/// bundleID → app icon PNG 字节的 SQLite-backed cache,带内存 negative cache。
///
/// 设计:
/// - 持久化(SQLite `app_icon` 表)= daemon 重启 / iOS 端首次冷启不用重 PNG encode
/// - 内存 negative cache = 已知 app 没装的 bundleID 不每次都重跑 NSWorkspace 查找
/// - resolver 闭包从 daemon 注入(AppKit-side `NSWorkspace.icon + PNG encode`),
///   把 AppKit 依赖隔离在 duo-pasted target,DuoPasteCore 保持平台中立(GRDB only)
///
/// 用法:
///
///     let store = AppIconStore(database: db) { bid in
///         AppKitIconResolver.pngBytes(forBundleID: bid)
///     }
///     let bytes = try await store.iconPNG(forBundleID: "com.apple.Safari")
///
public actor AppIconStore {
    public typealias IconResolver = @Sendable (_ bundleID: String) -> Data?

    private let database: Database
    private let resolver: IconResolver

    /// 已 resolve 过的 bundleID — value 是 PNG 字节(命中)或 nil(已知没装)。
    /// 命中 case 也 cache 在内存避免 SQLite 反复 read;miss case 永不写表(节省存储)
    private var memCache: [String: Data?] = [:]

    public init(database: Database, resolver: @escaping IconResolver) {
        self.database = database
        self.resolver = resolver
    }

    /// 查 bundleID 对应 icon 字节。顺序:内存 cache → SQLite 表 → resolver(AppKit)。
    /// resolver 返 nil(app 未装 / sandbox 拒访问) → 缓存负命中,后续请求快速返 nil
    public func iconPNG(forBundleID bundleID: String) async throws -> Data? {
        if memCache.keys.contains(bundleID) {
            return memCache[bundleID, default: nil]
        }

        // SQLite 命中 → 缓存进内存返回
        if let bytes = try await database.pool.read({ db in
            try Data.fetchOne(
                db,
                sql: "SELECT png_bytes FROM app_icon WHERE bundle_id = ?",
                arguments: [bundleID]
            )
        }) {
            memCache[bundleID] = bytes
            return bytes
        }

        // 都没命中 → 调 resolver 算
        guard let bytes = resolver(bundleID) else {
            memCache[bundleID] = .some(nil)
            return nil
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        try await database.pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO app_icon (bundle_id, png_bytes, fetched_at_ns, app_version)
                VALUES (?, ?, ?, NULL);
            """, arguments: [bundleID, bytes, now])
        }
        memCache[bundleID] = bytes
        return bytes
    }

    /// 测试 / debug 用 — 清空内存 cache,下次请求重走 SQLite
    public func invalidateMemoryCache() {
        memCache.removeAll()
    }

    /// 直接写表(测试用 — 跳过 resolver,模拟"已 cache 的字节")
    public func _testInsert(bundleID: String, pngBytes: Data) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        try await database.pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO app_icon (bundle_id, png_bytes, fetched_at_ns, app_version)
                VALUES (?, ?, ?, NULL);
            """, arguments: [bundleID, pngBytes, now])
        }
        memCache[bundleID] = pngBytes
    }
}

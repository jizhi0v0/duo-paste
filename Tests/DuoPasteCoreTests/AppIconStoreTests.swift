import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private func makeDB() throws -> DuoPasteCore.Database {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-icon-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoPasteCore.Database(path: paths.mainDB)
}

@Test func v10AppIconTableExists() async throws {
    let db = try makeDB()
    let columns = try await db.pool.read { conn -> [String] in
        try Row.fetchAll(conn, sql: "PRAGMA table_info(app_icon)").map {
            ($0["name"] as String?) ?? ""
        }
    }
    #expect(columns.contains("bundle_id"))
    #expect(columns.contains("png_bytes"))
    #expect(columns.contains("fetched_at_ns"))
    #expect(columns.contains("app_version"))
}

@Test func appIconStoreCachesResolverHitInDB() async throws {
    let db = try makeDB()
    // resolver 每次返同一字节,但应该只被调一次(第一次 miss → 写表 → 后续从表读)
    let callCount = LockedInt()
    let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  // PNG magic
    let store = AppIconStore(database: db) { _ in
        callCount.increment()
        return pngBytes
    }

    let first = try await store.iconPNG(forBundleID: "com.apple.Safari")
    #expect(first == pngBytes)
    #expect(callCount.value == 1)

    // 第二次走内存 cache,resolver 不再调
    let second = try await store.iconPNG(forBundleID: "com.apple.Safari")
    #expect(second == pngBytes)
    #expect(callCount.value == 1)

    // 清内存 cache → 走 SQLite read,resolver 仍不调(表里已有)
    await store.invalidateMemoryCache()
    let third = try await store.iconPNG(forBundleID: "com.apple.Safari")
    #expect(third == pngBytes)
    #expect(callCount.value == 1)
}

@Test func appIconStoreNegativeCachesMissingApps() async throws {
    let db = try makeDB()
    let callCount = LockedInt()
    let store = AppIconStore(database: db) { _ in
        callCount.increment()
        return nil  // app 没装
    }

    let first = try await store.iconPNG(forBundleID: "com.nonexistent.app")
    #expect(first == nil)
    #expect(callCount.value == 1)

    // 负命中走内存,resolver 不再调
    let second = try await store.iconPNG(forBundleID: "com.nonexistent.app")
    #expect(second == nil)
    #expect(callCount.value == 1)

    // 表里**不**应该有这一行(负命中不写表,避免 BLOB 浪费空间)
    let exists = try await db.pool.read { conn -> Bool in
        try Bool.fetchOne(conn, sql: """
            SELECT EXISTS(SELECT 1 FROM app_icon WHERE bundle_id = ?)
        """, arguments: ["com.nonexistent.app"]) ?? false
    }
    #expect(exists == false)
}

@Test func appIconStorePersistsAcrossInstances() async throws {
    let db = try makeDB()
    let bytes1 = Data([0x89, 0x50, 0x4E, 0x47])
    let store1 = AppIconStore(database: db) { _ in bytes1 }
    _ = try await store1.iconPNG(forBundleID: "com.apple.Safari")

    // 新 store 实例(模拟 daemon 重启),resolver 这次会抛 — 验证读的是磁盘
    let store2 = AppIconStore(database: db) { _ in
        Issue.record("resolver should not be called when row exists in DB")
        return nil
    }
    let bytes = try await store2.iconPNG(forBundleID: "com.apple.Safari")
    #expect(bytes == bytes1)
}

/// 小工具 — Swift 6 strict concurrency 下 escaping closure 内的可变状态
final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}

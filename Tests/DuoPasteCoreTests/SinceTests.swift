import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private typealias DuoDB = DuoPasteCore.Database

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-since-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeDB() throws -> DuoDB {
    let paths = Paths(root: tempDir())
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func mkItem(
    id: String,
    ingestedAtNs: Int64?,
    capturedAtNs: Int64 = 1_700_000_000_000_000_000,
    text: String = "x",
    deletedAtNs: Int64? = nil
) -> Item {
    Item(
        id: id,
        originDevice: "test",
        capturedAtNs: capturedAtNs,
        ingestedAtNs: ingestedAtNs,
        kind: .text,
        preview: text,
        textFull: text,
        deletedAtNs: deletedAtNs
    )
}

private func insert(_ db: DuoDB, _ items: [Item]) throws {
    try db.pool.write { conn in
        for it in items { try it.insert(conn) }
    }
}

@Test func sinceFromZeroReturnsAllInIngestOrder() throws {
    let db = try makeDB()
    try insert(db, [
        mkItem(id: "c", ingestedAtNs: 30),
        mkItem(id: "a", ingestedAtNs: 10),
        mkItem(id: "b", ingestedAtNs: 20),
    ])
    let page = try SinceAPI(database: db).fetch(SinceQuery())
    #expect(page.items.map(\.id) == ["a", "b", "c"])
    #expect(page.hasMore == false)
    #expect(page.nextCursor.ingestedAtNs == 30)
    #expect(page.nextCursor.id == "c")
}

@Test func sinceSkipsNullIngestedAtNs() throws {
    // client 上还没 push 的本地条目（ingested_at_ns IS NULL）不该出现在 /since 流里
    let db = try makeDB()
    try insert(db, [
        mkItem(id: "ingested", ingestedAtNs: 5),
        mkItem(id: "local-only", ingestedAtNs: nil),
    ])
    let page = try SinceAPI(database: db).fetch(SinceQuery())
    #expect(page.items.map(\.id) == ["ingested"])
}

@Test func sinceIncludesSoftDeletedRows() throws {
    // mirror 需要 replay 软删，所以 /since 不能过滤 deleted_at_ns
    let db = try makeDB()
    try insert(db, [
        mkItem(id: "alive", ingestedAtNs: 1),
        mkItem(id: "dead", ingestedAtNs: 2, deletedAtNs: 99),
    ])
    let ids = try SinceAPI(database: db).fetch(SinceQuery()).items.map(\.id)
    #expect(ids == ["alive", "dead"])
}

@Test func sinceCursorIsExclusive() throws {
    // 用上一页 nextCursor 再来一次，不应该重复返回最后那条
    let db = try makeDB()
    try insert(db, [
        mkItem(id: "a", ingestedAtNs: 10),
        mkItem(id: "b", ingestedAtNs: 20),
        mkItem(id: "c", ingestedAtNs: 30),
    ])
    let api = SinceAPI(database: db)
    let p1 = try api.fetch(SinceQuery(limit: 2))
    #expect(p1.items.map(\.id) == ["a", "b"])
    #expect(p1.hasMore == true)
    let p2 = try api.fetch(SinceQuery(cursor: p1.nextCursor, limit: 2))
    #expect(p2.items.map(\.id) == ["c"])
    #expect(p2.hasMore == false)
}

@Test func sinceTiebreaksOnIdForSameNs() throws {
    // 同 ingested_at_ns 多条：id ASC 二级排序确保跨页 stable
    let db = try makeDB()
    try insert(db, [
        mkItem(id: "id-z", ingestedAtNs: 100),
        mkItem(id: "id-a", ingestedAtNs: 100),
        mkItem(id: "id-m", ingestedAtNs: 100),
    ])
    let api = SinceAPI(database: db)
    let p1 = try api.fetch(SinceQuery(limit: 2))
    #expect(p1.items.map(\.id) == ["id-a", "id-m"])
    #expect(p1.hasMore == true)
    #expect(p1.nextCursor.ingestedAtNs == 100)
    #expect(p1.nextCursor.id == "id-m")
    let p2 = try api.fetch(SinceQuery(cursor: p1.nextCursor, limit: 2))
    #expect(p2.items.map(\.id) == ["id-z"])
    #expect(p2.hasMore == false)
}

@Test func sinceEmptyResultPreservesInputCursor() throws {
    // 空结果时 nextCursor 原样回输入——pull worker 持久化逻辑可以无脑
    let db = try makeDB()
    try insert(db, [mkItem(id: "a", ingestedAtNs: 5)])
    let api = SinceAPI(database: db)
    let cursor = SinceCursor(ingestedAtNs: 1_000_000, id: "anything")
    let p = try api.fetch(SinceQuery(cursor: cursor))
    #expect(p.items.isEmpty)
    #expect(p.hasMore == false)
    #expect(p.nextCursor == cursor)
}

@Test func sinceLimitClampsToMax() throws {
    // limit 上界保护：1000 上限，请求 5000 → 返回 max 1000 行（这里只塞 3 条，所以拿到全部）
    let db = try makeDB()
    try insert(db, [
        mkItem(id: "a", ingestedAtNs: 1),
        mkItem(id: "b", ingestedAtNs: 2),
        mkItem(id: "c", ingestedAtNs: 3),
    ])
    let page = try SinceAPI(database: db).fetch(SinceQuery(limit: 5000))
    #expect(page.items.count == 3)
    #expect(page.hasMore == false)
}

@Test func sinceCursorIsStrictlyExclusiveOnSameNs() throws {
    // 显式覆盖 OR-clause 的边界：cursor=(100, "id-m") 下一页应跳过 id-a / id-m（同 ns 但 id <= cursor）
    // 这是 (a > x) OR (a = x AND b > y) 的关键 case——错写成 b >= y 会重复返回 id-m
    let db = try makeDB()
    try insert(db, [
        mkItem(id: "id-a", ingestedAtNs: 100),
        mkItem(id: "id-m", ingestedAtNs: 100),
        mkItem(id: "id-z", ingestedAtNs: 100),
    ])
    let cursor = SinceCursor(ingestedAtNs: 100, id: "id-m")
    let page = try SinceAPI(database: db).fetch(SinceQuery(cursor: cursor, limit: 10))
    #expect(page.items.map(\.id) == ["id-z"])  // id-a (id < cursor.id) + id-m (id == cursor.id) 都不返回
}

@Test func nextIngestNsIsStrictlyMonotonic() throws {
    // 即使两次 now() 给同样的值（NTP 倒退 / 同纳秒），nextIngestNs 也必须严格单增——
    // 这是 /since 不漏行的契约
    let db = try makeDB()
    try db.pool.write { conn in
        let n1 = try DuoPasteCore.Database.nextIngestNs(conn, now: 500)
        #expect(n1 == 500)
        try mkItem(id: "a", ingestedAtNs: n1).insert(conn)
        let n2 = try DuoPasteCore.Database.nextIngestNs(conn, now: 500)  // 同 now → 必须 > 500
        #expect(n2 == 501)
        try mkItem(id: "b", ingestedAtNs: n2).insert(conn)
        let n3 = try DuoPasteCore.Database.nextIngestNs(conn, now: 200)  // now 倒退 → 仍单增
        #expect(n3 == 502)
        try mkItem(id: "c", ingestedAtNs: n3).insert(conn)
        let n4 = try DuoPasteCore.Database.nextIngestNs(conn, now: 10_000)  // now 大幅前跃 → 跟上
        #expect(n4 == 10_000)
    }
}

@Test func sinceHasMoreTrueOnExactLimit() throws {
    // rows.count == limit → 标 hasMore=true（即使后面其实没东西，也只代表"再问一次以确认"）
    let db = try makeDB()
    try insert(db, [
        mkItem(id: "a", ingestedAtNs: 1),
        mkItem(id: "b", ingestedAtNs: 2),
    ])
    let p = try SinceAPI(database: db).fetch(SinceQuery(limit: 2))
    #expect(p.items.count == 2)
    #expect(p.hasMore == true)
}

import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

private typealias DuoDB = DuoPasteCore.Database

/// 覆盖 (pinned DESC, prefix DESC, captured_at_ns DESC) 排序契约的回归测试。
/// 不写这些断言，prefix-boost 被回退也能让旧的"按时间倒序"测试继续通过——
/// 这就是 review 提出来要补的盲区。
private func makeDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-prefix-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func insertOwn(
    _ db: DuoDB,
    id: String,
    capturedAtNs: Int64,
    text: String,
    pinned: Bool = false
) throws {
    let it = Item(
        id: id,
        originDevice: "self",
        capturedAtNs: capturedAtNs,
        kind: .text,
        sourceAppName: "T",
        preview: text,
        textFull: text,
        pinned: pinned
    )
    try db.pool.write { conn in try it.insert(conn) }
}

/// v7 合表后 peer 行直接落 item 表（origin != self，PullWorker 写时强制 push_state='acked'）。
/// 名字保留 `insertMirror` 让测试语义可读，实际写 item 表。
private func insertMirror(
    _ db: DuoDB,
    id: String,
    capturedAtNs: Int64,
    text: String,
    pinned: Bool = false
) throws {
    let it = Item(
        id: id,
        originDevice: "primary",
        capturedAtNs: capturedAtNs,
        ingestedAtNs: capturedAtNs,
        kind: .text,
        sourceAppName: "T",
        preview: text,
        textFull: text,
        pinned: pinned
    )
    try db.pool.write { conn in try it.insert(conn) }
}

private func nowNs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000_000)
}

@Test func prefixHitWinsOverNewerNonPrefixInSingleTable() throws {
    // older prefix match 应排到 newer non-prefix match 前面，纯时间倒序会反过来
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "older-prefix",
                  capturedAtNs: now - 60_000_000_000,   // 60s ago
                  text: "git status output")
    try insertOwn(db, id: "newer-noprefix",
                  capturedAtNs: now - 30_000_000_000,   // 30s ago, 更新
                  text: "the git command was nice")     // git 不在起始位置
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(text: "git", limit: 10))
    #expect(hits.map(\.0.id) == ["older-prefix", "newer-noprefix"])
}

@Test func pinnedAlwaysBeatsPrefixBoost() throws {
    // pinned 优先级 > prefix。一个 pinned non-prefix + 一个 unpinned prefix 同时存在时，
    // pinned 必须置顶。避免把 prefix-boost 误升到 pinned 之上
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "pinned-noprefix",
                  capturedAtNs: now - 90_000_000_000,
                  text: "see git inside",
                  pinned: true)
    try insertOwn(db, id: "unpinned-prefix",
                  capturedAtNs: now - 30_000_000_000,
                  text: "git status")
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(text: "git", limit: 10))
    #expect(hits.map(\.0.id) == ["pinned-noprefix", "unpinned-prefix"])
}

@Test func prefixOutside24hWindowGetsNoBoost() throws {
    // 24h 之外的 prefix 不享受 boost。两天前 prefix-match 应被 1h 前 non-prefix-match 反超，
    // 退化成纯时间倒序——剪贴板心智是"搜=找最近用过的"，不希望陈年起头匹配翻上来
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "old-prefix",
                  capturedAtNs: now - 48 * 3600 * 1_000_000_000,   // 48h ago, 出窗
                  text: "git ancient note")
    try insertOwn(db, id: "recent-noprefix",
                  capturedAtNs: now - 3600 * 1_000_000_000,         // 1h ago, 窗内
                  text: "look the git is here")
    let hits = try SearchAPI(database: db).searchHits(SearchQuery(text: "git", limit: 10))
    // recent-noprefix 排前：prefix-boost 对 old-prefix 失效，纯时间倒序
    #expect(hits.map(\.0.id) == ["recent-noprefix", "old-prefix"])
}

@Test func unionPrefixBoostMatchesSingleTableOrdering() throws {
    // 跨表 union 排序必须复现单表 fetchHits 的 prefix 优先级。
    // own 表 prefix-match 较老 + mirror 表 non-prefix 较新 → prefix 仍应胜出。
    // 反例：如果 fetchUnion 的 Swift dedup 排序漏掉 prefix-score 步骤，时间更新的 mirror 会赢
    let db = try makeDB()
    let now = nowNs()
    try insertOwn(db, id: "own-prefix",
                  capturedAtNs: now - 30 * 60 * 1_000_000_000,    // 30min ago
                  text: "git diff main")
    try insertMirror(db, id: "mir-noprefix",
                     capturedAtNs: now - 15 * 60 * 1_000_000_000, // 15min ago, 更新
                     text: "tracking git issues")
    let hits = try SearchAPI(database: db).searchUnion(SearchQuery(text: "git", limit: 10))
    #expect(hits.map(\.0.id) == ["own-prefix", "mir-noprefix"])
}

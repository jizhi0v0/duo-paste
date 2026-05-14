import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

/// PR 6 之后 SearchProvider 永远走本机 fold-aware 路径——SearchTransport / 远端 /search /
/// SearchProvider.Mode 的 .remoteOK / .remoteFallback / .localMirror 全删。
/// 这套测试覆盖剩下的两条不变量：
///  - 模式选择正确（.local 还是 .mesh(stalenessSec:)）
///  - 本机命中带 snippet（FTS 命中时填）
///  - 空 query 不带 snippet
///  - kindCounts 永远是 fold-aware 算出来的非空 dict（保证 chip 数字不消失）

private typealias DuoDB = DuoPasteCore.Database

private func makeDBWithItems(_ items: [Item]) throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-search-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try DuoDB(path: paths.mainDB)
    try db.pool.write { conn in
        for it in items { try it.insert(conn) }
    }
    return db
}

private func sampleItem(
    id: String = UUID().uuidString,
    origin: String = "test-device",
    text: String,
    kind: ItemKind = .text,
    capturedAtNs: Int64 = 1_700_000_000_000_000_000,
    pinned: Bool = false
) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedAtNs,
        kind: kind,
        sourceAppName: "Example",
        preview: text,
        textFull: text,
        pinned: pinned
    )
}

@Test func searchProviderLocalReturnsSnippets() async throws {
    let db = try makeDBWithItems([
        sampleItem(id: "s1", text: "this is a foo bar baz quux test"),
        sampleItem(id: "s2", text: "another row without keyword"),
    ])
    let provider = SearchProvider(local: SearchAPI(database: db))
    let outcome = try await provider.search(SearchQuery(text: "foo"))
    #expect(outcome.items.count == 1)
    let snippet = outcome.snippets["s1"]
    #expect(snippet != nil)
    #expect(snippet?.contains("\u{02}") == true)
    #expect(snippet?.contains("\u{03}") == true)
    #expect(snippet?.contains("foo") == true)
}

@Test func searchProviderEmptyQueryHasNoSnippets() async throws {
    let db = try makeDBWithItems([sampleItem(text: "anything")])
    let provider = SearchProvider(local: SearchAPI(database: db))
    let outcome = try await provider.search(SearchQuery())
    #expect(outcome.snippets.isEmpty)
}

@Test func searchProviderModeIsLocalWhenNoPeerPullYet() async throws {
    // 没有任何 peer 的 lastPullNs（standalone / 还没起 PullWorker / 首次启动未跑过 tick）
    // → mode 应当是 .local
    let db = try makeDBWithItems([sampleItem(text: "alpha"), sampleItem(text: "beta")])
    let provider = SearchProvider(
        local: SearchAPI(database: db),
        oldestPeerLastPullNs: { nil }
    )
    let outcome = try await provider.search(SearchQuery())
    #expect(outcome.mode == .local)
    #expect(outcome.items.count == 2)
}

@Test func searchProviderModeIsMeshWhenPeerPullActive() async throws {
    // 有 peer 已追平过 → mode 应当是 .mesh(stalenessSec:)，stalenessSec 是 (now-last)/1e9
    let db = try makeDBWithItems([sampleItem(text: "row")])
    let provider = SearchProvider(
        local: SearchAPI(database: db),
        oldestPeerLastPullNs: { 1_000_000_000 },
        nowNs: { 5_000_000_000 }
    )
    let outcome = try await provider.search(SearchQuery())
    if case .mesh(let staleness) = outcome.mode {
        #expect(staleness == 4)  // (5e9 - 1e9) / 1e9
    } else {
        Issue.record("expected .mesh, got \(outcome.mode)")
    }
}

@Test func searchProviderKindCountsAlwaysNonEmpty() async throws {
    // chip 数字契约：normalizeKindCounts 把所有 ItemKind 都补到 dict，缺的填 0。
    // 即使 0 命中也不能返回空 dict（空 dict 在 UI caller 端被解释为 "未知 → 隐藏"）。
    let db = try makeDBWithItems([
        sampleItem(text: "t1", kind: .text),
        sampleItem(text: "u1", kind: .url),
    ])
    let provider = SearchProvider(local: SearchAPI(database: db))
    let outcome = try await provider.search(SearchQuery())
    // 全部 ItemKind 都应有 entry
    for k in ItemKind.allCases {
        #expect(outcome.kindCounts[k] != nil, "kind \(k) 缺 entry")
    }
    #expect(outcome.kindCounts[.text] == 1)
    #expect(outcome.kindCounts[.url] == 1)
    #expect(outcome.kindCounts[.image] == 0)
}

@Test func searchProviderTotalCountMatchesFoldedRowCount() async throws {
    // PR 6 核心目标：count() 永远走 fold-aware，跨 origin 同 text 折成 1 条。
    // 这条直接钉死路径正确——两条 own + peer 同 text 应当 fold 后 total=1
    let db = try makeDBWithItems([
        sampleItem(id: "own", origin: "self", text: "shared content", capturedAtNs: 100),
        sampleItem(id: "peer", origin: "other", text: "shared content", capturedAtNs: 500),
        sampleItem(id: "uniq", origin: "self", text: "unique", capturedAtNs: 200),
    ])
    let provider = SearchProvider(local: SearchAPI(database: db))
    let outcome = try await provider.search(SearchQuery())
    #expect(outcome.totalCount == 2, "fold 后 shared content 折成 1 条 + unique 一条 = 2")
    #expect(outcome.items.count == 2)
}

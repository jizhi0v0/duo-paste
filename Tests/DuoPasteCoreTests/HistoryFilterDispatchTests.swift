import Testing
import Foundation
@testable import DuoPasteCore

/// 覆盖 `HistoryFilterDispatch.dispatch` 的四条分支契约——iOS `HistoryStore.filtered` 的
/// 核心 dispatch 逻辑. 不钉这个测试,下次 PR 把 fold / sort / qualifier filter 三者顺序
/// 改错也能编译过 + UI 看不出来(在某些 query 组合下行为巧合一致);本 suite 是 minimum 守门:
///
/// **Branch 1**: 空 query + 空 qualifier → 全列表 fold + iOS list order
/// **Branch 2**: 空 query + 有 qualifier → items.filter(qualifier) + fold + sort
/// **Branch 3**: 命中 cached server (`cache.q == query`) → server items.filter(qualifier),
///              **不再 fold 不再 sort**(保留 server prefix24h boost)
/// **Branch 4**: query 非空 + 无 cached server(或 q 不匹配)→ contains fallback + qualifier + fold + sort
///
/// 配合 `ItemFoldTests` (fold 契约) + `QueryQualifierMatchesTests` (qualifier 契约) 三角覆盖.
@Suite("HistoryFilterDispatch (4 branches)")
struct HistoryFilterDispatchTests {

    private func makeText(
        id: String,
        origin: String = "self",
        capturedAtNs: Int64,
        text: String,
        pinned: Bool = false
    ) -> Item {
        Item(
            id: id,
            originDevice: origin,
            capturedAtNs: capturedAtNs,
            kind: .text,
            preview: text,
            textFull: text,
            pinned: pinned
        )
    }

    private func makeImage(
        id: String,
        origin: String = "self",
        capturedAtNs: Int64,
        sha: String,
        pinned: Bool = false
    ) -> Item {
        Item(
            id: id,
            originDevice: origin,
            capturedAtNs: capturedAtNs,
            kind: .image,
            blobSha256: sha,
            pinned: pinned
        )
    }

    private func makeFile(
        id: String,
        origin: String = "self",
        capturedAtNs: Int64,
        mime: String,
        textFull: String? = nil,
        pinned: Bool = false
    ) -> Item {
        Item(
            id: id,
            originDevice: origin,
            capturedAtNs: capturedAtNs,
            kind: .file,
            textFull: textFull,
            blobMime: mime,
            pinned: pinned
        )
    }

    // MARK: - Branch 1: 空 query + 空 qualifier → fold + iOS list order

    @Test("Branch 1: 空 query + 空 qualifier → fold + (pinned DESC, ns DESC)")
    func branch1_emptyQueryEmptyQualifier_foldsAndSorts() {
        // 跨 origin 同 text → 折一条
        let a = makeText(id: "a", origin: "self", capturedAtNs: 100, text: "shared")
        let b = makeText(id: "b", origin: "peer", capturedAtNs: 500, text: "shared")
        // 不同 text + pinned 老的应排在前(pinned > 时间)
        let c = makeText(id: "c", origin: "self", capturedAtNs: 200, text: "other", pinned: true)
        let d = makeText(id: "d", origin: "self", capturedAtNs: 999, text: "another")

        let out = HistoryFilterDispatch.dispatch(
            items: [a, b, c, d],
            query: "",
            lastServerSearch: nil,
            qualifiers: []
        )

        // 期望:c(pinned) → b(ns=500 fold winner) → d(ns=999 但未 pin,b 是 fold winner ns=500)
        // 排序:pinned 在前 → 同 unpinned 按 ns DESC: d(999) > b(500)
        #expect(out.count == 3, "shared 那对折一条 + 'other' + 'another' = 3")
        #expect(out[0].id == "c", "pinned 永远在前")
        #expect(out[1].id == "d", "unpinned 按 ns DESC: d(999) > b(500)")
        #expect(out[2].id == "b", "b 是 shared fold winner, ns=500")
    }

    @Test("Branch 1: tombstone 不进结果")
    func branch1_tombstoneFiltered() {
        var t = makeText(id: "deleted", origin: "self", capturedAtNs: 999, text: "gone")
        t.deletedAtNs = 1000
        let alive = makeText(id: "alive", origin: "self", capturedAtNs: 100, text: "stays")

        let out = HistoryFilterDispatch.dispatch(
            items: [t, alive],
            query: "",
            lastServerSearch: nil,
            qualifiers: []
        )
        #expect(out.count == 1)
        #expect(out.first?.id == "alive")
    }

    // MARK: - Branch 2: 空 query + 有 qualifier → filter qualifier 后 fold + sort

    @Test("Branch 2: 空 query + qualifier 过 .kind(.url)")
    func branch2_emptyQueryWithKindQualifier() {
        let url = Item(id: "u", originDevice: "self", capturedAtNs: 200, kind: .url, textFull: "https://example.com")
        let text = makeText(id: "t", origin: "self", capturedAtNs: 100, text: "plain text")
        let img = makeImage(id: "i", capturedAtNs: 300, sha: "abc")

        let out = HistoryFilterDispatch.dispatch(
            items: [url, text, img],
            query: "",
            lastServerSearch: nil,
            qualifiers: [.kind(.url)]
        )
        #expect(out.count == 1)
        #expect(out.first?.id == "u")
    }

    @Test("Branch 2: 空 query + imageMerged → image kind + imageFile subkind 都进")
    func branch2_emptyQueryImageMerged() {
        let native = makeImage(id: "native", capturedAtNs: 100, sha: "n1")
        let png = makeFile(id: "png", capturedAtNs: 200, mime: "image/png")
        let txt = makeText(id: "txt", capturedAtNs: 300, text: "not image")

        let out = HistoryFilterDispatch.dispatch(
            items: [native, png, txt],
            query: "",
            lastServerSearch: nil,
            qualifiers: [.imageMerged]
        )
        #expect(out.count == 2)
        let ids = Set(out.map(\.id))
        #expect(ids == ["native", "png"])
        // 排序:都 unpinned → ns DESC: png(200) > native(100)
        #expect(out[0].id == "png")
        #expect(out[1].id == "native")
    }

    @Test("Branch 2: qualifier filter 在 fold 之前——跨 origin 同 text 仍折一条")
    func branch2_filterBeforeFoldKeepsCrossOriginDedup() {
        // 同 text 跨 origin 两条都过 qualifier 过滤,fold 后只剩一条
        let a = makeText(id: "a", origin: "self", capturedAtNs: 100, text: "shared")
        let b = makeText(id: "b", origin: "peer", capturedAtNs: 500, text: "shared")
        let unrelated = makeText(id: "x", origin: "self", capturedAtNs: 300, text: "other")

        let out = HistoryFilterDispatch.dispatch(
            items: [a, b, unrelated],
            query: "",
            lastServerSearch: nil,
            qualifiers: [.kind(.text)]
        )
        // 三条都是 text kind,fold 把 a/b 折一条 → 共 2 条
        #expect(out.count == 2)
        // 排序:都 unpinned → ns DESC: b(500) > unrelated(300)
        #expect(out[0].id == "b")
        #expect(out[1].id == "x")
    }

    // MARK: - Branch 3: cached server 命中 → server filter, 不 fold 不 sort

    @Test("Branch 3: cache.q == query + 空 qualifier → 直接返 cache.items")
    func branch3_cacheHitEmptyQualifierReturnsServerItemsAsIs() {
        // server 已 fold + 已 sort(含 prefix24h boost),客户端直接复用顺序.
        // 故意把 cache 顺序设成"ns 老的在前"——若客户端误 re-sort 会按 ns DESC 把新的放前
        let serverFirst = makeText(id: "boost-old", origin: "self", capturedAtNs: 100, text: "hello world")
        let serverSecond = makeText(id: "ns-new", origin: "self", capturedAtNs: 999, text: "world hello")
        let cache = HistoryFilterDispatch.ServerSearchContext(
            q: "hello",
            items: [serverFirst, serverSecond]
        )
        // items 列表故意跟 cache 不一样——证明走 cache 路径而非本地
        let items = [makeText(id: "local-only", origin: "self", capturedAtNs: 200, text: "hello local")]

        let out = HistoryFilterDispatch.dispatch(
            items: items,
            query: "hello",
            lastServerSearch: cache,
            qualifiers: []
        )
        #expect(out.count == 2)
        #expect(out[0].id == "boost-old", "保留 server 顺序——不能按 ns DESC re-sort")
        #expect(out[1].id == "ns-new")
    }

    @Test("Branch 3: cache.q == query + 有 qualifier → 仅 client-side filter,保留 server 顺序")
    func branch3_cacheHitWithQualifierPreservesServerOrder() {
        // server 返三条:前两条 url,一条 text. qualifier=.kind(.url) → 仅前两条,顺序不变
        let urlA = Item(id: "urlA", originDevice: "self", capturedAtNs: 100, kind: .url, preview: "https://a.com", textFull: "https://a.com")
        let urlB = Item(id: "urlB", originDevice: "self", capturedAtNs: 500, kind: .url, preview: "https://b.com", textFull: "https://b.com")
        let txt = makeText(id: "txt", origin: "self", capturedAtNs: 999, text: "just text containing query")
        let cache = HistoryFilterDispatch.ServerSearchContext(
            q: "query",
            items: [urlA, urlB, txt]  // server 顺序:urlA 前,urlB 中,txt 后
        )

        let out = HistoryFilterDispatch.dispatch(
            items: [],
            query: "query",
            lastServerSearch: cache,
            qualifiers: [.kind(.url)]
        )
        #expect(out.count == 2)
        #expect(out[0].id == "urlA", "保留 server 顺序——urlA 在 cache 中排前")
        #expect(out[1].id == "urlB")
    }

    @Test("Branch 3: cache.q != query → 不命中,走 contains fallback(Branch 4)")
    func branch3_staleCacheFallsThroughToBranch4() {
        // cache 里装的是旧 query 的结果, 当前 query 已改 → 走本地 contains fallback
        let staleItem = makeText(id: "stale", origin: "self", capturedAtNs: 999, text: "old result")
        let cache = HistoryFilterDispatch.ServerSearchContext(q: "old", items: [staleItem])
        let local = makeText(id: "local", origin: "self", capturedAtNs: 100, text: "fresh new content")

        let out = HistoryFilterDispatch.dispatch(
            items: [local],
            query: "fresh",
            lastServerSearch: cache,
            qualifiers: []
        )
        // 走 contains fallback —— local 命中 "fresh"
        #expect(out.count == 1)
        #expect(out.first?.id == "local")
    }

    // MARK: - Branch 4: query 非空 + 无 cached server → contains fallback + qualifier + fold + sort

    @Test("Branch 4: contains 走 preview / textFull / extractedText 三列")
    func branch4_containsAcrossThreeColumns() {
        let inPreview = Item(id: "prev", originDevice: "self", capturedAtNs: 100, kind: .text, preview: "MAGIC token", textFull: "other")
        let inTextFull = Item(id: "tf", originDevice: "self", capturedAtNs: 200, kind: .text, preview: "x", textFull: "contains MAGIC inside")
        let inExtracted = Item(id: "ex", originDevice: "self", capturedAtNs: 300, kind: .image, preview: "x", textFull: nil, extractedText: "OCR result has MAGIC")
        let noMatch = makeText(id: "no", origin: "self", capturedAtNs: 999, text: "nothing relevant")

        let out = HistoryFilterDispatch.dispatch(
            items: [inPreview, inTextFull, inExtracted, noMatch],
            query: "magic",
            lastServerSearch: nil,
            qualifiers: []
        )
        // 三个命中,排序 ns DESC: ex(300) > tf(200) > prev(100)
        #expect(out.count == 3)
        #expect(out[0].id == "ex")
        #expect(out[1].id == "tf")
        #expect(out[2].id == "prev")
    }

    @Test("Branch 4: contains 大小写不敏感")
    func branch4_containsCaseInsensitive() {
        let upper = makeText(id: "u", origin: "self", capturedAtNs: 100, text: "Hello WORLD")
        let out = HistoryFilterDispatch.dispatch(
            items: [upper],
            query: "world",
            lastServerSearch: nil,
            qualifiers: []
        )
        #expect(out.count == 1)
        #expect(out.first?.id == "u")
    }

    @Test("Branch 4: contains + qualifier 交集 → 都命中才进结果")
    func branch4_containsAndQualifierIntersect() {
        // 两条 url 都含 query 串,但 qualifier=.kind(.text) 只让非 url 过——结果应空
        let urlA = Item(id: "ua", originDevice: "self", capturedAtNs: 100, kind: .url, textFull: "https://example.com/hello")
        let urlB = Item(id: "ub", originDevice: "self", capturedAtNs: 200, kind: .url, textFull: "https://example.com/hello-2")
        let txt = makeText(id: "txt", origin: "self", capturedAtNs: 300, text: "hello text")

        let out = HistoryFilterDispatch.dispatch(
            items: [urlA, urlB, txt],
            query: "hello",
            lastServerSearch: nil,
            qualifiers: [.kind(.text)]
        )
        #expect(out.count == 1)
        #expect(out.first?.id == "txt", "qualifier=.kind(.text) 把 url 都剔掉")
    }

    @Test("Branch 4: 跨 origin 同 text 在 contains fallback 后仍 fold 一条")
    func branch4_containsThenFoldDedupesCrossOrigin() {
        let a = makeText(id: "a", origin: "self", capturedAtNs: 100, text: "duplicate content")
        let b = makeText(id: "b", origin: "peer", capturedAtNs: 500, text: "duplicate content")
        let other = makeText(id: "o", origin: "self", capturedAtNs: 300, text: "different content")

        let out = HistoryFilterDispatch.dispatch(
            items: [a, b, other],
            query: "content",
            lastServerSearch: nil,
            qualifiers: []
        )
        // 三条都含 "content",fold 把 a/b 折一条 → 共 2
        #expect(out.count == 2)
        // 排序 ns DESC: b(500) > other(300)
        #expect(out[0].id == "b")
        #expect(out[1].id == "o")
    }

    // MARK: - 排序契约 (pinned > captured_at_ns DESC)

    @Test("iosListOrder: pinned 永远在前,同 pinned 按 ns DESC")
    func iosListOrderContract() {
        let oldPinned = makeText(id: "old-pinned", capturedAtNs: 100, text: "a", pinned: true)
        let newUnpinned = makeText(id: "new-unpin", capturedAtNs: 999, text: "b", pinned: false)
        let newPinned = makeText(id: "new-pinned", capturedAtNs: 500, text: "c", pinned: true)
        let oldUnpinned = makeText(id: "old-unpin", capturedAtNs: 200, text: "d", pinned: false)

        let sorted = [oldPinned, newUnpinned, newPinned, oldUnpinned].sorted(by: HistoryFilterDispatch.iosListOrder)
        #expect(sorted.map(\.id) == ["new-pinned", "old-pinned", "new-unpin", "old-unpin"])
    }

    // MARK: - 边界:items 空集合

    @Test("空 items + 空 query + 空 qualifier → 空结果")
    func emptyEverything() {
        let out = HistoryFilterDispatch.dispatch(
            items: [],
            query: "",
            lastServerSearch: nil,
            qualifiers: []
        )
        #expect(out.isEmpty)
    }

    @Test("空 items + 非空 query + nil cache → Branch 4 走过 contains → 空结果")
    func branch4_emptyItems() {
        let out = HistoryFilterDispatch.dispatch(
            items: [],
            query: "anything",
            lastServerSearch: nil,
            qualifiers: []
        )
        #expect(out.isEmpty)
    }
}

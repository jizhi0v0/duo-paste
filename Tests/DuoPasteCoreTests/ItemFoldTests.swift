import Testing
import Foundation
@testable import DuoPasteCore

/// 覆盖 `Item.foldByTextFull` 的契约——文本永久 dedup + 跨设备 blob 副本 fold。
///
/// **不钉这个测试,下次 PR 把 winner 选择 / pinned 聚合 / blob 行参与判断改错也能
/// 编译过,Mac 端 `SearchFoldV7Tests` 走 SQL + searchHits 路径,iOS 端无单测——本 suite
/// 是核心 fold 行为的 minimum 守门**:winner / pinned OR / blob 跨-origin 时窗 /
/// 空 text_full 不参与 / nil text_full 落 nonText 桶不丢. iOS HistoryStore.filtered
/// 与 Mac Search.fetchHitsFolded 必须共用本契约,任何分叉是 bug.
@Suite("Item.foldByTextFull (cross-origin text dedup)")
struct ItemFoldTests {

    private func makeText(
        id: String,
        origin: String,
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
        origin: String,
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

    private func makeImageFile(
        id: String,
        origin: String,
        capturedAtNs: Int64,
        sha: String,
        path: String,
        pinned: Bool = false
    ) -> Item {
        Item(
            id: id,
            originDevice: origin,
            capturedAtNs: capturedAtNs,
            kind: .file,
            preview: URL(fileURLWithPath: path).lastPathComponent,
            textFull: path,
            blobSha256: sha,
            blobMime: "image/png",
            pinned: pinned
        )
    }

    @Test("跨 origin 同 text_full fold 一条")
    func crossOriginSameTextFoldsToOne() {
        let a = makeText(id: "own", origin: "self", capturedAtNs: 100, text: "duplicate")
        let b = makeText(id: "peer", origin: "peer", capturedAtNs: 500, text: "duplicate")
        let folded = Item.foldByTextFull([a, b])
        #expect(folded.count == 1)
        #expect(folded.first?.id == "peer", "winner 必须是 max capturedAtNs 那条")
    }

    @Test("winner = max(capturedAtNs)")
    func winnerIsMaxCapturedAtNs() {
        let a = makeText(id: "newest", origin: "self", capturedAtNs: 999, text: "x")
        let b = makeText(id: "old", origin: "peer", capturedAtNs: 100, text: "x")
        let c = makeText(id: "mid", origin: "self", capturedAtNs: 500, text: "x")
        let folded = Item.foldByTextFull([a, b, c])
        #expect(folded.count == 1)
        #expect(folded.first?.id == "newest")
        #expect(folded.first?.capturedAtNs == 999)
    }

    @Test("pinned OR 聚合——任一参与行 pinned → winner.pinned=true")
    func pinnedIsOREvenIfWinnerUnpinned() {
        let pinnedOlder = makeText(id: "older-pinned", origin: "self", capturedAtNs: 100, text: "shared", pinned: true)
        let unpinnedNewer = makeText(id: "newer-unpinned", origin: "peer", capturedAtNs: 500, text: "shared", pinned: false)
        let folded = Item.foldByTextFull([pinnedOlder, unpinnedNewer])
        #expect(folded.count == 1)
        #expect(folded.first?.id == "newer-unpinned", "winner 还是 max ns")
        #expect(folded.first?.pinned == true, "pinned 必须 OR 聚合,不能丢")
    }

    @Test("同 origin 的同 sha blob 不 fold——主动多次复制保留时间线")
    func imageSameShaDoesNotFold() {
        let a = makeImage(id: "img1", origin: "self", capturedAtNs: 100, sha: "abcd")
        let b = makeImage(id: "img2", origin: "self", capturedAtNs: 500, sha: "abcd")
        let folded = Item.foldByTextFull([a, b])
        #expect(folded.count == 2, "blob 行必须保留两份")
    }

    @Test("同 origin 同 SHA 的图片文件与裸图片永久 fold，最新表示获胜")
    func sameOriginImageFileAndImageFoldAcrossLongGap() {
        let sha = String(repeating: "f", count: 64)
        let file = makeImageFile(
            id: "file-first",
            origin: "self",
            capturedAtNs: 100,
            sha: sha,
            path: "/tmp/CleanShot.png",
            pinned: true
        )
        let image = makeImage(
            id: "image-later",
            origin: "self",
            capturedAtNs: 10_000_000_000_000,
            sha: sha
        )

        let folded = Item.foldByTextFull([file, image])

        #expect(folded.count == 1)
        #expect(folded[0].id == "image-later", "最新一次复制决定 file/image 粘贴语义")
        #expect(folded[0].kind == .image)
        #expect(folded[0].pinned == true, "同内容卡片的置顶状态做 OR")
    }

    @Test("跨 origin 近时间同 sha fold，保留原始文件名 + 最新排序时间")
    func nearbyCrossOriginBlobFolds() {
        let sha = String(repeating: "a", count: 64)
        let original = Item(
            id: "original",
            originDevice: "mac-a",
            capturedAtNs: 1_000_000_000,
            kind: .file,
            sourceAppName: "CleanShot X",
            preview: "CleanShot 2026-07-14 at 10.32.52@2x.png",
            textFull: "/original/CleanShot 2026-07-14 at 10.32.52@2x.png",
            blobSha256: sha
        )
        let continuityCopy = Item(
            id: "copy",
            originDevice: "mac-b",
            capturedAtNs: 8_000_000_000,
            kind: .file,
            sourceAppName: "Claude",
            preview: "mac_1783996376558.png",
            textFull: "/cache/mac_1783996376558.png",
            blobSha256: sha,
            pinned: true
        )

        let folded = Item.foldByTextFull([continuityCopy, original])
        #expect(folded.count == 1)
        #expect(folded[0].id == "original")
        #expect(folded[0].preview == original.preview)
        #expect(folded[0].textFull == original.textFull)
        #expect(folded[0].capturedAtNs == continuityCopy.capturedAtNs)
        #expect(folded[0].pinned == true)
    }

    @Test("跨 origin 同 sha 超过 15s 不 fold")
    func distantCrossOriginBlobStaysSeparate() {
        let a = makeImage(id: "a", origin: "mac-a", capturedAtNs: 0, sha: "same")
        let b = makeImage(
            id: "b",
            origin: "mac-b",
            capturedAtNs: Item.crossOriginBlobFoldWindowNs + 1,
            sha: "same"
        )
        #expect(Item.foldByTextFull([a, b]).count == 2)
    }

    @Test("paste bump captured_at 不拆开 UUIDv7 跨 origin blob fold")
    func capturedAtBumpDoesNotSplitBlobFold() {
        let firstID = UUIDv7.generate(timestampMs: 1_000).uuidString
        let copyID = UUIDv7.generate(timestampMs: 1_005).uuidString
        let bumped = makeImage(
            id: firstID,
            origin: "mac-a",
            capturedAtNs: 999_000_000_000,
            sha: "same"
        )
        let copy = makeImage(
            id: copyID,
            origin: "mac-b",
            capturedAtNs: 1_005_000_000,
            sha: "same"
        )
        let folded = Item.foldByTextFull([bumped, copy])
        #expect(folded.count == 1)
        #expect(folded[0].id == firstID)
        #expect(folded[0].capturedAtNs == bumped.capturedAtNs)
    }

    @Test("text_full 空串不参与 fold——不会把所有空文本折一条")
    func emptyTextFullDoesNotFold() {
        let a = Item(id: "a", originDevice: "self", capturedAtNs: 100, kind: .text, textFull: "")
        let b = Item(id: "b", originDevice: "peer", capturedAtNs: 500, kind: .text, textFull: "")
        let folded = Item.foldByTextFull([a, b])
        #expect(folded.count == 2, "空 text_full 落 nonText 桶")
    }

    @Test("text_full nil 不参与 fold——image/file blob 路径走这里")
    func nilTextFullDoesNotFold() {
        let a = Item(id: "a", originDevice: "self", capturedAtNs: 100, kind: .text, textFull: nil)
        let b = Item(id: "b", originDevice: "peer", capturedAtNs: 500, kind: .text, textFull: nil)
        let folded = Item.foldByTextFull([a, b])
        #expect(folded.count == 2)
    }

    @Test("不同 text_full 不 fold——byte-equal 才算同")
    func differentTextStaysSeparate() {
        let a = makeText(id: "a", origin: "self", capturedAtNs: 100, text: "hello")
        let b = makeText(id: "b", origin: "self", capturedAtNs: 200, text: "hello ")  // 多个尾部空格
        let folded = Item.foldByTextFull([a, b])
        #expect(folded.count == 2, "trailing whitespace 算不同——契约是 byte-equal")
    }

    @Test("大小写敏感")
    func caseSensitiveKey() {
        let a = makeText(id: "lower", origin: "self", capturedAtNs: 100, text: "Hello")
        let b = makeText(id: "upper", origin: "peer", capturedAtNs: 200, text: "hello")
        let folded = Item.foldByTextFull([a, b])
        #expect(folded.count == 2)
    }

    @Test("空入参返回空")
    func emptyInputReturnsEmpty() {
        #expect(Item.foldByTextFull([]).isEmpty)
    }

    @Test("单条直通")
    func singleItemPassthrough() {
        let it = makeText(id: "x", origin: "self", capturedAtNs: 100, text: "single")
        let folded = Item.foldByTextFull([it])
        #expect(folded.count == 1)
        #expect(folded.first?.id == "x")
    }

    @Test("混合:text fold + image 保留 + 不同 text 各保留")
    func mixedScenario() {
        let textA1 = makeText(id: "ta1", origin: "self", capturedAtNs: 100, text: "alpha")
        let textA2 = makeText(id: "ta2", origin: "peer", capturedAtNs: 500, text: "alpha")
        let textB = makeText(id: "tb", origin: "self", capturedAtNs: 200, text: "beta")
        let imgA = makeImage(id: "ia", origin: "self", capturedAtNs: 300, sha: "sha1")
        let imgB = makeImage(id: "ib", origin: "self", capturedAtNs: 400, sha: "sha1")
        let folded = Item.foldByTextFull([textA1, textA2, textB, imgA, imgB])
        // alpha 折一条(winner ta2) + beta 一条 + 两张图各一条 = 4
        #expect(folded.count == 4)
        let ids = Set(folded.map(\.id))
        #expect(ids.contains("ta2"))
        #expect(!ids.contains("ta1"))
        #expect(ids.contains("tb"))
        #expect(ids.contains("ia"))
        #expect(ids.contains("ib"))
    }

    @Test("多 origin 链 + pinned 散落各处——pinned 全 OR 聚到 winner")
    func pinnedAggregatesAcrossMultipleOrigins() {
        let a = makeText(id: "a", origin: "self", capturedAtNs: 100, text: "x", pinned: false)
        let b = makeText(id: "b", origin: "peer1", capturedAtNs: 200, text: "x", pinned: true)
        let c = makeText(id: "c", origin: "peer2", capturedAtNs: 300, text: "x", pinned: false)
        let d = makeText(id: "d", origin: "peer3", capturedAtNs: 400, text: "x", pinned: false)
        let folded = Item.foldByTextFull([a, b, c, d])
        #expect(folded.count == 1)
        #expect(folded.first?.id == "d", "winner 是 max ns")
        #expect(folded.first?.pinned == true, "中间链中有一条 pinned → winner 继承")
    }

    @Test("同 ns 不爆——任选一条作 winner,pinned OR 不丢")
    func sameNsDoesNotCrash() {
        let a = makeText(id: "a", origin: "self", capturedAtNs: 100, text: "x", pinned: true)
        let b = makeText(id: "b", origin: "peer", capturedAtNs: 100, text: "x", pinned: false)
        let folded = Item.foldByTextFull([a, b])
        #expect(folded.count == 1)
        #expect(folded.first?.pinned == true, "同 ns 时 pinned OR 依然成立")
    }

    @Test("text + url + rtf + html kind 都按 text_full byte-equal fold")
    func allTextlikeKindsFold() {
        let t = Item(id: "t", originDevice: "self", capturedAtNs: 100, kind: .text, textFull: "https://example.com")
        let u = Item(id: "u", originDevice: "peer", capturedAtNs: 200, kind: .url, textFull: "https://example.com")
        let folded = Item.foldByTextFull([t, u])
        #expect(folded.count == 1, "kind 不参与 fold key——只看 text_full byte-equal")
        #expect(folded.first?.id == "u", "winner = max ns")
    }

    /// **Tombstone 防御契约**——subagent review 找到的陷阱:
    /// `softDelete` 不动 textFull / capturedAtNs (Database.swift:790)，wire 上 tombstone
    /// 仍带原 textFull + 原 capturedAtNs。若 fold 不 skip:
    /// - tombstone capturedAtNs 大于活的 sibling → tombstone 当 winner
    /// - UI 渲染 winner = 被删除的内容,用户看到"已删的还在"
    /// 必须 fold 内部 skip,不能信"caller 已 pre-filter"。
    @Test("tombstone skip——即使 capturedAtNs 大于活 sibling 也不当 winner")
    func tombstoneNeverWinsEvenWhenNewer() {
        let alive = makeText(id: "alive", origin: "self", capturedAtNs: 100, text: "shared")
        var tombstone = makeText(id: "deleted-newer", origin: "peer", capturedAtNs: 999, text: "shared")
        tombstone.deletedAtNs = 1000  // 软删
        let folded = Item.foldByTextFull([alive, tombstone])
        #expect(folded.count == 1, "tombstone skip 后只剩 alive 一条")
        #expect(folded.first?.id == "alive", "winner 不能是 tombstone")
    }

    @Test("纯 tombstone 输入返回空")
    func allTombstonesReturnEmpty() {
        var a = makeText(id: "a", origin: "self", capturedAtNs: 100, text: "x")
        a.deletedAtNs = 200
        var b = Item(id: "b", originDevice: "self", capturedAtNs: 300, kind: .image, blobSha256: "abc")
        b.deletedAtNs = 400
        let folded = Item.foldByTextFull([a, b])
        #expect(folded.isEmpty, "tombstone(text) + tombstone(image) 都 skip → 空")
    }

    @Test("tombstone 的 pinned 不参与 OR 聚合——已删 = 不存在")
    func tombstonePinnedDoesNotPropagate() {
        let alive = makeText(id: "alive", origin: "self", capturedAtNs: 100, text: "x", pinned: false)
        var deletedPinned = makeText(id: "deleted", origin: "peer", capturedAtNs: 50, text: "x", pinned: true)
        deletedPinned.deletedAtNs = 200
        let folded = Item.foldByTextFull([alive, deletedPinned])
        #expect(folded.count == 1)
        #expect(folded.first?.pinned == false, "tombstone 的 pinned=true 不能传染到活 winner")
    }

    /// **Sibling-resurrection 契约** (C2 — subagent 找到的 UX 行为)：
    /// 用户在 iOS 删折叠卡 winner 行（id=B 的 peer 行）→ HistoryStore.removeOptimistic
    /// 只移 B → 下一次 filtered fold 看到的 input 只剩 A → A 自动顶上来成新 winner
    /// → UI 显 "删了又出现一张同文本卡(不同 id)"。
    /// 这是 Mac fold 同行为(都基于物理行),不修——但钉死在 fold 层确保未来不变.
    @Test("移除 winner 后,sibling 自动成新 winner——UI 看到的'删了又出现'机制")
    func siblingResurrectsAsWinnerAfterRemovingPriorWinner() {
        let a = makeText(id: "a-old", origin: "self", capturedAtNs: 100, text: "same")
        let b = makeText(id: "b-new", origin: "peer", capturedAtNs: 500, text: "same")
        // 第一轮:b 是 winner
        let round1 = Item.foldByTextFull([a, b])
        #expect(round1.count == 1)
        #expect(round1.first?.id == "b-new")
        // caller 物理删 b 后再 fold(模拟 iOS HistoryStore.removeOptimistic 后 filtered 重算)
        let round2 = Item.foldByTextFull([a])
        #expect(round2.count == 1)
        #expect(round2.first?.id == "a-old", "sibling a 自动成新 winner——UI 显新 id 的同文本卡")
    }

    /// **输入顺序无关性** (N4 — subagent nit)：fold 基于 dict,winner 选择只看 ns 不看
    /// 入参顺序. 钉死防未来"改成 ordered fold(按输入顺序优先)"静默通过.
    @Test("输入顺序不影响 fold 结果")
    func inputOrderDoesNotAffectFold() {
        let older = makeText(id: "older", origin: "self", capturedAtNs: 100, text: "shared", pinned: true)
        let newer = makeText(id: "newer", origin: "peer", capturedAtNs: 500, text: "shared", pinned: false)
        let abThenBa = Item.foldByTextFull([older, newer])
        let baThenAb = Item.foldByTextFull([newer, older])
        #expect(abThenBa.count == 1)
        #expect(baThenAb.count == 1)
        #expect(abThenBa.first?.id == "newer")
        #expect(baThenAb.first?.id == "newer", "winner 永远是 max ns,不看入参顺序")
        #expect(abThenBa.first?.pinned == true)
        #expect(baThenAb.first?.pinned == true, "pinned OR 聚合也不看入参顺序")
    }
}

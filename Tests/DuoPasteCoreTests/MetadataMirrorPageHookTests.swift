import Testing
import Foundation
import GRDB
@testable import DuoPasteCore

/// `MetadataMirrorStore.synchronize` 的两条 client 契约：
///
/// 1. **`onPageApplied` 每页回调一次，且在 writer transaction 提交之后**。
///    iOS 的 `progress` 回调只带计数器，不带行；R2.1 把 item 所有权搬进 SQLite mirror 之后，
///    `HistoryStore.merge(_:)`（连同它承担的乐观删除 / pin-pending 对账）失去了调用方，
///    整条"删除未送达"检测链变成死代码——卡片一直假装已删、橙色 banner 永不出现、
///    重启后条目无声复活。本 hook 是把那半边对账接回生产路径的唯一入口。
/// 2. **取消之后不再发布 progress**。否则"取消时恰好有一页刚 commit"会把 UI 状态推回
///    「正在同步」并永久卡死（`reloadSyncCheckpoint` 的 guard 会短路后续所有前台恢复）。

private func makeStore() throws -> (MetadataMirrorStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-mirror-hook-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (try MetadataMirrorStore(path: dir.appendingPathComponent("mirror.sqlite")), dir)
}

private func item(_ id: String, ns: Int64, deleted: Int64? = nil) -> Item {
    Item(
        id: id,
        originDevice: "mac-a",
        capturedAtNs: ns,
        ingestedAtNs: ns,
        kind: .text,
        preview: id,
        textFull: id,
        deletedAtNs: deleted
    )
}

private func page(_ items: [Item], hasMore: Bool, total: Int) -> SincePageWire {
    SincePageWire(
        ok: true,
        count: items.count,
        items: items,
        nextCursor: SinceCursor(ingestedAtNs: items.last?.ingestedAtNs ?? 0, id: items.last?.id ?? ""),
        hasMore: hasMore,
        totalCount: total,
        sourceDeviceID: "mac-a"
    )
}

private actor Recorder {
    private(set) var pages: [[String]] = []
    private(set) var visibleAtCallback: [Int] = []
    private(set) var progressPages: [Int] = []

    func recordPage(_ ids: [String], visible: Int) {
        pages.append(ids)
        visibleAtCallback.append(visible)
    }
    func recordProgress(_ pageNumber: Int) { progressPages.append(pageNumber) }
}

/// 串行发页。`fetchPage` 是 `@Sendable`，不能捕获可变 var。
private actor PageScript {
    private var remaining: [SincePageWire]
    init(_ pages: [SincePageWire]) { self.remaining = pages }
    func next() -> SincePageWire { remaining.removeFirst() }
}

@Test func onPageAppliedFiresPerPageAfterRowsAreCommitted() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = Recorder()

    let script = PageScript([
        page([item("a", ns: 10), item("b", ns: 20)], hasMore: true, total: 3),
        page([item("c", ns: 30)], hasMore: false, total: 3),
    ])

    _ = try await store.synchronize(
        pageLimit: 2,
        progress: { await recorder.recordProgress($0.pageNumber) },
        onPageApplied: { items in
            // 回调时行必须已经落库——client 据此清乐观状态才是安全的
            let visible = (try? store.totalItemCount()) ?? -1
            await recorder.recordPage(items.map(\.id), visible: visible)
        },
        fetchPage: { _, _ in await script.next() }
    )

    #expect(await recorder.pages == [["a", "b"], ["c"]])
    // 第一页回调时 2 行已提交，第二页回调时 3 行已提交
    #expect(await recorder.visibleAtCallback == [2, 3])
    #expect(await recorder.progressPages == [1, 2])
}

/// tombstone 也必须经过 hook —— iOS 靠它清 `optimisticallyDeletedIDs` / pin overlay。
@Test func onPageAppliedIncludesTombstones() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = Recorder()

    let only = page([item("a", ns: 10), item("b", ns: 20, deleted: 99)], hasMore: false, total: 2)
    _ = try await store.synchronize(
        onPageApplied: { items in
            await recorder.recordPage(
                items.map(\.id),
                visible: items.filter { $0.deletedAtNs != nil }.count
            )
        },
        fetchPage: { _, _ in only }
    )
    #expect(await recorder.pages == [["a", "b"]])
    #expect(await recorder.visibleAtCallback == [1], "tombstone 必须原样透传给 client 对账")
}

@Test func cancellationStopsProgressButKeepsCommittedPage() async throws {
    let (store, dir) = try makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = Recorder()

    let first = page([item("a", ns: 10)], hasMore: true, total: 5)
    let thrown = await Task { () -> String in
        do {
            _ = try await store.synchronize(
                progress: { await recorder.recordProgress($0.pageNumber) },
                onPageApplied: { _ in },
                fetchPage: { _, _ in
                    // 用户在这一页正在途中时点了「取消」
                    withUnsafeCurrentTask { $0?.cancel() }
                    return first
                }
            )
            return "no throw"
        } catch is CancellationError {
            return "CancellationError"
        } catch {
            return "\(type(of: error))"
        }
    }.value

    #expect(thrown == "CancellationError")
    #expect(
        await recorder.progressPages.isEmpty,
        "取消后仍发布 progress 会把 UI 推回 .syncing 并永久卡死"
    )
    // 已提交的页必须留下：取消保留 cursor 与行，「继续同步」从这里接着走
    #expect(try store.totalItemCount() == 1)
    #expect(try store.cursor() != .zero)
}

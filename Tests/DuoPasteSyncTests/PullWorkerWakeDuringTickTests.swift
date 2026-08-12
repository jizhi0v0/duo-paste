import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

/// `wake()` 落在 tick **执行期间**（而不是 sleep 期间）时必须仍然生效。
///
/// 现实时序：本轮 `/since` 已经发出 → 对端此刻才 commit 新行 → 广播 `cursor_advanced` →
/// `WSNotificationClient.onCursorAdvanced` 调 `worker.wake()`。这一刻 `currentSleep == nil`，
/// 只 cancel sleep 是空操作，通知被丢掉，新行要等满一个 `intervalSec` 才被拉到——
/// 违反 CLAUDE.md "WS 通知层让推送延迟 < 1s"。
///
/// 已有的 `MultiPeerPullWorkerTests` 只覆盖"sleep 期间 wake"，那条路径靠 cancel 就够了，
/// 所以这个缺口一直没被发现。
private func makeDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-wake-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func item(id: String, ns: Int64) -> Item {
    Item(
        id: id,
        originDevice: "peer-b",
        capturedAtNs: ns,
        ingestedAtNs: ns,
        kind: .text,
        sourceAppName: "Test",
        preview: id,
        textFull: id
    )
}

private func onePage(_ items: [Item]) -> SincePageWire {
    SincePageWire(
        ok: true,
        count: items.count,
        items: items,
        nextCursor: SinceCursor(ingestedAtNs: items.last?.ingestedAtNs ?? 0, id: items.last?.id ?? ""),
        hasMore: false
    )
}

/// 在**第一次** `/since` 处理期间调用 `worker.wake()`，精确模拟"对端在我们这轮请求发出
/// 之后才 commit"的时序。PullWorker 是 actor，tick 此刻正挂在这个 await 上，actor
/// 可重入让 `handleWake` 先跑到——正是生产里 WS 帧到达的样子。
private actor WakeDuringTickTransport: SinceTransport {
    private var worker: PullWorker?
    private var fetchCount = 0

    func attach(_ worker: PullWorker) { self.worker = worker }
    func fetchCallCount() -> Int { fetchCount }

    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        await self.next()
    }

    private func next() -> RemoteSinceResult {
        fetchCount += 1
        switch fetchCount {
        case 1:
            // 本轮拉到空——对端的新行还没 commit
            worker?.wake()
            return RemoteSinceResult(outcome: .ok(onePage([])))
        case 2:
            // 只有"wake 没被丢掉"时才会走到这里（intervalSec 设成 600s）
            return RemoteSinceResult(outcome: .ok(onePage([item(id: "late-row", ns: 100)])))
        default:
            return RemoteSinceResult(outcome: .ok(onePage([])))
        }
    }

    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        PrimaryHealthResult(outcome: .ok(deviceID: "peer-b", nowMs: 1_000, ponteHost: nil))
    }
}

@Test func wakeArrivingDuringTickStillSkipsTheIntervalSleep() async throws {
    let db = try makeDB()
    let transport = WakeDuringTickTransport()
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "self-mac",
        expectedPeerDeviceID: "peer-b",
        meshStatus: MeshStatus(),
        // 600s：测试期内绝不会自然到期。第二轮 tick 只可能来自被兑现的 wake
        config: PullWorker.Config(intervalSec: 600),
        nowNs: { 5_000 }
    )
    await transport.attach(worker)

    let baseline = await worker.completedTickCountForTesting()
    await worker.start()
    let reached = await worker.waitForCompletedTicksForTesting(atLeast: baseline + 2)
    await worker.stop()

    #expect(reached, "tick 期间到达的 wake 被丢了——worker 睡满 intervalSec 没有第二轮")
    let rows = try await db.pool.read { conn in
        try String.fetchAll(conn, sql: "SELECT id FROM item")
    }
    #expect(rows == ["late-row"])
}

/// 反向保护：**没有** wake 时不能凭空少睡。否则"修好 wake"会退化成 30s 间隔失效、
/// 每轮 tick 之间无退避空转。
private actor NeverWakesTransport: SinceTransport {
    private var fetchCount = 0
    func fetchCallCount() -> Int { fetchCount }

    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        await self.next()
    }

    private func next() -> RemoteSinceResult {
        fetchCount += 1
        return RemoteSinceResult(outcome: .ok(onePage([])))
    }

    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        PrimaryHealthResult(outcome: .ok(deviceID: "peer-b", nowMs: 1_000, ponteHost: nil))
    }
}

@Test func withoutWakeWorkerStillSleepsTheFullInterval() async throws {
    let db = try makeDB()
    let transport = NeverWakesTransport()
    let worker = PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "self-mac",
        expectedPeerDeviceID: "peer-b",
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 600),
        nowNs: { 5_000 }
    )
    let baseline = await worker.completedTickCountForTesting()
    await worker.start()
    #expect(await worker.waitForCompletedTicksForTesting(atLeast: baseline + 1))
    // 第一轮之后应当睡满 600s —— 短超时内绝不该出现第二轮
    let spun = await worker.waitForCompletedTicksForTesting(atLeast: baseline + 2, timeoutSec: 0.6)
    await worker.stop()
    #expect(spun == false, "没有 wake 却又跑了一轮 —— pendingWake 没被正确清掉，退化成空转")
    #expect(await transport.fetchCallCount() == 1)
}

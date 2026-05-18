import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

/// 给 onHealthProbed 测试用的可脚本化 transport。/health 按 modes 序列返回,
/// 用尽后退回最后一项重复(让 backoff tick 拿到同样 outcome)。/since 不参与本组测试,
/// 返回 unreachable 让 tick 早退即可——只验证 health callback 行为
private actor HealthCallbackTransport: SinceTransport {
    enum HealthMode: Sendable {
        case ok(deviceID: String)
        case unreachable
        case rejected
        case okEmptyID
        case throwError
    }
    private var modes: [HealthMode]
    private(set) var healthCalls: Int = 0

    init(modes: [HealthMode]) { self.modes = modes }

    nonisolated func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        RemoteSinceResult(outcome: .unreachable(reason: "n/a in this test"))
    }

    nonisolated func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        try await self._fetchPrimaryHealth()
    }

    private func _fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        healthCalls += 1
        let mode = modes.count > 1 ? modes.removeFirst() : (modes.first ?? .unreachable)
        switch mode {
        case .ok(let id):
            return PrimaryHealthResult(outcome: .ok(deviceID: id, nowMs: 1_000, ponteHost: nil))
        case .unreachable:
            return PrimaryHealthResult(outcome: .unreachable(reason: "fake"))
        case .rejected:
            return PrimaryHealthResult(outcome: .rejected(reason: "fake"))
        case .okEmptyID:
            return PrimaryHealthResult(outcome: .ok(deviceID: "", nowMs: 1_000, ponteHost: nil))
        case .throwError:
            throw URLError(.cannotConnectToHost)
        }
    }
}

/// 同步收集 callback 收到的 rttMs。NSLock 让 push/snapshot 在 actor 外随便调,不依赖
/// Task hop 让测试 timing 简单可靠(worker.stop() 后立刻 snapshot 拿到完整序列)
private final class RTTCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int64] = []
    func push(_ ms: Int64) {
        lock.lock(); defer { lock.unlock() }
        _values.append(ms)
    }
    func snapshot() -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }
}

private func makeClientDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-pull-cb-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func makeWorker(
    transport: HealthCallbackTransport,
    expected: String? = nil,
    collector: RTTCollector,
    db: DuoDB
) -> PullWorker {
    PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "client-self",
        expectedPeerDeviceID: expected,
        meshStatus: MeshStatus(),
        config: PullWorker.Config(intervalSec: 60),
        onHealthProbed: { ms in collector.push(ms) }
    )
}

private func runBriefly(_ w: PullWorker, ms: Int = 200) async {
    await w.start()
    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    await w.stop()
}

@Test func onHealthProbedFiresPositiveRttOnOK() async throws {
    let db = try makeClientDB()
    let transport = HealthCallbackTransport(modes: [.ok(deviceID: "primary-device")])
    let collector = RTTCollector()
    let worker = makeWorker(transport: transport, collector: collector, db: db)
    await runBriefly(worker)
    let rtts = collector.snapshot()
    #expect(!rtts.isEmpty)
    // .ok → 非负 RTT (Date wall-clock,fake 调用通常 < 10ms)
    #expect(rtts.allSatisfy { $0 >= 0 })
}

@Test func onHealthProbedFiresMinusOneOnUnreachable() async throws {
    let db = try makeClientDB()
    let transport = HealthCallbackTransport(modes: [.unreachable])
    let collector = RTTCollector()
    let worker = makeWorker(transport: transport, collector: collector, db: db)
    await runBriefly(worker)
    let rtts = collector.snapshot()
    #expect(!rtts.isEmpty)
    #expect(rtts.allSatisfy { $0 == -1 })
}

@Test func onHealthProbedFiresMinusOneOnRejected() async throws {
    let db = try makeClientDB()
    let transport = HealthCallbackTransport(modes: [.rejected])
    let collector = RTTCollector()
    let worker = makeWorker(transport: transport, collector: collector, db: db)
    await runBriefly(worker)
    let rtts = collector.snapshot()
    #expect(!rtts.isEmpty)
    #expect(rtts.allSatisfy { $0 == -1 })
}

@Test func onHealthProbedFiresMinusOneOnThrow() async throws {
    let db = try makeClientDB()
    let transport = HealthCallbackTransport(modes: [.throwError])
    let collector = RTTCollector()
    let worker = makeWorker(transport: transport, collector: collector, db: db)
    await runBriefly(worker)
    let rtts = collector.snapshot()
    #expect(!rtts.isEmpty)
    #expect(rtts.allSatisfy { $0 == -1 })
}

@Test func onHealthProbedFiresMinusOneOnEmptyDeviceID() async throws {
    let db = try makeClientDB()
    let transport = HealthCallbackTransport(modes: [.okEmptyID])
    let collector = RTTCollector()
    let worker = makeWorker(transport: transport, collector: collector, db: db)
    await runBriefly(worker)
    let rtts = collector.snapshot()
    #expect(!rtts.isEmpty)
    #expect(rtts.allSatisfy { $0 == -1 })
}

@Test func onHealthProbedFiresMinusOneOnExpectedMismatch() async throws {
    let db = try makeClientDB()
    let transport = HealthCallbackTransport(modes: [.ok(deviceID: "actual-id")])
    let collector = RTTCollector()
    let worker = makeWorker(
        transport: transport,
        expected: "expected-but-different-id",
        collector: collector,
        db: db
    )
    await runBriefly(worker)
    let rtts = collector.snapshot()
    #expect(!rtts.isEmpty)
    #expect(rtts.allSatisfy { $0 == -1 })
}

// MARK: - B5: onChosenLikelyDown 失败计数触发

/// 计数 callback 触发次数。同步 push 不依赖 Task hop,跟 RTTCollector 同设计
private final class DownCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count: Int = 0
    func hit() {
        lock.lock(); defer { lock.unlock() }
        _count += 1
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
}

/// 让 PullWorker tick 跑多次:initialBackoffSec 设 0.05s 加速 backoff sleep,
/// runMs=1500ms 让 3-5 次 tick 全部跑完
private func makeFailingWorker(
    threshold: Int,
    counter: DownCounter,
    db: DuoPasteCore.Database
) -> PullWorker {
    let transport = HealthCallbackTransport(modes: [.unreachable])
    return PullWorker(
        database: db,
        transport: transport,
        selfDeviceID: "client-self",
        meshStatus: MeshStatus(),
        config: PullWorker.Config(
            intervalSec: 60,
            initialBackoffSec: 0.05,  // 测试加速
            maxBackoffSec: 0.2,
            reconcileFailureThreshold: threshold
        ),
        onChosenLikelyDown: { counter.hit() }
    )
}

@Test func onChosenLikelyDownFiresOnceAtThreshold() async throws {
    let db = try makeClientDB()
    let counter = DownCounter()
    let worker = makeFailingWorker(threshold: 3, counter: counter, db: db)
    await worker.start()
    // 让 3+ 次 tick 跑完:initial=0.05, 失败 backoff 2^n × 0.05,3 次后 sleep 0.05+0.1+0.2 = 0.35s
    // 给 1500ms 余量让第 4/5 次也跑完,验证只触发 1 次不会 spam
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    await worker.stop()
    // ==threshold 时触发一次。后续 tick 仍 unreachable 但 consecutiveTransientFailures 已 > threshold,
    // 不再触发(等下次 .ok reset 后才会再积累到 threshold)
    #expect(counter.count == 1, "got \(counter.count) — should fire exactly once at threshold boundary")
}

@Test func onChosenLikelyDownDoesNotFireBelowThreshold() async throws {
    let db = try makeClientDB()
    let counter = DownCounter()
    let worker = makeFailingWorker(threshold: 100, counter: counter, db: db)  // 高阈值跑不到
    await worker.start()
    try? await Task.sleep(nanoseconds: 500_000_000)
    await worker.stop()
    #expect(counter.count == 0)
}

@Test func onChosenLikelyDownDisabledWhenThresholdZero() async throws {
    let db = try makeClientDB()
    let counter = DownCounter()
    let worker = PullWorker(
        database: db,
        transport: HealthCallbackTransport(modes: [.unreachable]),
        selfDeviceID: "client-self",
        meshStatus: MeshStatus(),
        config: PullWorker.Config(
            intervalSec: 60,
            initialBackoffSec: 0.05,
            maxBackoffSec: 0.2,
            reconcileFailureThreshold: 0  // 禁用
        ),
        onChosenLikelyDown: { counter.hit() }
    )
    await worker.start()
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    await worker.stop()
    #expect(counter.count == 0)
}


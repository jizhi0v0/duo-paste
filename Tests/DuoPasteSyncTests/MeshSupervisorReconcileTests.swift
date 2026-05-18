import Testing
import Foundation
import DuoPasteCore
@testable import DuoPasteSync

/// PR 4 reconcileTransports 测试。注入 fake discoverOverride + fake buildPeer 让测试
/// 不需要真起 PullWorker / server。验：
/// - 决策没变 → no-op，worker 实例 identity 保持
/// - 决策变了 → 该 peer 重建，未变的 peer 不动
/// - Burst trigger → coalesce gate 合并，discover 调用次数 ≤2

private actor CallCounter {
    private(set) var count = 0
    func inc() { count += 1 }
}

/// 一个共享 actor 跑测试期间的 fake PullWorker 寿命跟踪——不真起 runLoop，
/// 但记录 start/stop 调用让测试断言生命周期管理正确
private actor BuildLog {
    private(set) var builds: [Int] = []        // 每次 buildPeer 被调时记 peerIndex
    func record(_ idx: Int) { builds.append(idx) }
}

@Suite(.serialized)
struct MeshSupervisorReconcileTests {

    private func makePeerConfig(_ url: String) -> Config.PeerConfig {
        Config.PeerConfig(url: URL(string: url)!)
    }

    private func makeDecision(
        peerIndex: Int,
        chosenPullURL: String,
        wsKind: SmartTransport.TransportKind = .nio,
        configuredURL: String? = nil,
        ponteHost: String? = nil
    ) -> SmartTransport.PeerDecision {
        let configured = URL(string: configuredURL ?? chosenPullURL)!
        let pull = URL(string: chosenPullURL)!
        return SmartTransport.PeerDecision(
            peerIndex: peerIndex,
            configuredURL: configured,
            manualPullURL: nil,
            learnedPonteHost: ponteHost,
            chosenPullURL: pull,
            chosenWSURL: pull,
            chosenWSKind: wsKind,
            httpRttMs: [:]
        )
    }

    /// 用一个 noop PullWorker——transport 给 fake fetch 返回 unreachable，永远不真探。
    /// 测试只 care worker 实例 identity，不 care 它真跑通什么
    private func makeNoopWorker(label: String) -> PullWorker {
        let fake = NoopTransport()
        let db = try! makeMemoryDB()
        let blobs = makeMemoryBlobs()
        return PullWorker(
            database: db,
            transport: fake,
            selfDeviceID: "self-\(label)",
            expectedPeerDeviceID: nil,
            meshStatus: MeshStatus(),
            pasteSuppressions: nil,
            blobFetcher: fake,
            blobs: blobs,
            evictOnFull: { false },
            config: PullWorker.Config(intervalSec: 60)
        )
    }

    @Test func reconcileNoChangeIsNoOp() async throws {
        // 初始 decision == discover 返回的 decision → applyDecisions 应跳过 → worker
        // 实例 identity 保持
        let peer = makePeerConfig("https://mbp.tail.ts.net:8443")
        let decision = makeDecision(peerIndex: 0, chosenPullURL: "https://mbp.tail.ts.net:8443")
        let initialWorker = makeNoopWorker(label: "init")
        let initialPeer = MeshSupervisor.Peer(worker: initialWorker)

        let buildLog = BuildLog()
        let buildPeer: @Sendable (SmartTransport.PeerDecision) -> MeshSupervisor.Peer = { d in
            // 这条不该被调（决策没变）；若被调测试会失败
            Task { await buildLog.record(d.peerIndex) }
            return MeshSupervisor.Peer(worker: PullWorker(
                database: try! makeMemoryDB(),
                transport: NoopTransport(),
                selfDeviceID: "self",
                expectedPeerDeviceID: nil,
                meshStatus: MeshStatus(),
                blobFetcher: NoopTransport(),
                blobs: makeMemoryBlobs(),
                evictOnFull: { false },
                config: PullWorker.Config(intervalSec: 60)
            ))
        }

        let supervisor = MeshSupervisor(
            initialPeers: [initialPeer],
            initialDecisions: [decision],
            smart: SmartTransport(),
            configPeers: [peer],
            auth: HMACAuth(secret: Data(repeating: 0xC0, count: 32)),
            tailscaleSession: .shared,
            buildPeer: buildPeer,
            discoverOverride: { [decision] },
            autoRecoverOnDNSChange: false
        )

        await supervisor.reconcileTransports()

        // worker 实例 identity 没变
        let workers = await supervisor.workers
        #expect(workers.count == 1)
        #expect(workers[0] === initialWorker)
        #expect(await buildLog.builds.isEmpty)
    }

    @Test func reconcileURLChangeRebuildsAffectedPeerOnly() async throws {
        // 两 peer。reconcile 时 peer 0 决策变了，peer 1 没变 →
        // peer 0 worker 是新实例，peer 1 是老实例
        let peerA = makePeerConfig("https://mbp.tail.ts.net:8443")
        let peerB = makePeerConfig("https://mini.tail.ts.net:8443")

        let oldDecisionA = makeDecision(peerIndex: 0, chosenPullURL: "https://mbp.tail.ts.net:8443")
        let oldDecisionB = makeDecision(peerIndex: 1, chosenPullURL: "https://mini.tail.ts.net:8443")
        let newDecisionA = makeDecision(
            peerIndex: 0,
            chosenPullURL: "https://mbp.sgponte:8443",
            wsKind: .urlSession,
            configuredURL: "https://mbp.tail.ts.net:8443",
            ponteHost: "mbp.sgponte"
        )
        // peer 1 决策不变
        let newDecisionB = oldDecisionB

        let oldWorkerA = makeNoopWorker(label: "A-old")
        let oldWorkerB = makeNoopWorker(label: "B-old")
        let newWorkerA = makeNoopWorker(label: "A-new")
        let workersForRebuild = WorkerStock(items: [(0, newWorkerA)])

        let buildLog = BuildLog()
        let buildPeer: @Sendable (SmartTransport.PeerDecision) -> MeshSupervisor.Peer = { d in
            Task { await buildLog.record(d.peerIndex) }
            if d.peerIndex == 0 {
                return MeshSupervisor.Peer(worker: newWorkerA)
            }
            return MeshSupervisor.Peer(worker: oldWorkerB)  // 不该被调用，但兜底
        }
        _ = workersForRebuild

        let supervisor = MeshSupervisor(
            initialPeers: [MeshSupervisor.Peer(worker: oldWorkerA), MeshSupervisor.Peer(worker: oldWorkerB)],
            initialDecisions: [oldDecisionA, oldDecisionB],
            smart: SmartTransport(),
            configPeers: [peerA, peerB],
            auth: HMACAuth(secret: Data(repeating: 0xC1, count: 32)),
            tailscaleSession: .shared,
            buildPeer: buildPeer,
            discoverOverride: { [newDecisionA, newDecisionB] },
            autoRecoverOnDNSChange: false
        )

        await supervisor.reconcileTransports()

        let workers = await supervisor.workers
        #expect(workers.count == 2)
        #expect(workers[0] === newWorkerA, "peer 0 应该是新 worker")
        #expect(workers[1] === oldWorkerB, "peer 1 决策没变，应该保留老 worker")
        let builds = await buildLog.builds
        #expect(builds == [0], "只 peer 0 应被重建")

        // currentDecisions 应该更新到 newDecisionA
        let decisions = await supervisor.currentDecisions
        #expect(decisions[0] == newDecisionA)
        #expect(decisions[1] == oldDecisionB)
    }

    @Test func reconcileCoalescesBurstTriggers() async throws {
        // 5 次并发 reconcile → discover 闭包最多被调 2 次
        let peer = makePeerConfig("https://mbp.tail.ts.net:8443")
        let decision = makeDecision(peerIndex: 0, chosenPullURL: "https://mbp.tail.ts.net:8443")
        let initialPeer = MeshSupervisor.Peer(worker: makeNoopWorker(label: "init"))

        let discoverCount = CallCounter()
        let discoverOverride: @Sendable () async -> [SmartTransport.PeerDecision] = { [decision] in
            await discoverCount.inc()
            // 慢一点让后续 trigger 一定踩到 inFlight=true
            try? await Task.sleep(nanoseconds: 100_000_000)
            return [decision]
        }
        let buildPeer: @Sendable (SmartTransport.PeerDecision) -> MeshSupervisor.Peer = { _ in
            MeshSupervisor.Peer(worker: PullWorker(
                database: try! makeMemoryDB(),
                transport: NoopTransport(),
                selfDeviceID: "self",
                expectedPeerDeviceID: nil,
                meshStatus: MeshStatus(),
                blobFetcher: NoopTransport(),
                blobs: makeMemoryBlobs(),
                evictOnFull: { false },
                config: PullWorker.Config(intervalSec: 60)
            ))
        }

        let supervisor = MeshSupervisor(
            initialPeers: [initialPeer],
            initialDecisions: [decision],
            smart: SmartTransport(),
            configPeers: [peer],
            auth: HMACAuth(secret: Data(repeating: 0xC2, count: 32)),
            tailscaleSession: .shared,
            buildPeer: buildPeer,
            discoverOverride: discoverOverride,
            autoRecoverOnDNSChange: false
        )

        // 5 个并发 trigger
        async let r0: Void = supervisor.reconcileTransports()
        async let r1: Void = supervisor.reconcileTransports()
        async let r2: Void = supervisor.reconcileTransports()
        async let r3: Void = supervisor.reconcileTransports()
        async let r4: Void = supervisor.reconcileTransports()
        _ = await (r0, r1, r2, r3, r4)

        let total = await discoverCount.count
        // 完美 coalesce 是 2 次：第一次 + 一次合并所有 queued。但并发时序下也可能
        // 跑 1 次（第二次刚要 enter 时第一次已 exit）。允许 1-2 次，严禁 ≥3
        #expect(total >= 1 && total <= 2, "burst 5 应合并到 1-2 次 discover，实际 \(total)")
    }

    @Test func reconcileNoOpWhenSmartDepsMissing() async throws {
        // PR 3 兼容入口(无 smart 依赖)调 reconcile 应静默 no-op,不抛
        let supervisor = MeshSupervisor(workers: [makeNoopWorker(label: "x")])
        await supervisor.reconcileTransports()  // 不该挂 / 抛 / 改变 peer
        let workers = await supervisor.workers
        #expect(workers.count == 1)
    }

    @Test func periodicReconcileFiresMultipleTimes() async throws {
        // B2:周期 timer 在 supervisor.start() 后启动,按 periodicReconcileSec 间隔
        // 反复触发 reconcileTransports。stop() 取消 task,后续 sleep 期不再触发
        let peer = makePeerConfig("https://x:8443")
        let decision = makeDecision(peerIndex: 0, chosenPullURL: "https://x:8443")
        let initialWorker = makeNoopWorker(label: "init")
        let counter = CallCounter()
        let discoverOverride: @Sendable () async -> [SmartTransport.PeerDecision] = { [decision] in
            await counter.inc()
            return [decision]
        }
        let supervisor = MeshSupervisor(
            initialPeers: [MeshSupervisor.Peer(worker: initialWorker)],
            initialDecisions: [decision],
            smart: SmartTransport(),
            configPeers: [peer],
            auth: HMACAuth(secret: Data(repeating: 0xC0, count: 32)),
            tailscaleSession: .shared,
            buildPeer: { _ in MeshSupervisor.Peer(worker: initialWorker) },
            discoverOverride: discoverOverride,
            autoRecoverOnDNSChange: false,
            periodicReconcileSec: 0.15  // 短间隔测试加速
        )
        await supervisor.start()
        try? await Task.sleep(nanoseconds: 600_000_000)  // 0.6s → 应触发 3-4 次
        await supervisor.stop()
        let firedDuringRun = await counter.count
        #expect(firedDuringRun >= 3, "got \(firedDuringRun) — periodic timer should have fired ≥3 times in 0.6s @ 0.15s interval")
        // stop 后再等一会儿,确认 timer 真停了不会继续触发
        try? await Task.sleep(nanoseconds: 400_000_000)
        let firedAfterStop = await counter.count
        #expect(firedAfterStop == firedDuringRun, "got \(firedAfterStop) vs \(firedDuringRun) — timer not cancelled by stop()")
    }

    @Test func periodicReconcileDisabledWhenSecZero() async throws {
        // periodicReconcileSec=0 → 不启动 timer
        let peer = makePeerConfig("https://x:8443")
        let decision = makeDecision(peerIndex: 0, chosenPullURL: "https://x:8443")
        let counter = CallCounter()
        let supervisor = MeshSupervisor(
            initialPeers: [MeshSupervisor.Peer(worker: makeNoopWorker(label: "x"))],
            initialDecisions: [decision],
            smart: SmartTransport(),
            configPeers: [peer],
            auth: HMACAuth(secret: Data(repeating: 0xC0, count: 32)),
            tailscaleSession: .shared,
            buildPeer: { _ in MeshSupervisor.Peer(worker: makeNoopWorker(label: "x")) },
            discoverOverride: { await counter.inc(); return [decision] },
            autoRecoverOnDNSChange: false,
            periodicReconcileSec: 0
        )
        await supervisor.start()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await supervisor.stop()
        #expect(await counter.count == 0)
    }
}

/// Worker 实例池——给 reconcile 测试持续 pop 新 worker
private actor WorkerStock {
    private var items: [(Int, PullWorker)]
    init(items: [(Int, PullWorker)]) { self.items = items }
    func popWorker(forPeerIndex idx: Int) -> PullWorker? {
        if let pos = items.firstIndex(where: { $0.0 == idx }) {
            return items.remove(at: pos).1
        }
        return nil
    }
}

/// Fake transport 给 PullWorker——什么都不返回，永远 unreachable。测试只关心 worker 实例
/// identity，不需要它真的拉数据
private struct NoopTransport: SinceTransport, BlobFetcher, Sendable {
    func fetchSince(cursor: SinceCursor, limit: Int) async throws -> RemoteSinceResult {
        RemoteSinceResult(outcome: .unreachable(reason: "noop"))
    }
    func fetchPrimaryHealth() async throws -> PrimaryHealthResult {
        PrimaryHealthResult(outcome: .unreachable(reason: "noop"))
    }
    func getBlob(sha256: String) async throws -> GetBlobOutcome {
        .notFound
    }
}

private func makeMemoryDB() throws -> Database {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("mesh-reconcile-\(UUID().uuidString).sqlite")
    return try Database(path: path)
}

private func makeMemoryBlobs() -> BlobStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mesh-reconcile-blobs-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root)
}

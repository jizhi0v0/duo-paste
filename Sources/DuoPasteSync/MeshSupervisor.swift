import Foundation
import DuoPasteCore

/// Mesh 拓扑下 N 个 PullWorker 的薄包装：统一 start / stop / wakeAll。PR 4 加 smart
/// transport reconcile——DNS 变化时重测 /health 决策，对决策变了的 peer tear-down 老 worker
/// + 起新 worker（cursor 在 DB 里所以无状态丢失）。
///
/// 为什么是"薄"：PullWorker 已经是 actor 自管 runLoop / sleep / wake，supervisor 不接管控制流，
/// 只做生命周期 fan-out + transport 决策 reconcile。
///
/// PR 3：每个 peer 一个 (PullWorker, WSNotificationClient?) 对。WS client 可选——`mesh.ws_enabled=false`
/// 或测试场景传 nil，行为退化为 PR 2 纯轮询模式。
///
/// PR 4：peers 不再 immutable，存在私有 `PeerSlots` actor 里允许运行时换 worker 实例。
/// DNS 变化触发 `reconcileTransports()` 重 discover + 必要时 rebuild。Coalesce gate 防 storm。
public final class MeshSupervisor: @unchecked Sendable {
    public struct Peer: Sendable {
        public let worker: PullWorker
        public let wsClient: WSNotificationClient?

        public init(worker: PullWorker, wsClient: WSNotificationClient? = nil) {
            self.worker = worker
            self.wsClient = wsClient
        }
    }

    /// 运行时可变的 peer 列表 + 上次 decision 缓存——为 reconcile diff 用
    private let slots: PeerSlots
    private let log: @Sendable (String) -> Void
    /// 系统 DNS / 网络接口变化时让所有 WS client 立即重连(绕过 backoff sleep)。
    /// supervisor.start() 时启动,stop() 时停。nil = 禁用自动恢复(测试场景)
    private var dnsMonitor: DNSChangeMonitor?
    /// 周期 reconcile 兜底——非 DNS 触发的环境恢复(Surge 重启 / ponte 隧道重连 / 对端
    /// daemon 重启等)。<= 0 = 禁用(测试 / 兼容路径)。默认 300s = 5min,跟 PullWorker B5
    /// 失败计数触发的 quick recovery 协同覆盖(B5 ~14s 内反应,B2 5min 兜底)
    private let periodicReconcileSec: TimeInterval
    private var periodicReconcileTask: Task<Void, Never>?

    // PR 4 reconcile 依赖。全 nil 表示 "纯 PullWorker / 测试模式 / 老调用点"——这种模式
    // reconcileTransports() no-op，DNS 变化仍调 wakeAllWS()
    private let smart: SmartTransport?
    private let configPeers: [Config.PeerConfig]
    private let auth: HMACAuth?
    private let tailscaleSession: URLSession?
    /// 生产路径 = `SmartTransport.PeerBuilder.build`；测试可注入 fake closure 返回特定 Peer
    private let buildPeer: (@Sendable (SmartTransport.PeerDecision) -> Peer)?
    /// 测试注入点——覆盖 smart.discover 走 fake 返回固定 decisions；nil = 用 smart 真探
    private let discoverOverride: (@Sendable () async -> [SmartTransport.PeerDecision])?
    /// reconcile 完后给外部（AppState）push 当前决策，让 UI 能订阅展示
    private let onDecisionsUpdated: (@Sendable ([SmartTransport.PeerDecision]) -> Void)?
    private let reconcileGate: ReconcileGate

    // MARK: - Inits

    /// 完整 init——PR 4 smart-mode 用。所有 reconcile 依赖一起注入；任何一项 nil →
    /// reconcileTransports() 立即返回（退化为 PR 3 静态 supervisor）
    public init(
        initialPeers: [Peer],
        initialDecisions: [SmartTransport.PeerDecision] = [],
        smart: SmartTransport? = nil,
        configPeers: [Config.PeerConfig] = [],
        auth: HMACAuth? = nil,
        tailscaleSession: URLSession? = nil,
        buildPeer: (@Sendable (SmartTransport.PeerDecision) -> Peer)? = nil,
        discoverOverride: (@Sendable () async -> [SmartTransport.PeerDecision])? = nil,
        onDecisionsUpdated: (@Sendable ([SmartTransport.PeerDecision]) -> Void)? = nil,
        autoRecoverOnDNSChange: Bool = true,
        periodicReconcileSec: TimeInterval = 300,
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("mesh: \(msg)\n".utf8))
        }
    ) {
        self.slots = PeerSlots(peers: initialPeers, decisions: initialDecisions)
        self.log = log
        self.smart = smart
        self.configPeers = configPeers
        self.auth = auth
        self.tailscaleSession = tailscaleSession
        self.buildPeer = buildPeer
        self.discoverOverride = discoverOverride
        self.onDecisionsUpdated = onDecisionsUpdated
        self.reconcileGate = ReconcileGate()
        self.periodicReconcileSec = periodicReconcileSec
        if autoRecoverOnDNSChange {
            // WakeBox 桥接：闭包不能直接 capture self（初始化未完），用一个 box 占位
            let wakeBox = WakeBox()
            self.dnsMonitor = DNSChangeMonitor(
                onChange: { wakeBox.invoke() }
            )
            wakeBox.target = { [weak self] in
                guard let self else { return }
                // 快路径：让所有 WS client 立即跳出 backoff 重连——cheap，不依赖 reconcile
                self.wakeAllWS()
                // 慢路径：重测 /health 决策，必要时 rebuild。无 smart 配置 → no-op
                Task { await self.reconcileTransports() }
            }
        }
    }

    /// PR 3 兼容入口——peers + 可选 DNS 自恢复。无 smart reconcile
    public convenience init(
        peers: [Peer],
        autoRecoverOnDNSChange: Bool = true,
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("mesh: \(msg)\n".utf8))
        }
    ) {
        self.init(
            initialPeers: peers,
            autoRecoverOnDNSChange: autoRecoverOnDNSChange,
            periodicReconcileSec: 0,
            log: log
        )
    }

    /// PR 2 兼容入口:只有 PullWorker 列表 → 自动包成 Peer 对(wsClient = nil)。
    /// 旧调用点(如 PR 2 时期 AppDelegate)和单 peer 测试可以继续 work。
    /// 这条路径**默认禁用** DNS monitor——纯 PullWorker 不需要,测试不希望
    /// supervisor.start() 走系统 SCDynamicStore 交互
    public convenience init(
        workers: [PullWorker],
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("mesh: \(msg)\n".utf8))
        }
    ) {
        self.init(
            initialPeers: workers.map { Peer(worker: $0) },
            autoRecoverOnDNSChange: false,
            periodicReconcileSec: 0,
            log: log
        )
    }

    /// 闭包持有的 box,把 supervisor 弱引用桥进 DNSChangeMonitor 的 @Sendable 回调
    private final class WakeBox: @unchecked Sendable {
        var target: (() -> Void)?
        func invoke() { target?() }
    }

    // MARK: - Accessors

    /// 暴露 worker 列表的别名——很多旧测试 / 上层代码用 `supervisor.workers`，保留兼容。
    /// async 因为底下走 actor，但 99% callsite 反正已经在 async ctx
    public var workers: [PullWorker] {
        get async { await slots.snapshot().map(\.worker) }
    }

    /// 当前 mesh 里活跃 peer 数。
    public var peerCount: Int {
        get async { await slots.count() }
    }

    /// 当前每个 peer 的 transport 决策。reconcileTransports 完会更新。
    /// nil 元素 = 没用 smart 路径初始化的 peer
    public var currentDecisions: [SmartTransport.PeerDecision?] {
        get async { await slots.decisions() }
    }

    // MARK: - Lifecycle

    /// 启动所有 peer。每对内部各自的 PullWorker.start() / WSNotificationClient.start() 是
    /// 幂等的（内部 guard 重入），并发启动各自 runLoop（actor 间互不阻塞）。
    /// PullWorker 先起，WS client 后起——WS 触发 wake() 时 worker 已经在跑。
    public func start() async {
        let snapshot = await slots.snapshot()
        let wsCount = snapshot.compactMap(\.wsClient).count
        log("starting \(snapshot.count) peer worker(s) · ws=\(wsCount)")
        for p in snapshot {
            await p.worker.start()
            if let ws = p.wsClient {
                await ws.start()
            }
        }
        // DNS / 网络接口 SCDynamicStore 监听放在 ws 启动后:Tailscale up/down 时立即
        // 让所有 WS client 跳过 backoff 重连
        dnsMonitor?.start()
        // 周期 reconcile timer:DNS 没变 + chosen 仍勉强活着但更优 transport 已恢复
        // 时兜底切回(典型场景:Surge 启动慢于 daemon → ponte 探测失败 → 5min 后周期
        // reconcile 看到 ponte 通了切回去)。smart 依赖任意为 nil 时 reconcileTransports
        // 自动 no-op,timer 也不必启动
        if periodicReconcileSec > 0, smart != nil, auth != nil, tailscaleSession != nil, buildPeer != nil {
            startPeriodicReconcile()
        }
    }

    private func startPeriodicReconcile() {
        let interval = periodicReconcileSec
        let logFn = log
        logFn("periodic reconcile started · interval=\(Int(interval))s")
        periodicReconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.reconcileTransports()
            }
        }
    }

    /// 停所有 peer。WS client 先停(cancel 长连接 task),PullWorker 后停——避免
    /// WS 在停 worker 期间还触发 wake()。
    public func stop() async {
        periodicReconcileTask?.cancel()
        periodicReconcileTask = nil
        dnsMonitor?.stop()
        let snapshot = await slots.snapshot()
        for p in snapshot {
            if let ws = p.wsClient {
                await ws.stop()
            }
            await p.worker.stop()
        }
        log("stopped all peer workers")
    }

    /// 外部触发"立即拉一次"——主要给手动调试用；正常路径靠 WS client 的 onCursorAdvanced。
    public func wakeAll() {
        Task { [slots] in
            for p in await slots.snapshot() {
                p.worker.wake()
            }
        }
    }

    /// SCDynamicStore DNS / 网络接口变化时调:让所有 WS client cancel 当前 backoff
    /// sleep 立即重连。WSClient.wake() 是 nonisolated 无 await
    public func wakeAllWS() {
        Task { [slots] in
            for p in await slots.snapshot() {
                p.wsClient?.wake()
            }
        }
    }

    // MARK: - PR 4 reconcile

    /// DNS 变化触发——重 discover transport，决策变了的 peer 重建。
    ///
    /// Coalesce gate 防 burst：DNS 通常 1-2 秒内连发好几次（tailscale up/down 通常 2-4 次
    /// SCDynamicStore 通知）。gate 让 in-flight 不重入，新 trigger 标 queued；当前一轮
    /// 跑完后再合并跑一次。最坏情况就是 2 次 discover 而不是 5+。
    public func reconcileTransports() async {
        guard let smart, let auth, let tailscaleSession, let buildPeer else {
            // 没注入 smart 依赖 → 完整 no-op；本次 supervisor 是纯 PullWorker 模式
            return
        }
        guard await reconcileGate.tryEnter() else {
            // in-flight，本次 trigger 已被记账，等当前轮跑完会合并跑一次
            return
        }
        while true {
            let decisions: [SmartTransport.PeerDecision]
            if let override = discoverOverride {
                decisions = await override()
            } else {
                decisions = await smart.discover(
                    peers: configPeers,
                    auth: auth,
                    tailscaleSession: tailscaleSession
                )
            }
            await applyDecisions(decisions, buildPeer: buildPeer)
            onDecisionsUpdated?(decisions)
            if await reconcileGate.exitOrLoop() {
                break  // 没 queued，本轮跑完干净退出
            }
            // 有 queued → 再跑一轮合并
        }
    }

    /// 对每个 peer 比较 decision 是否变了，变了就 stop old + build new + start new + 替换 slot。
    /// cursor 在 DB 里所以 worker 重建无状态丢失；MeshStatus per-peer 行通过 peerDeviceID 保持
    private func applyDecisions(
        _ decisions: [SmartTransport.PeerDecision],
        buildPeer: @Sendable (SmartTransport.PeerDecision) -> Peer
    ) async {
        let oldPeers = await slots.snapshot()
        let oldDecisions = await slots.decisions()
        for (i, decision) in decisions.enumerated() {
            guard i < oldPeers.count else {
                // 配置加了新 peer——当前实现不支持运行时新增。log warn 跳过
                log("reconcile: peer count grew (\(decisions.count) > \(oldPeers.count))，需重启 daemon 才能加新 peer")
                continue
            }
            if let oldDecision = oldDecisions.indices.contains(i) ? oldDecisions[i] : nil,
               oldDecision == decision {
                continue  // 决策没变，跳过
            }
            log("peer \(i) transport changed → \(decision.transportLabel)")
            let old = oldPeers[i]
            if let ws = old.wsClient { await ws.stop() }
            await old.worker.stop()
            let new = buildPeer(decision)
            await new.worker.start()
            if let ws = new.wsClient { await ws.start() }
            await slots.replace(at: i, with: new, decision: decision)
        }
    }
}

// MARK: - Internal actors

/// 私有 actor 持 supervisor 当前的 peer + 上次决策。reconcile 时增量替换；
/// snapshot/count/decisions 给读端
private actor PeerSlots {
    private var peers: [MeshSupervisor.Peer]
    /// 跟 peers 长度对齐——nil 表示当前 peer 没有"smart decision"记录（PR 3 兼容入口的情况）
    private var lastDecisions: [SmartTransport.PeerDecision?]

    init(peers: [MeshSupervisor.Peer], decisions: [SmartTransport.PeerDecision]) {
        self.peers = peers
        // decisions 长度可能小于 peers（兼容入口给 [] / 给部分）
        var aligned: [SmartTransport.PeerDecision?] = Array(repeating: nil, count: peers.count)
        for (i, d) in decisions.enumerated() where i < aligned.count {
            aligned[i] = d
        }
        self.lastDecisions = aligned
    }

    func snapshot() -> [MeshSupervisor.Peer] { peers }
    func count() -> Int { peers.count }
    func decisions() -> [SmartTransport.PeerDecision?] { lastDecisions }

    func replace(at index: Int, with peer: MeshSupervisor.Peer, decision: SmartTransport.PeerDecision) {
        guard peers.indices.contains(index) else { return }
        peers[index] = peer
        lastDecisions[index] = decision
    }
}

/// Coalesce gate——in-flight 标志 + queued 标志。tryEnter 返回是否抢到入口；
/// 没抢到的把 queued 标 true，调用方直接返回。当前轮跑完调 exitOrLoop——
/// queued 为 true → 清 queued，保留 inFlight，让调用方再跑一次；
/// queued 为 false → 清 inFlight，返回 true 让调用方退出
private actor ReconcileGate {
    private var inFlight = false
    private var queued = false

    func tryEnter() -> Bool {
        if inFlight {
            queued = true
            return false
        }
        inFlight = true
        return true
    }

    func exitOrLoop() -> Bool {
        if queued {
            queued = false
            return false
        }
        inFlight = false
        return true
    }
}

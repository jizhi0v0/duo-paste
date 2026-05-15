import Foundation
import DuoPasteCore

/// Mesh 拓扑下 N 个 PullWorker 的薄包装：统一 start / stop / wakeAll。
///
/// 为什么是"薄"：PullWorker 已经是 actor 自管 runLoop / sleep / wake，supervisor 不接管控制流，
/// 只做生命周期 fan-out。这样 MeshSupervisor 的测试只验"N 个 worker 都被启动" / "stop 全停"，
/// 单个 worker 的 pull 行为继续在 PullWorkerTests / MultiPeerPullWorkerTests 验证。
///
/// 注入 `[PullWorker]` 而不是 `[PeerSpec] + transportFactory`：
/// - 生产 AppDelegate 自己组装好每个 worker（HTTPPeerClient transport + 注入依赖），传进 supervisor
/// - 测试可直接构造 mock-transport 的 worker 列表传进来
/// - supervisor 不依赖 transport / config 细节，可独立单测
///
/// PR 3：每个 peer 一个 (PullWorker, WSNotificationClient?) 对。WS client 可选——`mesh.ws_enabled=false`
/// 或测试场景传 nil，行为退化为 PR 2 纯轮询模式。
public final class MeshSupervisor: @unchecked Sendable {
    public struct Peer: Sendable {
        public let worker: PullWorker
        public let wsClient: WSNotificationClient?

        public init(worker: PullWorker, wsClient: WSNotificationClient? = nil) {
            self.worker = worker
            self.wsClient = wsClient
        }
    }

    /// 配置好的 peer 对列表。每对锚定一个 peer。初始化后不变；并发读 OK，
    /// @unchecked Sendable 因为 Swift 不能从 final class 自动推出"不可变 array of actor 对是 Sendable"。
    public let peers: [Peer]
    private let log: @Sendable (String) -> Void
    /// 系统 DNS / 网络接口变化时让所有 WS client 立即重连(绕过 backoff sleep)。
    /// supervisor.start() 时启动,stop() 时停。nil = 禁用自动恢复(测试场景)
    private var dnsMonitor: DNSChangeMonitor?

    public init(
        peers: [Peer],
        autoRecoverOnDNSChange: Bool = true,
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("mesh: \(msg)\n".utf8))
        }
    ) {
        self.peers = peers
        self.log = log
        if autoRecoverOnDNSChange {
            // WakeBox 桥接:闭包不能直接 capture self(初始化未完),用一个 box 占位
            let wakeBox = WakeBox()
            self.dnsMonitor = DNSChangeMonitor(
                onChange: { wakeBox.invoke() }
            )
            wakeBox.target = { [weak self] in self?.wakeAllWS() }
        }
    }

    /// 闭包持有的 box,把 supervisor 弱引用桥进 DNSChangeMonitor 的 @Sendable 回调
    private final class WakeBox: @unchecked Sendable {
        var target: (() -> Void)?
        func invoke() { target?() }
    }

    /// PR 2 兼容入口：只有 PullWorker 列表 → 自动包成 Peer 对（wsClient = nil）。
    /// 旧调用点（如 PR 2 时期 AppDelegate）和单 peer 测试可以继续 work。
    /// 这条路径**默认禁用** DNS monitor——纯 PullWorker 不需要,测试不希望
    /// supervisor.start() 走系统 SCDynamicStore 交互
    public convenience init(
        workers: [PullWorker],
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("mesh: \(msg)\n".utf8))
        }
    ) {
        self.init(peers: workers.map { Peer(worker: $0) }, autoRecoverOnDNSChange: false, log: log)
    }

    /// 暴露 worker 列表的别名——很多旧测试 / 上层代码用 `supervisor.workers`，保留兼容。
    public var workers: [PullWorker] { peers.map(\.worker) }

    /// 启动所有 peer。每对内部各自的 PullWorker.start() / WSNotificationClient.start() 是
    /// 幂等的（内部 guard 重入），并发启动各自 runLoop（actor 间互不阻塞）。
    /// PullWorker 先起，WS client 后起——WS 触发 wake() 时 worker 已经在跑。
    public func start() async {
        let wsCount = peers.compactMap(\.wsClient).count
        log("starting \(peers.count) peer worker(s) · ws=\(wsCount)")
        for p in peers {
            await p.worker.start()
            if let ws = p.wsClient {
                await ws.start()
            }
        }
        // DNS / 网络接口 SCDynamicStore 监听放在 ws 启动后:Tailscale up/down 时立即
        // 让所有 WS client 跳过 backoff 重连
        dnsMonitor?.start()
    }

    /// 停所有 peer。WS client 先停（cancel 长连接 task），PullWorker 后停——避免
    /// WS 在停 worker 期间还触发 wake()。
    public func stop() async {
        dnsMonitor?.stop()
        for p in peers {
            if let ws = p.wsClient {
                await ws.stop()
            }
            await p.worker.stop()
        }
        log("stopped all peer workers")
    }

    /// 外部触发"立即拉一次"——主要给手动调试用；正常路径靠 WS client 的 onCursorAdvanced。
    public func wakeAll() {
        for p in peers {
            p.worker.wake()
        }
    }

    /// SCDynamicStore DNS / 网络接口变化时调:让所有 WS client cancel 当前 backoff
    /// sleep 立即重连。WSClient.wake() 是 nonisolated 无 await
    public func wakeAllWS() {
        for p in peers {
            p.wsClient?.wake()
        }
    }

    /// 当前 mesh 里活跃 peer 数。
    public var peerCount: Int { peers.count }
}

import Foundation
import DuoPasteCore

/// Mesh 拓扑下 N 个 PullWorker 的薄包装：统一 start / stop / wakeAll。
///
/// 为什么是"薄"：PullWorker 已经是 actor 自管 runLoop / sleep / wake，supervisor 不接管控制流，
/// 只做生命周期 fan-out。这样 MeshSupervisor 的测试只验"N 个 worker 都被启动" / "stop 全停"，
/// 单个 worker 的 pull 行为继续在 PullWorkerTests / MultiPeerPullWorkerTests 验证。
///
/// 注入 `[PullWorker]` 而不是 `[PeerSpec] + transportFactory`：
/// - 生产 AppDelegate 自己组装好每个 worker（HTTPIngestClient transport + 注入依赖），传进 supervisor
/// - 测试可直接构造 mock-transport 的 worker 列表传进来
/// - supervisor 不依赖 transport / config 细节，可独立单测
///
/// PR 2 不接 WSNotificationClient（PR 3 范围）；PR 3 会扩成 `[(PullWorker, WSNotificationClient)]` 对。
public final class MeshSupervisor: @unchecked Sendable {
    /// 配置好的 PullWorker actor 列表。每个 actor 锚定一个 peer。
    /// 初始化后不变；并发读 OK，@unchecked Sendable 因为 Swift 不能从 final class
    /// 自动推出"不可变 array of actor 是 Sendable"。
    public let workers: [PullWorker]
    private let log: @Sendable (String) -> Void

    public init(
        workers: [PullWorker],
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("mesh: \(msg)\n".utf8))
        }
    ) {
        self.workers = workers
        self.log = log
    }

    /// 启动所有 worker。每个 PullWorker.start() 内部 guard 重入，多次调用幂等。
    /// 并发启动各自的 runLoop（actor 间互不阻塞）。
    public func start() async {
        log("starting \(workers.count) peer worker(s)")
        for w in workers {
            await w.start()
        }
    }

    /// 停所有 worker。每个 PullWorker.stop() 内部取消 currentSleep + runTask，
    /// 串行 await 是 OK 的——stop 是测试 / shutdown 路径，不需要并发优化。
    public func stop() async {
        for w in workers {
            await w.stop()
        }
        log("stopped all peer workers")
    }

    /// 外部触发"立即拉一次"（PR 3 WebSocket notify 路径）。每个 worker wake 自家 sleep。
    /// nonisolated 因为 PullWorker.wake() 是 nonisolated，supervisor 包装继承同语义。
    public func wakeAll() {
        for w in workers {
            w.wake()
        }
    }

    /// 当前 mesh 里活跃 peer 数（PR 2 = 配置 peer 数，PR 3 后可能扩展健康过滤）
    public var peerCount: Int { workers.count }
}

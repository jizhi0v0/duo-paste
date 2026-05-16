import Foundation
import DuoPasteCore
import DuoPasteSync

/// 进程级共享依赖。AppDelegate 在启动时构造一次后注入到所有需要的位置。
@MainActor
final class AppDependencies {
    let paths: Paths
    let config: Config
    let database: Database
    let blobs: BlobStore
    /// BlobStore 字节占用增量计数器。Settings 关于页订阅，put/evict 时 BlobStore 内部
    /// 自动喂数。baseline 由 AppDelegate 启动后 detached 扫盘任务建立
    let blobStats: BlobStorageStats
    let deviceID: String
    /// LRU blob 驱逐器。ENOSPC 时 capture / paste / pull 路径走它腾空间。
    /// **生产路径所有 BlobStore.put 都应走 retryingOnFull 变体** + 注入这个回调
    let evictor: BlobEvictor
    let evictOnFull: @Sendable () throws -> Bool
    let captureService: CaptureService
    let searchAPI: SearchAPI
    /// 搜索选择层。Mesh 拓扑下永远走本机 fold-aware 路径——item 表本身就是单表混存
    /// own + peer 行，`SearchAPI.searchHits/count/countByKind` 内部 text-fold 让两端口径一致。
    /// `mode` 显示靠 MeshStatus.oldestLastPullNs() 推断（nil = 还没追平任何 peer）。
    let searchProvider: SearchProvider
    /// Mesh peer PullWorker 跟 SearchProvider / UI 间的非阻塞状态通道。`mesh.enabled=false`
    /// 或 peers 空时这个对象永远不被 set，SearchProvider 走 `.local` mode（行为不变，只是 banner 文案变）。
    let meshStatus: MeshStatus
    /// 跨设备 paste-echo 抑制集合。AppDelegate.pasteBack 写入；PullWorker 应用 mirror 时查。
    let pasteSuppressions: PasteSuppressionSet
    /// PR 3：进程级共享 WS broadcaster。**eagerly 创建**——server 起之前 connections 集合
    /// 是空的，CaptureService 路径调 broadcastCursorAdvanced 自然 no-op；server 启动注入
    /// 同一个实例后，新 connection 注册进来 fan-out 才生效。
    /// 这样 CaptureService.onCursorAdvanced 不需要 Atomic<closure> 后置注入——闭包 capture
    /// broadcaster 引用即可
    let wsBroadcaster: WSBroadcaster

    init() throws {
        let paths = Paths.makeDefault()
        let deviceID = try DeviceID.loadOrCreate(at: paths.deviceIDFile)
        let config = try Config.load(from: paths.configFile)
        let database = try Database(path: paths.mainDB)
        let blobStats = BlobStorageStats()
        let blobs = BlobStore(root: paths.blobsDir, stats: blobStats)
        self.paths = paths
        self.config = config
        self.deviceID = deviceID
        self.database = database
        self.blobs = blobs
        self.blobStats = blobStats
        let evictor = BlobEvictor(
            database: database,
            blobs: blobs,
            log: { msg in
                FileHandle.standardError.write(Data("blob-evict: \(msg)\n".utf8))
            }
        )
        self.evictor = evictor
        let evictOnFull: @Sendable () throws -> Bool = { try evictor.evictOneOldest() }
        self.evictOnFull = evictOnFull
        // plan settings-cleanup：ws_rotation_sec 不再从 config 读，用 default 4h。
        // Auth rotation 是安全 hardening 不是用户调参点，硬编码合适
        let wsBroadcaster = WSBroadcaster(
            rotationIntervalSec: 4 * 3600
        )
        self.wsBroadcaster = wsBroadcaster
        // Sendable closure 给 CaptureService.onCursorAdvanced——primary 路径 commit 后触发，
        // 投递到 broadcaster fan-out 给所有连上的 peer。Task wrapper 让 actor 调用脱离
        // capture 路径同步等待
        self.captureService = CaptureService(
            database: database,
            blobs: blobs,
            deviceID: deviceID,
            limits: config.capture,
            onCursorAdvanced: { [wsBroadcaster, deviceID] ns in
                Task {
                    await wsBroadcaster.broadcastCursorAdvanced(
                        deviceID: deviceID,
                        latestIngestedAtNs: ns
                    )
                }
            },
            evictOnFull: evictOnFull
        )
        let searchAPI = SearchAPI(database: database)
        self.searchAPI = searchAPI
        let meshStatus = MeshStatus()
        self.meshStatus = meshStatus
        self.pasteSuppressions = PasteSuppressionSet()

        // PR 6 之后 SearchProvider 永远走本机 fold-aware，没有 remote 路径——chip 总数
        // 跨设备口径一致是 plan §"Search 改动"硬不变量
        self.searchProvider = SearchProvider(
            local: searchAPI,
            oldestPeerLastPullNs: { [meshStatus] in meshStatus.oldestLastPullNs() }
        )
    }

    /// 进程级共享 URLSession，PullWorker / WSNotificationClient / paste blob fetcher 共用——
    /// 确保 keep-alive 连接池跨用例复用，避免每次新建 TLS 握手。
    /// timeoutIntervalForRequest=10s：单次 /since / /blob 不该卡用户太久。
    static let syncURLSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.urlCache = nil               // search 永远要最新的，不走 URL cache
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "duo-paste/sync"]
        return URLSession(configuration: cfg)
    }()
}

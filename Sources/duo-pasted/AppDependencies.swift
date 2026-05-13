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
    let deviceID: String
    let captureService: CaptureService
    let searchAPI: SearchAPI
    /// 搜索选择层。standalone / pure-primary 时 remote=nil → 等价直接打本地。
    /// `pull.enabled=true` 时 mirrorStatus 通过 PullWorker 更新 → SearchProvider 看到非 nil
    /// 自动切 union 本地路径，不再过远端。
    let searchProvider: SearchProvider
    /// Mesh peer PullWorker 跟 SearchProvider / UI 间的非阻塞状态通道。`pull.enabled=false`
    /// 时这个对象永远不被 set → SearchProvider 走原 .local / .remoteOK 逻辑。多 peer 部署下
    /// SearchProvider 看 `oldestLastPullNs()`（最悲观）—— 任一 peer 还没追平就不走 localMirror。
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
        let database = try Database(path: paths.mainDB, role: config.derivedDatabaseRole)
        let blobs = BlobStore(root: paths.blobsDir)
        self.paths = paths
        self.config = config
        self.deviceID = deviceID
        self.database = database
        self.blobs = blobs
        let wsBroadcaster = WSBroadcaster()
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
            }
        )
        let searchAPI = SearchAPI(database: database)
        self.searchAPI = searchAPI
        let meshStatus = MeshStatus()
        self.meshStatus = meshStatus
        self.pasteSuppressions = PasteSuppressionSet()

        // primary_url 配置好且能加载到 shared secret → 准备远端搜索；否则 nil 走本地
        var remote: SearchTransport? = nil
        if let primaryURL = config.primaryURL {
            if let secret = try? SharedSecret.load(from: paths.sharedSecretFile) {
                remote = HTTPIngestClient(
                    baseURL: primaryURL,
                    auth: HMACAuth(secret: secret),
                    session: Self.syncURLSession
                )
            } else {
                fputs("search remote disabled: shared-secret load failed\n", stderr)
            }
        }
        self.searchProvider = SearchProvider(
            local: searchAPI,
            remote: remote,
            mirrorLastPullNs: { [meshStatus] in meshStatus.oldestLastPullNs() }
        )
    }

    /// 进程级共享 URLSession，push worker 和 search 都用同一个——确保 keep-alive
    /// 连接池跨用例复用，避免每次新建 TLS 握手。
    /// timeoutIntervalForRequest=10s：search keystroke 不该卡用户太久，
    /// 超时即降级本地比让 UI 等死好。
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

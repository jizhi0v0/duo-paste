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
    /// Pull worker 跟 SearchProvider 间的非阻塞状态通道。`pull.enabled=false` 时这个对象
    /// 永远不被 set → SearchProvider 走原 .local / .remoteOK 逻辑。
    let mirrorStatus: MirrorStatus

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
        self.captureService = CaptureService(
            database: database,
            blobs: blobs,
            deviceID: deviceID
        )
        let searchAPI = SearchAPI(database: database)
        self.searchAPI = searchAPI
        let mirrorStatus = MirrorStatus()
        self.mirrorStatus = mirrorStatus

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
            mirrorLastPullNs: { [mirrorStatus] in mirrorStatus.lastPullNs() }
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

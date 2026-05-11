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
    /// 搜索选择层。standalone 模式下 remote=nil → 等价直接打本地。
    let searchProvider: SearchProvider

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

        // primary_url 配置好且能加载到 shared secret → 准备远端搜索；否则 nil 走本地
        var remote: SearchTransport? = nil
        if let primaryURL = config.primaryURL {
            if let secret = try? SharedSecret.load(from: paths.sharedSecretFile) {
                remote = HTTPIngestClient(baseURL: primaryURL, auth: HMACAuth(secret: secret))
            } else {
                fputs("search remote disabled: shared-secret load failed\n", stderr)
            }
        }
        self.searchProvider = SearchProvider(local: searchAPI, remote: remote)
    }
}

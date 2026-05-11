import Foundation
import DuoPasteCore

/// 进程级共享依赖。AppDelegate 在启动时构造一次后注入到所有需要的位置。
@MainActor
final class AppDependencies {
    let paths: Paths
    let database: Database
    let blobs: BlobStore
    let deviceID: String
    let captureService: CaptureService
    let searchAPI: SearchAPI

    init() throws {
        let paths = Paths.makeDefault()
        let deviceID = try DeviceID.loadOrCreate(at: paths.deviceIDFile)
        let database = try Database(path: paths.mainDB, role: .primary)
        let blobs = BlobStore(root: paths.blobsDir)
        self.paths = paths
        self.deviceID = deviceID
        self.database = database
        self.blobs = blobs
        self.captureService = CaptureService(
            database: database,
            blobs: blobs,
            deviceID: deviceID
        )
        self.searchAPI = SearchAPI(database: database)
    }
}

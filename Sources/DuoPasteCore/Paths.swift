import Foundation

/// 应用所有持久化数据的根路径布局。
/// 单例式工厂：默认走 Application Support，测试时可注入临时目录。
public struct Paths: Sendable {
    public let root: URL
    public let dbDir: URL
    public let blobsDir: URL
    public let thumbsDir: URL
    public let snapshotsDir: URL

    public var mainDB: URL { dbDir.appendingPathComponent("main.sqlite") }
    public var deviceIDFile: URL { root.appendingPathComponent("device-id") }
    public var configFile: URL { root.appendingPathComponent("config.json") }
    public var sharedSecretFile: URL { root.appendingPathComponent("shared-secret") }

    public init(root: URL) {
        self.root = root
        self.dbDir = root.appendingPathComponent("db")
        self.blobsDir = root.appendingPathComponent("blobs")
        self.thumbsDir = root.appendingPathComponent("thumbs")
        self.snapshotsDir = root.appendingPathComponent("snapshots")
    }

    public static func defaultRoot() -> URL {
        let fm = FileManager.default
        let support = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("duo-paste", isDirectory: true)
    }

    public static func makeDefault() -> Paths {
        let p = Paths(root: defaultRoot())
        p.ensureExists()
        return p
    }

    public func ensureExists() {
        let fm = FileManager.default
        for dir in [root, dbDir, blobsDir, thumbsDir, snapshotsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

import Foundation
import CryptoKit

public struct BlobInfo: Sendable, Hashable {
    public let sha256: String
    public let size: Int64
    public let path: URL
    public let wasExisting: Bool
}

public struct BlobStore: Sendable {
    public let root: URL
    /// 字节占用增量计数器。Settings 关于页订阅这个 actor 推送，put/evict 写盘事件直接喂入。
    /// nil = 不维护计数器（CLI 一次性命令、单测路径），生产 daemon 路径必须注入。
    public let stats: BlobStorageStats?

    public init(root: URL, stats: BlobStorageStats? = nil) {
        self.root = root
        self.stats = stats
    }

    public func path(for sha256: String, ext: String? = nil) -> URL {
        precondition(sha256.count == 64, "sha256 must be 64 hex chars")
        let a = String(sha256.prefix(2))
        let b = String(sha256.dropFirst(2).prefix(2))
        var name = sha256
        if let ext, !ext.isEmpty {
            name += "." + ext
        }
        return root
            .appendingPathComponent(a, isDirectory: true)
            .appendingPathComponent(b, isDirectory: true)
            .appendingPathComponent(name)
    }

    /// 不带扩展名的目录路径解析（用来在已知 sha256 时定位"任意扩展"的文件）。
    public func locate(sha256: String) -> URL? {
        let a = String(sha256.prefix(2))
        let b = String(sha256.dropFirst(2).prefix(2))
        let dir = root
            .appendingPathComponent(a, isDirectory: true)
            .appendingPathComponent(b, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return nil
        }
        for name in entries where name.hasPrefix(sha256) {
            return dir.appendingPathComponent(name)
        }
        return nil
    }

    public func exists(sha256: String) -> Bool {
        locate(sha256: sha256) != nil
    }

    @discardableResult
    public func put(_ data: Data, ext: String? = nil) throws -> BlobInfo {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return try writeBlob(data: data, sha256Hex: hex, ext: ext)
    }

    /// `put` 的防御版本：在算 sha 之前先比对 `expectedSha`，不匹配直接 throw。
    /// 用于 lazy GET /blob 拉来的字节落盘——content-addressed 不变量要求接收端再
    /// 校验一次（HTTPPeerClient.getBlob 内部已校验，但调用方主动 verify 是补强）。
    @discardableResult
    public func putVerified(_ data: Data, expectedSha256: String, ext: String? = nil) throws -> BlobInfo {
        precondition(expectedSha256.count == 64, "sha256 must be 64 hex chars")
        let digest = SHA256.hash(data: data)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        guard actualHex == expectedSha256 else {
            throw BlobStoreError.shaMismatch(expected: expectedSha256, actual: actualHex)
        }
        return try writeBlob(data: data, sha256Hex: actualHex, ext: ext)
    }

    /// 唯一的真写盘路径——put / putVerified 都收敛到这里。
    ///
    /// 并发契约（同一 sha 两个 caller 同时进来）：
    ///   - 第一个 link 成功 → wasExisting=false + notifyAdded
    ///   - 第二个 linkItem 失败（EEXIST，因为 target 已被赢家占）→ 视为竞态丢方，
    ///     **返回 wasExisting=true 且不调 notifyAdded**（字节已被赢家计入，BlobStorageStats
    ///     重复计数会让 UI 仓库占用虚增）
    ///
    /// 用 linkItem 而**不**用 moveItem：POSIX rename(2) 是 atomic replace，dst 已存在时
    /// 不报错而是覆盖，竞态丢方根本没机会进 catch；linkItem 走 link(2)，dst 已存在时
    /// 必定 EEXIST，才是真正的 "exclusive create" 语义。tmp 无论 link 成败都 cleanup
    private func writeBlob(data: Data, sha256Hex hex: String, ext: String?) throws -> BlobInfo {
        let target = path(for: hex, ext: ext)
        let fm = FileManager.default

        if let existing = locate(sha256: hex) {
            return try existingBlobInfo(at: existing, hex: hex, fallbackSize: Int64(data.count))
        }
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".tmp." + UUID().uuidString)
        try data.write(to: tmp, options: [.atomic])
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.linkItem(at: tmp, to: target)
        } catch {
            if fm.fileExists(atPath: target.path) {
                return try existingBlobInfo(at: target, hex: hex, fallbackSize: Int64(data.count))
            }
            throw error
        }
        let written = BlobInfo(
            sha256: hex,
            size: Int64(data.count),
            path: target,
            wasExisting: false
        )
        notifyAdded(written.size)
        return written
    }

    /// 已存在 blob 的 BlobInfo 构造统一入口。attrs 读取失败时退化到 fallbackSize（caller
    /// 传 data.count）以保证调用方不抛 IO 错误—— short-circuit 路径是"读 size 给 UI"的
    /// 不严格场景
    private func existingBlobInfo(at url: URL, hex: String, fallbackSize: Int64) throws -> BlobInfo {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? fallbackSize
        return BlobInfo(sha256: hex, size: size, path: url, wasExisting: true)
    }

    public func read(sha256: String) throws -> Data? {
        guard let url = locate(sha256: sha256) else { return nil }
        return try Data(contentsOf: url)
    }

    /// 读 blob 文件字节数。不存在返回 nil（区别于 0 字节文件）。
    public func size(sha256: String) -> Int64? {
        guard let url = locate(sha256: sha256) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    /// 物理删 blob 文件。**只删 fs，不动 DB 行**——`item.blob_sha256` 保留指向该 sha，
    /// `BlobStore.exists()` 之后返回 false → UI 落到 CloudBadge（"云端"）状态 → Enter 走
    /// lazy 路径从 peer 重拉。这是磁盘水位驱逐 / tombstone GC 的底层原语。
    ///
    /// Returns: `.deleted(size)` 删成功 + 字节数；`.notFound` 文件不在；`.failed(err)` 删失败。
    /// 不抛错：caller 通常在循环里跑（驱逐到水位达标），单文件失败不该中断整轮
    @discardableResult
    public func evict(sha256: String) -> EvictOutcome {
        guard let url = locate(sha256: sha256) else { return .notFound }
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        do {
            try fm.removeItem(at: url)
            notifyRemoved(size)
            return .deleted(size: size)
        } catch {
            return .failed(error)
        }
    }

    public enum EvictOutcome: Sendable {
        case deleted(size: Int64)
        case notFound
        case failed(Error)
    }

    /// `put` 的 ENOSPC 重试包装：磁盘满时调 `evictor()` 释放一个 LRU blob 后重试，
    /// 循环直到成功 / evictor 返回 false / 达到 maxRetries。
    /// 非 ENOSPC 错误立即重抛——不要把其它写盘问题（权限 / I/O 错误）当成空间问题
    /// 反复 evict
    @discardableResult
    public func putRetryingOnFull(
        _ data: Data,
        ext: String? = nil,
        maxRetries: Int = 64,
        evictor: () throws -> Bool
    ) throws -> BlobInfo {
        try Self.retryOnFull(maxRetries: maxRetries, evictor: evictor) {
            try self.put(data, ext: ext)
        }
    }

    /// `putVerified` 的 ENOSPC 重试包装——同 putRetryingOnFull 行为
    @discardableResult
    public func putVerifiedRetryingOnFull(
        _ data: Data,
        expectedSha256: String,
        ext: String? = nil,
        maxRetries: Int = 64,
        evictor: () throws -> Bool
    ) throws -> BlobInfo {
        try Self.retryOnFull(maxRetries: maxRetries, evictor: evictor) {
            try self.putVerified(data, expectedSha256: expectedSha256, ext: ext)
        }
    }

    /// 写盘成功钩子 —— 起 detached Task 喂 BlobStorageStats actor，让 Settings 关于页
    /// 不用扫盘就能即时刷新"Blob 仓库占用"。stats=nil（CLI / 单测路径）时 no-op。
    /// 起 Task 而非改方法 async：BlobStore.put 在生产路径都被 sync caller 调用（包括
    /// retryOnFull 闭包内嵌），改 async 会污染整条调用链
    private func notifyAdded(_ size: Int64) {
        guard let stats else { return }
        Task { await stats.add(size) }
    }

    private func notifyRemoved(_ size: Int64) {
        guard let stats else { return }
        Task { await stats.sub(size) }
    }

    /// 内部 retry loop。**internal access** 让单测注入 mock put 闭包验证循环骨架——
    /// 真做 ENOSPC 仿真要 dd if=/dev/zero 占满 tmp 卷，CI 不可控
    @discardableResult
    static func retryOnFull(
        maxRetries: Int,
        evictor: () throws -> Bool,
        put: () throws -> BlobInfo
    ) throws -> BlobInfo {
        var retries = 0
        while true {
            do {
                return try put()
            } catch {
                guard DiskFull.isOutOfSpace(error) else {
                    throw error
                }
                guard retries < maxRetries, try evictor() else {
                    throw error
                }
                retries += 1
            }
        }
    }
}

public enum BlobStoreError: Error, CustomStringConvertible, Sendable {
    case shaMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .shaMismatch(let e, let a):
            return "BlobStore: expected sha=\(e), actual=\(a)"
        }
    }
}

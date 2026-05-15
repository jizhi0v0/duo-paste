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

    public init(root: URL) {
        self.root = root
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
        let target = path(for: hex, ext: ext)
        let fm = FileManager.default

        if let existing = locate(sha256: hex) {
            let attrs = try fm.attributesOfItem(atPath: existing.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
            return BlobInfo(sha256: hex, size: size, path: existing, wasExisting: true)
        }

        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 原子写：先写临时文件再 rename
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".tmp." + UUID().uuidString)
        try data.write(to: tmp, options: [.atomic])
        // 目标若被竞争创建，仍认为是成功的；保留已存在文件
        do {
            try fm.moveItem(at: tmp, to: target)
        } catch {
            if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: tmp)
            } else {
                throw error
            }
        }
        return BlobInfo(
            sha256: hex,
            size: Int64(data.count),
            path: target,
            wasExisting: false
        )
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
        // 已经算出 hex，直接走内部写盘路径避免重算
        return try writeBlob(data: data, sha256Hex: actualHex, ext: ext)
    }

    /// 把 sha 已知的 data 落盘。内部使用，跳过算 sha 重复劳动。
    private func writeBlob(data: Data, sha256Hex hex: String, ext: String?) throws -> BlobInfo {
        let target = path(for: hex, ext: ext)
        let fm = FileManager.default

        if let existing = locate(sha256: hex) {
            let attrs = try fm.attributesOfItem(atPath: existing.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
            return BlobInfo(sha256: hex, size: size, path: existing, wasExisting: true)
        }
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".tmp." + UUID().uuidString)
        try data.write(to: tmp, options: [.atomic])
        do {
            try fm.moveItem(at: tmp, to: target)
        } catch {
            if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: tmp)
            } else {
                throw error
            }
        }
        return BlobInfo(
            sha256: hex,
            size: Int64(data.count),
            path: target,
            wasExisting: false
        )
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

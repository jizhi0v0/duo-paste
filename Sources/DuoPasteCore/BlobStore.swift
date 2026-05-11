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

    public func read(sha256: String) throws -> Data? {
        guard let url = locate(sha256: sha256) else { return nil }
        return try Data(contentsOf: url)
    }
}

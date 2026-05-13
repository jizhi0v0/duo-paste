import Foundation
import Security
import GRDB

/// 运维子命令的核心逻辑：纯函数 + 显式路径注入，方便单测。
/// CLI 包装层（duo-pasted/CLI.swift）只负责 argv 解析 + exit。
///
/// PR 4 之后只剩 `initSecret` + `retryFailedOCR`。push 链路相关命令（promote-to-primary /
/// migrate-primary / audit-push / retry-failed）随 PushWorker / RemoteIngester 一起删。
public enum Admin {
    public struct InitSecretResult: Equatable, Sendable {
        public let path: URL
        public let replaced: Bool
    }

    public enum AdminError: Error, CustomStringConvertible, Sendable {
        case alreadyExists(path: URL)
        case randomFailed(osstatus: Int32)

        public var description: String {
            switch self {
            case .alreadyExists(let p): return "\(p.path) 已存在；用 --force 覆盖"
            case .randomFailed(let s):  return "SecRandomCopyBytes 失败 (OSStatus=\(s))"
            }
        }
    }

    /// 生成 32 字节随机 secret，写到 path（hex 编码 + 0600 权限）。
    /// 已存在且 force=false → throw alreadyExists；否则覆盖（atomic）。
    @discardableResult
    public static func initSecret(at path: URL, force: Bool) throws -> InitSecretResult {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: path.path)
        if existed && !force {
            throw AdminError.alreadyExists(path: path)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AdminError.randomFailed(osstatus: status)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try fm.createDirectory(at: path.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try (hex + "\n").data(using: .utf8)!.write(to: path, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return InitSecretResult(path: path, replaced: existed)
    }

    /// OCR 重试范围。`all` 把所有 own-origin 的 image 行里 `ocr_state IN ('failed', 'skipped')`
    /// 全部翻回 pending；`id(_)` 是单条手动 override（无视当前 state 黑名单——用户显式指定就
    /// 信任）
    public enum OCRRetryScope: Sendable, Equatable {
        case all
        case id(String)
    }

    /// 把 OCR `failed` / `skipped` 行重置回 pending 让 OCRWorker 重新扫。
    ///
    /// - `scope=.all`：仅本机 own-origin 的 image kind 且 ocr_state 落 failed/skipped。
    ///   排除：tombstone（deleted_at_ns != nil）/ 非 image / 非 own-origin（别人家的行
    ///   由对端 worker 负责）/ 已 pending（无需翻）/ done（用户没显式指定别动它）。
    /// - `scope=.id(_)`：只看 id + kind=image + `origin_device = selfDeviceID`
    ///   + `deleted_at_ns IS NULL`。无视 state——用户敲了 id 就是手动 override，
    ///   包括把 done 翻成 pending 重 OCR 的场景。但仍守 origin / tombstone：
    ///   OCRWorker.fetchPending 也只扫 own-origin + 非软删，翻 remote-origin /
    ///   tombstone 的 ocr_state 没人处理会永卡 pending
    ///
    /// **不** bump ingested_at_ns——重置本身不改 item 内容；worker 真跑 OCR 写
    /// text_full 时再 bump。
    ///
    /// - Returns: 受影响的行数
    public static func retryFailedOCR(
        dbPath: URL,
        selfDeviceID: String,
        scope: OCRRetryScope
    ) throws -> Int {
        let db = try Database(path: dbPath)
        return try db.pool.write { conn -> Int in
            switch scope {
            case .all:
                try conn.execute(sql: """
                    UPDATE item
                    SET ocr_state = 'pending'
                    WHERE origin_device = ?
                      AND kind = 'image'
                      AND ocr_state IN ('failed', 'skipped')
                      AND deleted_at_ns IS NULL
                """, arguments: [selfDeviceID])
            case .id(let id):
                // origin_device + deleted_at_ns guard 与 .all 路径对齐：单条重置也只
                // 翻本机 own-origin 且未软删的行，避免把 remote-origin / tombstone 翻回
                // pending 但 OCRWorker.fetchPending 不扫导致永卡
                try conn.execute(sql: """
                    UPDATE item
                    SET ocr_state = 'pending'
                    WHERE id = ?
                      AND origin_device = ?
                      AND kind = 'image'
                      AND deleted_at_ns IS NULL
                """, arguments: [id, selfDeviceID])
            }
            return conn.changesCount
        }
    }
}

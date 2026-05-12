import Foundation
import Security
import GRDB

/// 运维子命令的核心逻辑：纯函数 + 显式路径注入，方便单测。
/// CLI 包装层（duo-pasted/CLI.swift）只负责 argv 解析 + exit。
public enum Admin {
    public struct InitSecretResult: Equatable, Sendable {
        public let path: URL
        public let replaced: Bool
    }

    public enum AdminError: Error, CustomStringConvertible, Sendable {
        case alreadyExists(path: URL)
        case randomFailed(osstatus: Int32)
        case notInClientMode(currentSummary: String)
        case readConfigFailed(underlying: String)
        case writeConfigFailed(underlying: String)
        case invalidPostConfig(reason: String)

        public var description: String {
            switch self {
            case .alreadyExists(let p): return "\(p.path) 已存在；用 --force 覆盖"
            case .randomFailed(let s):  return "SecRandomCopyBytes 失败 (OSStatus=\(s))"
            case .notInClientMode(let s):
                return "promote-to-primary 仅在 client 模式下可用（当前：\(s)）"
            case .readConfigFailed(let u):
                return "读 config 失败：\(u)"
            case .writeConfigFailed(let u):
                return "写 config 失败：\(u)"
            case .invalidPostConfig(let r):
                return "promote 后 config 状态非法：\(r)"
            }
        }
    }

    public struct PromoteResult: Equatable, Sendable {
        /// `INSERT OR IGNORE INTO item SELECT FROM item_mirror` 真正插入的行数。
        public let promotedRows: Int
        /// 被清空的 item_mirror 行数（信息性）。
        public let mirrorClearedRows: Int
        /// pull_cursor 里读到的老 primary device_id。空字符串/nil → 之前从未拉过。
        public let lineageOldPrimaryID: String?
        /// self 任期起始 ns（= 调用 promote 时传入的 `now`）。
        public let lineageStartedAtNs: Int64
        /// 改写后的 config.json 路径。
        public let configWrittenTo: URL
        /// 被清除的原 primary URL（信息性，用于打印）。
        public let oldPrimaryURL: URL?
    }

    /// 把本机从 client 提升为 primary。详 plan §c。
    ///
    /// 流程（writer tx 内一次性做完，前 4 步原子）：
    /// 1. 校验当前 config 为 client 模式（`primary_url` 非空），否则 throw
    /// 2. `INSERT OR IGNORE INTO item SELECT ... FROM item_mirror`
    ///    - 保留 `origin_device`（这些条目仍归属原捕获设备）
    ///    - `push_state` 一律设 `'acked'`：本机变 primary 后没上游可推，留 pending 会被
    ///      想象中的 PushWorker 不停尝试推空气；实际新 config 已经把 primary_url 清掉，
    ///      PushWorker 根本不启动，但保持 push_state 状态一致仍是正确做法
    /// 3. 清空 `item_mirror` + `pull_cursor`
    /// 4. 写两行 `primary_lineage`：
    ///    - `(self, now, NULL)` 开当前任期
    ///    - `(old_primary, 0, now)` 闭老 primary 任期（如果 pull_cursor 里有 primary_id 记录）
    /// 5. 改写 config.json：移除 primary_url、`serve=true`、`pull.enabled=false`；可选覆盖
    ///    serve_host/port。其余字段（capture.* / tls 路径 / shared_secret_keychain_account /
    ///    任何手动加的非 Config 字段）走 `Config.write` 的"保留未知字段"路径全部保留。
    ///
    /// **不动**：shared-secret 文件、LaunchAgent 配置、blobs/ 目录。调用方负责 kickstart
    /// daemon 重读配置（CLI wrapper 打印提示）。
    public static func promoteToPrimary(
        dbPath: URL,
        configPath: URL,
        selfDeviceID: String,
        now: Int64,
        serveHost: String? = nil,
        servePort: Int? = nil
    ) throws -> PromoteResult {
        let current: Config
        do {
            current = try Config.load(from: configPath)
        } catch {
            throw AdminError.readConfigFailed(underlying: String(describing: error))
        }

        guard current.primaryURL != nil else {
            throw AdminError.notInClientMode(currentSummary: current.summary)
        }
        let oldPrimaryURL = current.primaryURL

        // Database.init 自动跑 migrator——确保 v5 primary_lineage 表已建
        let db = try Database(path: dbPath, role: .client)
        let (promoted, cleared, oldPrimaryID): (Int, Int, String?) = try db.pool.write { conn in
            // a. 读 pull_cursor 老 primary_id（在删之前）。pull_cursor 至多 1 行。
            let oldID = try String.fetchOne(
                conn,
                sql: "SELECT primary_id FROM pull_cursor LIMIT 1"
            )

            // b. item_mirror → item。SELECT 显式列出 14 mirror 字段 + 3 个 push 字段常量值，
            //    顺序对齐 item 表 schema。push_state 'acked' 见 doc。
            try conn.execute(sql: """
                INSERT OR IGNORE INTO item (
                    id, origin_device, captured_at_ns, ingested_at_ns,
                    kind, source_app, source_app_name,
                    preview, text_full,
                    blob_sha256, blob_size, blob_mime,
                    pinned, deleted_at_ns,
                    push_state, push_attempts, last_push_error
                )
                SELECT
                    id, origin_device, captured_at_ns, ingested_at_ns,
                    kind, source_app, source_app_name,
                    preview, text_full,
                    blob_sha256, blob_size, blob_mime,
                    pinned, deleted_at_ns,
                    'acked', 0, NULL
                FROM item_mirror
            """)
            let promotedRows = conn.changesCount

            // c. 清空 mirror + cursor。FTS 触发器同步清 item_mirror_fts，免费。
            try conn.execute(sql: "DELETE FROM item_mirror")
            let clearedRows = conn.changesCount
            try conn.execute(sql: "DELETE FROM pull_cursor")

            // d. 写 lineage 行。self 用 INSERT OR IGNORE 避免重复 promote 同一 ns 时报错；
            //    现实中 now 是 wall-clock ns，两次调用同 ns 概率极小，但理论上 IGNORE 仍是
            //    最安全的并发兜底（与 retryFailed 等其它 admin 子命令一致的幂等姿态）。
            try conn.execute(sql: """
                INSERT OR IGNORE INTO primary_lineage(device_id, started_at_ns, ended_at_ns)
                VALUES (?, ?, NULL)
            """, arguments: [selfDeviceID, now])

            // 闭老 primary 任期。started_at_ns=0 表示"未知起点"——audit-push 的 lineage 查询
            // 用 `device_id IN (...)` 不依赖 started 的精确值。oldID == self 时（本机以前曾
            // 作为 primary，被自己再 promote 一次的边界情况）不重写，避免覆盖更准确的旧记录。
            if let oldID, !oldID.isEmpty, oldID != selfDeviceID {
                try conn.execute(sql: """
                    INSERT OR IGNORE INTO primary_lineage(device_id, started_at_ns, ended_at_ns)
                    VALUES (?, 0, ?)
                """, arguments: [oldID, now])
            }

            return (promotedRows, clearedRows, oldID)
        }

        // e. 改写 config.json
        var next = current
        next.primaryURL = nil
        next.serve = true
        if let h = serveHost { next.serveHost = h }
        if let p = servePort { next.servePort = p }
        next.pull.enabled = false

        do {
            try Config.write(next, to: configPath)
        } catch let e as ConfigError {
            throw AdminError.invalidPostConfig(reason: e.description)
        } catch {
            throw AdminError.writeConfigFailed(underlying: String(describing: error))
        }

        return PromoteResult(
            promotedRows: promoted,
            mirrorClearedRows: cleared,
            lineageOldPrimaryID: (oldPrimaryID?.isEmpty == false) ? oldPrimaryID : nil,
            lineageStartedAtNs: now,
            configWrittenTo: configPath,
            oldPrimaryURL: oldPrimaryURL
        )
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

    /// 把 `push_state='failed'` 的 item 重置成 pending、清空错误状态。
    /// - Returns: 受影响的行数
    public static func retryFailed(dbPath: URL) throws -> Int {
        let db = try Database(path: dbPath, role: .client)
        return try db.pool.write { conn -> Int in
            try conn.execute(sql: """
                UPDATE item
                SET push_state = 'pending',
                    push_attempts = 0,
                    last_push_error = NULL
                WHERE push_state = 'failed'
            """)
            return conn.changesCount
        }
    }
}

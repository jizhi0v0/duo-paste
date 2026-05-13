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
        /// migrate-primary 仅老 primary 上跑（serve=true && primary_url=nil）。
        /// 在 client / standalone 模式下调用会拒绝——不在 primary 模式下没有 DB 可迁移
        case notInPrimaryMode(currentSummary: String)
        case readConfigFailed(underlying: String)
        case writeConfigFailed(underlying: String)
        case invalidPostConfig(reason: String)
        /// promote 预检阶段发现 mirror/item 表里有 blob_sha256 非空但 BlobStore 没字节的行。
        /// PullWorker 默认 eager_blobs=false 只镜像元数据，本机变 primary 后这些 blob 在
        /// `/blob/<sha>` 上是 404。默认拒绝；`allowMissingBlobs=true` 跳过此检查并继续。
        case missingBlobs(totalMissing: Int, samples: [String])
        /// LaunchAgent daemon 还在跑——
        /// - promote 路径：daemon 仍以 client 角色 capture 新行（那些行 ingested_at_ns=nil，
        ///   stamp 阶段已经过去，PushWorker promote 后不启动），这些行将永远不被 /since 暴露
        /// - migrate 路径：daemon 仍以 primary 角色继续 ingest，VACUUM INTO snapshot 完成
        ///   后老 primary 又有新行，rsync 到新机时这部分数据丢失
        /// 两条路径都要求先 `launchctl bootout` 停掉再重试
        case daemonRunning(label: String)

        public var description: String {
            switch self {
            case .alreadyExists(let p): return "\(p.path) 已存在；用 --force 覆盖"
            case .randomFailed(let s):  return "SecRandomCopyBytes 失败 (OSStatus=\(s))"
            case .notInClientMode(let s):
                return "promote-to-primary 仅在 client 模式下可用（当前：\(s)）"
            case .notInPrimaryMode(let s):
                return "migrate-primary 仅在 primary 模式下可用（当前：\(s)）"
            case .readConfigFailed(let u):
                return "读 config 失败：\(u)"
            case .writeConfigFailed(let u):
                return "写 config 失败：\(u)"
            case .invalidPostConfig(let r):
                return "promote 后 config 状态非法：\(r)"
            case .missingBlobs(let total, let samples):
                let head = samples.prefix(3).joined(separator: ", ")
                return "promote 中止：\(total) 个 blob 在本机 BlobStore 缺失 "
                    + "（示例 sha：\(head)\(samples.count > 3 ? " ..." : "")）。"
                    + "image/file 类历史在 promote 后会 404。"
                    + "若可接受丢失，加 --allow-missing-blobs 重跑。"
            case .daemonRunning(let label):
                return "操作中止：daemon (\(label)) 还在跑。"
                    + "在 promote/migrate 路径上 daemon 继续 capture/ingest 会让本次操作之后"
                    + "落地的数据被静默丢弃。先停 daemon：\n"
                    + "  launchctl bootout gui/$UID/\(label)\n"
                    + "再重试。"
            }
        }
    }

    public struct MigratePrimaryResult: Equatable, Sendable {
        /// VACUUM INTO 落地的快照文件绝对路径。CLI 把这个路径拼进 rsync 命令模板。
        public let snapshotPath: URL
        /// 快照文件字节数，让操作员对"要传多大"心里有数
        public let snapshotBytes: Int64
        /// blobs 内容寻址目录的根路径，rsync 时整体拷贝
        public let blobsRoot: URL
        /// blobs 目录下的文件总数（递归）
        public let blobsTotalFiles: Int
        /// blobs 目录下的字节总数（递归）
        public let blobsTotalBytes: Int64
        /// 当前 item 表行数（含软删 tombstone），信息性
        public let itemRowCount: Int
        /// 当前 item_mirror 行数。primary 模式下应该是 0；非 0 说明本机历史上曾是 client，
        /// 残留没清干净——VACUUM INTO 出去的快照会带上这些 mirror 行，新 primary 上跑
        /// promote-to-primary 时它们会被合并进 item。信息性披露
        public let itemMirrorRowCount: Int
    }

    public struct PromoteResult: Equatable, Sendable {
        /// `INSERT OR IGNORE INTO item SELECT FROM item_mirror` 真正插入的行数。
        public let promotedRows: Int
        /// 被清空的 item_mirror 行数（信息性）。
        public let mirrorClearedRows: Int
        /// 本次 promote 中被补 stamp `ingested_at_ns` 的 item 行总数。覆盖 client 路径
        /// 老遗留的 own-origin 行（CaptureService 在 .client role 下从不 stamp，详见
        /// CaptureService.swift line 121-122）以及刚 INSERT 进来但 mirror 表也是 nil 的
        /// 异常 mirror 行。stamp 完这些行才能被 `/since` 流拉走给其它 client。
        public let stampedRows: Int
        /// pull_cursor 里读到的老 primary device_id。空字符串/nil → 之前从未拉过。
        public let lineageOldPrimaryID: String?
        /// self 任期起始 ns（= 调用 promote 时传入的 `now`）。
        public let lineageStartedAtNs: Int64
        /// 改写后的 config.json 路径。
        public let configWrittenTo: URL
        /// 被清除的原 primary URL（信息性，用于打印）。
        public let oldPrimaryURL: URL?
        /// 预检阶段发现 BlobStore 缺字节的去重 sha256 总数。`allowMissingBlobs=true`
        /// 时会进入 promote 流程，CLI 渲染 warning；`=false` 时不应进入这里——已经
        /// throw `missingBlobs` 中止。
        public let missingBlobsTotal: Int
        /// 缺失 sha 样本，最多 `missingBlobSampleLimit` 条
        public let missingBlobsSamples: [String]
    }

    /// 把本机从 client 提升为 primary。详 plan §c。
    ///
    /// 流程（一个 writer tx 包住 step 4-8，原子）：
    /// 1. 校验当前 config 为 client 模式（`primary_url` 非空），否则 throw
    /// 1b. **daemon-running 检查**（P1 review fix）：调用方（CLI 层）通过 `launchctl list`
    ///     拿 daemon 在跑状态后传 `daemonRunning`；为 true 直接 throw `daemonRunning`，要求
    ///     用户先 `launchctl bootout` 停掉再重试。**为什么必须停**：promote 跑完后到用户
    ///     手动 kickstart 之间存在窗口，daemon 仍以 client mode capture 新行（这些行
    ///     `ingested_at_ns=nil`，stamp 阶段已经过去）。promote 后 PushWorker 不再启动，
    ///     这些行也不会再被 stamp——永远过滤掉在 `/since` 之外
    /// 2. **预检 blob 缺失**（writer tx 外，只读）：扫 item + item_mirror 里 blob_sha256 非空
    ///    AND deleted_at_ns IS NULL 的行，去重 sha 集合，逐个 `blobs.exists` 检查。缺失
    ///    + `allowMissingBlobs=false` → throw `missingBlobs`；`=true` → 进入下一步，
    ///    缺失统计带进 PromoteResult 让 CLI 输出 warning。**理由**：PullWorker 默认
    ///    `eager_blobs=false` 只镜像元数据；本机变 primary 后 `/blob/<sha>` 找不到字节
    ///    即 404。预检让操作员先意识到 image/file 历史会丢
    /// 3. `INSERT OR IGNORE INTO item SELECT ... FROM item_mirror`
    ///    - 保留 `origin_device`（这些条目仍归属原捕获设备）
    ///    - 新行 `push_state='acked'`：本机变 primary 后没上游可推，pending 会让重新跑起来
    ///      的 PushWorker 误推
    /// 4. **stamp `ingested_at_ns` IS NULL 的所有 item 行**：覆盖两类
    ///    - client 路径捕获的 own-origin 老行：CaptureService 在 `.client` role 下从不
    ///      stamp（line 121-122），它们等 primary ACK 后只翻 `push_state`，`ingested_at_ns`
    ///      永远是 nil。promote 后 `/since` 流 `WHERE ingested_at_ns IS NOT NULL` 会把
    ///      这些行过滤掉——其它 client 拉不到这台机器的历史。这是 review 发现的 P1
    ///    - mirror INSERT 进来但 mirror 表本身 ns 为 nil 的异常行（防御）
    ///    用 `Database.nextIngestNs` 单调赋值，同步把 own 行的 push_state 拍成 acked
    ///    （没上游了）
    /// 5. 清空 `item_mirror` + `pull_cursor`
    /// 6. 写两行 `primary_lineage`：
    ///    - `(self, now, NULL)` 开当前任期
    ///    - `(old_primary, 0, now)` 闭老 primary 任期（如果 pull_cursor 里有 primary_id 记录）
    /// 7. 改写 config.json：移除 primary_url、`serve=true`、`pull.enabled=false`；可选覆盖
    ///    serve_host/port。其余字段（capture.* / tls 路径 / shared_secret_keychain_account /
    ///    任何手动加的非 Config 字段）走 `Config.write` 的"保留未知字段"路径全部保留
    ///
    /// **不动**：shared-secret 文件、LaunchAgent 配置、blobs/ 目录。调用方负责 kickstart
    /// daemon 重读配置（CLI wrapper 打印提示）。
    public static func promoteToPrimary(
        dbPath: URL,
        configPath: URL,
        blobs: BlobStore,
        selfDeviceID: String,
        now: Int64,
        serveHost: String? = nil,
        servePort: Int? = nil,
        allowMissingBlobs: Bool = false,
        missingBlobSampleLimit: Int = 5,
        daemonRunning: Bool = false,
        daemonLabel: String = "io.duopaste.agent"
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

        // Step 1.5: daemon-running 安全检查（P1 review fix）。daemon 在跑时拒绝 promote——
        // promote 期间 daemon 仍以 client 角色 capture 出的新行不会被 stamp 也不会被
        // PushWorker 推（promote 完 PushWorker 不再启动），永远卡在 ingested_at_ns=nil
        // 不被 /since 暴露。检测下沉到 CLI 层（调 launchctl），Admin 接 Bool 保持纯函数
        if daemonRunning {
            throw AdminError.daemonRunning(label: daemonLabel)
        }

        // Database.init 自动跑 migrator——确保 v5 primary_lineage 表已建
        let db = try Database(path: dbPath, role: .client)

        // Step 2: 预检 blob 缺失。tx 外只读，便于失败时不留任何痕迹。
        let (missingTotal, missingSamples) = try checkMissingBlobs(
            db: db,
            blobs: blobs,
            sampleLimit: missingBlobSampleLimit
        )
        if missingTotal > 0 && !allowMissingBlobs {
            throw AdminError.missingBlobs(totalMissing: missingTotal, samples: missingSamples)
        }

        let (promoted, cleared, stamped, oldPrimaryID): (Int, Int, Int, String?) = try db.pool.write { conn in
            // a. 读 pull_cursor 老 primary_id（在删之前）。pull_cursor 至多 1 行。
            let oldID = try String.fetchOne(
                conn,
                sql: "SELECT primary_id FROM pull_cursor LIMIT 1"
            )

            // b. item_mirror → item。SELECT 显式列出 mirror 字段 + 3 个 push 字段常量值
            //    + ocr_state，顺序对齐 item 表 schema。push_state 'acked' 见 doc。
            //    ocr_state 直接搬过来——mirror 行里若 primary 已 OCR done，搬到 item 后
            //    不需要重 OCR；若 mirror 行 ocr_state IS NULL（v6 之前老 primary 不发该字段），
            //    搬过来仍是 NULL，新 primary 上的 OCR worker 该认 NULL = "没扫过"。
            //    （未来 worker 启动时可一次性把所有 kind=image AND ocr_state IS NULL 的
            //    own-origin 行回填为 pending；schema 不需要再变）
            try conn.execute(sql: """
                INSERT OR IGNORE INTO item (
                    id, origin_device, captured_at_ns, ingested_at_ns,
                    kind, source_app, source_app_name,
                    preview, text_full,
                    blob_sha256, blob_size, blob_mime,
                    pinned, deleted_at_ns,
                    push_state, push_attempts, last_push_error,
                    ocr_state
                )
                SELECT
                    id, origin_device, captured_at_ns, ingested_at_ns,
                    kind, source_app, source_app_name,
                    preview, text_full,
                    blob_sha256, blob_size, blob_mime,
                    pinned, deleted_at_ns,
                    'acked', 0, NULL,
                    ocr_state
                FROM item_mirror
            """)
            let promotedRows = conn.changesCount

            // c. 【P1 修复】stamp 所有 ingested_at_ns IS NULL 的 item 行——必须放在 INSERT mirror
            //    之后，让从 mirror 进来的异常 nil 行也被覆盖。按 captured_at_ns ASC 排让 stamp
            //    顺序贴近 capture 顺序（虽然 nextIngestNs 自带单调）。同步把 push_state 拍 acked
            //    / attempts 清 0 / error 清空——本机变 primary 后没上游可推，pending/failed 都
            //    应进入终态。
            let nullIDs = try String.fetchAll(conn, sql: """
                SELECT id FROM item
                WHERE ingested_at_ns IS NULL
                ORDER BY captured_at_ns ASC, id ASC
            """)
            for id in nullIDs {
                let stamp = try Database.nextIngestNs(conn, now: now)
                try conn.execute(sql: """
                    UPDATE item
                    SET ingested_at_ns = ?,
                        push_state = 'acked',
                        push_attempts = 0,
                        last_push_error = NULL
                    WHERE id = ?
                """, arguments: [stamp, id])
            }
            let stampedRows = nullIDs.count

            // d. 清空 mirror + cursor。FTS 触发器同步清 item_mirror_fts，免费。
            try conn.execute(sql: "DELETE FROM item_mirror")
            let clearedRows = conn.changesCount
            try conn.execute(sql: "DELETE FROM pull_cursor")

            // e. 写 lineage 行。self 用 INSERT OR IGNORE 避免重复 promote 同一 ns 时报错；
            //    现实中 now 是 wall-clock ns，两次调用同 ns 概率极小，但理论上 IGNORE 仍是
            //    最安全的并发兜底（与 retryFailed 等其它 admin 子命令一致的幂等姿态）。
            try conn.execute(sql: """
                INSERT OR IGNORE INTO primary_lineage(device_id, started_at_ns, ended_at_ns)
                VALUES (?, ?, NULL)
            """, arguments: [selfDeviceID, now])

            // 闭老 primary 任期。started_at_ns=0 表示"未知起点"——audit-push 读全量 lineage，
            // 用 `(started_at_ns == 0 || started_at_ns <= t) && (ended_at_ns == nil || t < ended_at_ns)`
            // 做区间覆盖判断，所以 started=0 sentinel 能覆盖 ended 之前的所有时刻。oldID == self
            // 时（本机以前曾作为 primary，被自己再 promote 一次的边界情况）不重写，避免覆盖更准确
            // 的旧记录。
            if let oldID, !oldID.isEmpty, oldID != selfDeviceID {
                try conn.execute(sql: """
                    INSERT OR IGNORE INTO primary_lineage(device_id, started_at_ns, ended_at_ns)
                    VALUES (?, 0, ?)
                """, arguments: [oldID, now])
            }

            return (promotedRows, clearedRows, stampedRows, oldID)
        }

        // f. 改写 config.json
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
            stampedRows: stamped,
            lineageOldPrimaryID: (oldPrimaryID?.isEmpty == false) ? oldPrimaryID : nil,
            lineageStartedAtNs: now,
            configWrittenTo: configPath,
            oldPrimaryURL: oldPrimaryURL,
            missingBlobsTotal: missingTotal,
            missingBlobsSamples: missingSamples
        )
    }

    /// 计划内换 primary 的 **prepare** 阶段（详 plan §b）：在**老 primary** 上跑，落一份
    /// 一致性快照 + 统计 blobs，让操作员手动 rsync 到新机器。命令本身是只读操作（除了
    /// 写出 snapshot 文件这个副产物），不动 DB / config / blobs/。
    ///
    /// **为什么不做"自动 rsync"**：跨机 rsync 需要 ssh 凭证 + 网络可达 + 防火墙策略，把
    /// 这层封进 Swift 命令容易卡在 ssh-agent / known_hosts / Tailscale ACL 等边界条件
    /// 上调试困难。打印命令模板让操作员 sshrsync 手跑反而最可控
    ///
    /// **为什么不自动改本机 config**：老 primary 跑完 migrate 后用途不定（彻底退役 / 改
    /// 为新 primary 的 client / 留着不动）。跟 promoteToPrimary 不同——promote 是抢救动作
    /// 有强假设，migrate 是计划内，操作员可能有各种后续打算，命令不该擅自决定
    ///
    /// **lineage 限制（MVP 已知缺口）**：plan §b 原文没要求写 lineage 行。本命令也不写。
    /// 后果：rsync 到新机后，新 primary DB 里没有"新 primary 接管"的 lineage 记录，其它
    /// client 跑 audit-push 时 `activePrimaryDeviceID` 找不到新 primary 任期 → 回退到
    /// `origin != self` 启发式。单 primary 部署下足够；多次换 primary 链路下可能产生
    /// 跨任期 dedup 误判。后续可加 `--demote-and-record` flag 让命令也写 lineage
    ///
    /// 流程：
    /// 1. 校验当前 config 为 primary 模式（`serve == true && primary_url == nil`）
    /// 2. **daemon-running 检查**：调用方（CLI 层）通过 `launchctl list` 拿状态后传
    ///    `daemonRunning`；为 true → throw `daemonRunning`。**必须停**的理由：VACUUM INTO
    ///    技术上能在 WAL 下拿到一致快照点，但快照之后 daemon 继续 ingest 新行——这些行
    ///    在快照里没有，rsync 完成时新机数据落后老机一段时间，等于静默丢数据
    /// 3. 打开 DB（role=.primary）。**注意**：`Database.init` 会跑 GRDB migrator 把 schema
    ///    推到最新版本——这是 binary 升级的正常副作用（跟 daemon 启动同一行为），且让快照
    ///    带上最新 schema。"命令只读"契约指**业务数据**（item / item_mirror / pull_cursor /
    ///    primary_lineage 等表的行内容不改），不包括 GRDB schema 演进；测试也只断言行数
    ///    与 config 文件字节不变，不断言 sqlite_master 不变
    /// 4. `Snapshot.takeSnapshot` 落 `~/.../snapshots/duo-paste-YYYYMMDD-HHmmss.sqlite`，
    ///    复用现成的 prune 策略 + 文件名风格
    /// 5. 读 snapshot 文件字节数 (`URL.fileSize`)
    /// 6. 递归 walk `blobs/` 目录算 (file count, total bytes)。**不**做内容校验
    ///    （sha256 重算 10 万个 blob 跑半小时），rsync `--checksum` 兜底
    /// 7. 读 item / item_mirror 行数（信息性）
    /// 8. 返回 result。不动 config、不动 DB、不动 blobs
    public static func migratePrimary(
        dbPath: URL,
        configPath: URL,
        blobsRoot: URL,
        snapshotsDir: URL,
        now: Date = Date(),
        daemonRunning: Bool = false,
        daemonLabel: String = "io.duopaste.agent"
    ) throws -> MigratePrimaryResult {
        let current: Config
        do {
            current = try Config.load(from: configPath)
        } catch {
            throw AdminError.readConfigFailed(underlying: String(describing: error))
        }

        // primary 模式判别 = `serve == true && primary_url == nil`。Config.validate 已经
        // 拦截 `serve && primary_url != nil` 的非法组合，所以这里看 serve+primary 就够
        guard current.serve && current.primaryURL == nil else {
            throw AdminError.notInPrimaryMode(currentSummary: current.summary)
        }

        if daemonRunning {
            throw AdminError.daemonRunning(label: daemonLabel)
        }

        // 打开本机 primary DB。Database.init 跑 migrator 确保 schema 最新——VACUUM INTO 出来
        // 的快照拷到新机后能直接被相同 binary 接管
        let db = try Database(path: dbPath, role: .primary)

        // 让 snapshot 父目录存在。CLI 一般传 Paths.snapshotsDir，已经在 Paths.ensureExists()
        // 里建过；测试 fixture 可能跳过，所以这里兜底
        try FileManager.default.createDirectory(
            at: snapshotsDir, withIntermediateDirectories: true
        )
        // 复用 Snapshot.filename 的命名风格（duo-paste-YYYYMMDD-HHmmss.sqlite），让快照
        // 文件在 snapshots/ 目录里与小时级 snapshot 同形态，享用现有 prune 策略
        let snapshotURL = snapshotsDir.appendingPathComponent(
            Snapshot.filename(for: now)
        )
        _ = try db.pool.writeWithoutTransaction { conn in
            try conn.execute(sql: "VACUUM INTO ?", arguments: [snapshotURL.path])
        }

        // 快照字节数。VACUUM INTO 成功但 stat 失败说明文件 / 文件系统出大问题
        // （权限被改、文件刚被删、磁盘 unmount）——CLI 看到 "成功"+0 字节快照会
        // 误以为命令 OK 但快照不可信，必须让错误传播
        let attrs = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        let snapshotBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        // walk blobs/
        let (blobFiles, blobBytes) = try walkBlobsDir(blobsRoot)

        // 行数
        let (itemCount, mirrorCount) = try db.pool.read { conn -> (Int, Int) in
            let i = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item") ?? 0
            let m = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM item_mirror") ?? 0
            return (i, m)
        }

        return MigratePrimaryResult(
            snapshotPath: snapshotURL,
            snapshotBytes: snapshotBytes,
            blobsRoot: blobsRoot,
            blobsTotalFiles: blobFiles,
            blobsTotalBytes: blobBytes,
            itemRowCount: itemCount,
            itemMirrorRowCount: mirrorCount
        )
    }

    /// 递归扫 blobs 目录算 (regular file count, sum of size)。目录不存在 → (0, 0)。
    /// **只**计 regular file，跳过 directory / symlink 之类——blobs/ 由 BlobStore.put 写入
    /// 永远是 regular file，但用户手动放别的东西时不要把目录大小算进总字节数。
    ///
    /// **不**用 `.skipsHiddenFiles`：rsync 默认会拷贝隐藏文件，inventory 数字要跟传输内容
    /// 对齐，操作员靠这个比对老 / 新机一致性。
    ///
    /// `resourceValues` 失败现在 throw 而不是 silently skip——失败说明 FS 异常（权限、文件
    /// 被删、磁盘问题），统计结果不可信时不应静默返回低估值让操作员误以为传输量很小
    private static func walkBlobsDir(_ root: URL) throws -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return (0, 0) }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return (0, 0)
        }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }

    /// 扫 item + item_mirror 里 `blob_sha256 IS NOT NULL AND deleted_at_ns IS NULL` 的行，
    /// 去重 sha 集合后逐个调 `blobs.exists`。返回 (缺失总数, 前 N 个样本)。
    /// 软删行排除——tombstone 不需要 blob 字节。
    private static func checkMissingBlobs(
        db: Database,
        blobs: BlobStore,
        sampleLimit: Int
    ) throws -> (total: Int, samples: [String]) {
        let allShas: [String] = try db.pool.read { conn in
            try String.fetchAll(conn, sql: """
                SELECT blob_sha256 FROM item
                    WHERE blob_sha256 IS NOT NULL AND deleted_at_ns IS NULL
                UNION
                SELECT blob_sha256 FROM item_mirror
                    WHERE blob_sha256 IS NOT NULL AND deleted_at_ns IS NULL
            """)
        }
        var missing: [String] = []
        for sha in allShas where !blobs.exists(sha256: sha) {
            missing.append(sha)
        }
        let samples = Array(missing.prefix(sampleLimit))
        return (missing.count, samples)
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
    /// - `scope=.id(_)`：只看 id + kind=image。无视 origin / state——用户敲了 id 就是
    ///   手动 override，包括把 done 翻成 pending 重 OCR 的场景
    ///
    /// 同步把 `last_push_error` 清空（OCR 失败原因复用此列，重 OCR 前清掉避免污染）。
    /// **不** bump ingested_at_ns——重置本身不改 item 内容；worker 真跑 OCR 写
    /// text_full 时再 bump。
    ///
    /// - Returns: 受影响的行数
    public static func retryFailedOCR(
        dbPath: URL,
        selfDeviceID: String,
        scope: OCRRetryScope
    ) throws -> Int {
        let db = try Database(path: dbPath, role: .client)
        return try db.pool.write { conn -> Int in
            switch scope {
            case .all:
                try conn.execute(sql: """
                    UPDATE item
                    SET ocr_state = 'pending',
                        last_push_error = NULL
                    WHERE origin_device = ?
                      AND kind = 'image'
                      AND ocr_state IN ('failed', 'skipped')
                      AND deleted_at_ns IS NULL
                """, arguments: [selfDeviceID])
            case .id(let id):
                try conn.execute(sql: """
                    UPDATE item
                    SET ocr_state = 'pending',
                        last_push_error = NULL
                    WHERE id = ?
                      AND kind = 'image'
                """, arguments: [id])
            }
            return conn.changesCount
        }
    }
}

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
        /// mesh-init 预检阶段发现 item 表里有 blob_sha256 非空但 BlobStore 没字节的行——
        /// 要么 PR 4 之前 eager_blobs=false 拉的元数据缺字节，要么 BlobStore 被手动清过。
        /// 默认拒绝（DR 操作不该静默继续）；`--allow-missing-blobs` 跳过此检查继续
        case missingBlobs(totalMissing: Int, samples: [String])
        /// LaunchAgent daemon 还在跑——mesh-init 写 config 期间 daemon 仍以老 config
        /// 跑可能 capture 行 + 启 PullWorker 抢锁。先 `launchctl bootout` 停掉再重试。
        case daemonRunning(label: String)
        /// 写 config.json 失败（IO / 权限）。底层错误透传方便排查
        case writeConfigFailed(underlying: String)

        public var description: String {
            switch self {
            case .alreadyExists(let p): return "\(p.path) 已存在；用 --force 覆盖"
            case .randomFailed(let s):  return "SecRandomCopyBytes 失败 (OSStatus=\(s))"
            case .missingBlobs(let total, let samples):
                let head = samples.prefix(3).joined(separator: ", ")
                return "mesh-init 中止：\(total) 个 blob 在本机 BlobStore 缺字节"
                    + "（示例 sha：\(head)\(samples.count > 3 ? " ..." : "")）。"
                    + "若可接受（这些 image/file 永远拉不出本机字节），加 --allow-missing-blobs 重跑。"
            case .daemonRunning(let label):
                return "mesh-init 中止：daemon (\(label)) 还在跑。先停 daemon：\n"
                    + "  launchctl bootout gui/$UID/\(label)\n"
                    + "再重试。"
            case .writeConfigFailed(let u):
                return "写 config 失败：\(u)"
            }
        }
    }

    public struct MeshInitResult: Equatable, Sendable {
        /// 写好的 config.json 路径
        public let configWrittenTo: URL
        /// 这次写入的 peer URL 列表（按入参顺序）
        public let peerURLs: [URL]
        /// 预检阶段发现的 missing blob sha 总数（去重后）。`allowMissingBlobs=true` 路径
        /// 才可能非 0；`=false` 时非 0 已经 throw missingBlobs 中止
        public let missingBlobsTotal: Int
        public let missingBlobsSamples: [String]
        /// dryRun=true 时配置不真写到磁盘——所有预检照常跑，让用户先看结果再决定
        public let dryRun: Bool
        /// 写 config 时清掉的老 schema 字段（primary_url / pull）。信息性，让用户清楚迁移做了什么
        public let removedLegacyKeys: [String]
    }

    /// 预检阶段 missing blob 样本上限。超过这数只报总数 + 前 N 个 sha，避免日志爆
    public static let missingBlobSampleLimit = 10

    // MARK: - mesh-doctor

    /// 单个 peer 的 doctor 报告。
    public struct PeerDoctorReport: Sendable, Equatable {
        public let url: URL
        /// config 里写死的 expected device_id（mesh-init 时显式传），nil 走学习模式
        public let expectedDeviceID: String?
        /// /health 探测结果。reachable 时填 (deviceID, nowMs, skewMs)，不可达填 reason
        public enum HealthOutcome: Sendable, Equatable {
            case ok(deviceID: String, nowMs: Int64, skewMs: Int64)
            case unreachable(reason: String)
            case rejected(reason: String)
        }
        public let health: HealthOutcome
        /// 跟 expectedDeviceID 是否匹配（health=ok 时才有意义）。
        /// nil = 没有 expected，true/false = expected 给了且匹配/不匹配
        public let deviceIDMatches: Bool?
        /// 本机 pull_cursor 表里这个 peer 的行（peer_device_id, cursor_ns, cursor_id）。
        /// nil = 还没 cursor 行（首次启动 / 学习模式 expected 跟 cursor PK 不同）
        public let pullCursor: PullCursorSnapshot?
    }

    public struct PullCursorSnapshot: Sendable, Equatable {
        public let peerDeviceID: String
        public let cursorNs: Int64
        public let cursorID: String
        public let updatedAtNs: Int64
    }

    /// mesh-doctor 总报告。
    public struct MeshDoctorReport: Sendable, Equatable {
        public let selfDeviceID: String
        public let peers: [PeerDoctorReport]
        /// 本机当前 max(ingested_at_ns)，让操作员对端 cursor 跟这个数比看追平程度
        public let selfMaxIngestedNs: Int64
        /// 本机 BlobStore 缺字节的 sha 总数 + 样本（item.blob_sha256 IS NOT NULL +
        /// kind IN image/file + 未删 + BlobStore.exists=false）
        public let missingBlobsTotal: Int
        public let missingBlobsSamples: [String]
    }

    /// /health 探测的 closure 返回值。Admin 在 Core 模块，不能依赖 Sync 的 SinceTransport
    /// → 用闭包接口，CLI 包装层把 HTTPPeerClient.fetchPrimaryHealth 翻译成这个 enum
    public enum HealthProbeOutcome: Sendable, Equatable {
        case ok(deviceID: String, nowMs: Int64)
        case unreachable(reason: String)
        case rejected(reason: String)
    }

    /// 探测每个 peer 健康 + 对账 cursor + 本机 blob 缺失。CLI 包装层调它打印报告。
    /// 纯函数（注入 healthProbe closure + db/blobs 路径），方便单测。
    ///
    /// 实现策略：
    /// - 每 peer 一次 healthProbe（生产路径 = HTTPPeerClient.fetchPrimaryHealth），串行做
    /// - 一次 DB read 拿 pull_cursor 全部行 + max ingested_at_ns + 算 missing blob 集
    /// - 本机时钟跟 peer.now_ms 比算 skewMs
    public static func meshDoctor(
        selfDeviceID: String,
        peers: [Config.PeerConfig],
        dbPath: URL,
        blobs: BlobStore,
        healthProbe: @Sendable (URL) async -> HealthProbeOutcome,
        nowNs: @Sendable () -> Int64 = { Clock.nowNs() }
    ) async throws -> MeshDoctorReport {
        let db = try Database(path: dbPath)
        let cursorRows: [PullCursorSnapshot] = try await db.pool.read { conn -> [PullCursorSnapshot] in
            try Row.fetchAll(conn, sql: """
                SELECT peer_device_id, cursor_ns, cursor_id, updated_at_ns
                  FROM pull_cursor
            """).map { row in
                PullCursorSnapshot(
                    peerDeviceID: row["peer_device_id"] ?? "",
                    cursorNs: row["cursor_ns"] ?? 0,
                    cursorID: row["cursor_id"] ?? "",
                    updatedAtNs: row["updated_at_ns"] ?? 0
                )
            }
        }
        let selfMax = try await db.currentMaxIngestedNs()
        let (missingTotal, missingSamples) = try scanMissingBlobs(dbPath: dbPath, blobs: blobs)

        var peerReports: [PeerDoctorReport] = []
        let localNowMs = nowNs() / 1_000_000
        for peer in peers {
            let outcome = await healthProbe(peer.url)
            let healthOutcome: PeerDoctorReport.HealthOutcome
            var matches: Bool? = nil
            switch outcome {
            case .ok(let did, let nowMs):
                let skew = nowMs - localNowMs
                healthOutcome = .ok(deviceID: did, nowMs: nowMs, skewMs: skew)
                if let expected = peer.deviceID {
                    matches = (did == expected)
                }
            case .unreachable(let r):
                healthOutcome = .unreachable(reason: r)
            case .rejected(let r):
                healthOutcome = .rejected(reason: r)
            }

            // 找本 peer 对应的 pull_cursor 行——按 expected device_id（严格模式）或
            // 按 health 报的 device_id（学习模式）
            let lookupID: String? = peer.deviceID
                ?? {
                    if case .ok(let did, _, _) = healthOutcome { return did } else { return nil }
                }()
            let cursor: PullCursorSnapshot? = lookupID.flatMap { id in
                cursorRows.first(where: { $0.peerDeviceID == id })
            }

            peerReports.append(PeerDoctorReport(
                url: peer.url,
                expectedDeviceID: peer.deviceID,
                health: healthOutcome,
                deviceIDMatches: matches,
                pullCursor: cursor
            ))
        }

        return MeshDoctorReport(
            selfDeviceID: selfDeviceID,
            peers: peerReports,
            selfMaxIngestedNs: selfMax,
            missingBlobsTotal: missingTotal,
            missingBlobsSamples: missingSamples
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

    /// 把本机 config.json 切到新 mesh schema：写 `peers: [...]` + `mesh: {...}` + `serve=true`，
    /// 显式删老 `primary_url` / `pull` 字段。
    ///
    /// **不动 DB**：本机 item 表里可能有老 push 链路 / 老 PullWorker 留下来的对端行，让 daemon
    /// 启动后 PullWorker 自己的 reconcilePeer 流程清理（peer device_id 不匹配时清行 + cursor）。
    /// PR 1 v7 migration 已把 item_mirror 合到 item，PR 4 v8 已 DROP push_*；不需要再开 tx。
    ///
    /// **不动 LaunchAgent plist**：mesh-init 是配置切换，不是 promote/migrate 那种"事实根重写"。
    /// 用户在打印的 kickstart 提示后手动 bootout/bootstrap/kickstart 让 daemon 重读 config。
    ///
    /// 步骤：
    /// 1. daemon guard：在跑 → throw（同 promote 不变量 #6）
    /// 2. 预检 blob 缺失：扫 item 表 blob_sha256 非空 + 未删 + image/file 的去重 sha 集，
    ///    逐个 BlobStore.exists；缺失 + 默认 → throw missingBlobs；`allowMissingBlobs=true` 跳
    /// 3. dry-run 路径：填 result + 立即返回（不写 config）
    /// 4. 写 config.json：用 Config.write 走 nested merge 路径，自动 removeValue 老 key
    /// 5. 返回 MeshInitResult 让 CLI 打印
    @discardableResult
    public static func meshInit(
        configPath: URL,
        dbPath: URL,
        blobs: BlobStore,
        peerURLs: [URL],
        peerDeviceIDs: [String?] = [],
        serveHost: String? = nil,
        servePort: Int? = nil,
        serveTLS: Bool? = nil,
        tlsCertPath: String? = nil,
        tlsKeyPath: String? = nil,
        allowMissingBlobs: Bool = false,
        dryRun: Bool = false,
        daemonRunning: Bool,
        daemonLabel: String
    ) throws -> MeshInitResult {
        // 1. daemon guard
        if daemonRunning {
            throw AdminError.daemonRunning(label: daemonLabel)
        }

        // 2. 预检 blob 缺失。组装 PeerConfig 列表前先扫，throw 早一步用户不需要等写盘
        let (missingTotal, missingSamples) = try scanMissingBlobs(dbPath: dbPath, blobs: blobs)
        if !allowMissingBlobs && missingTotal > 0 {
            throw AdminError.missingBlobs(totalMissing: missingTotal, samples: missingSamples)
        }

        // 组 PeerConfig：deviceID 列表跟 URL 列表对位（短的填 nil）。CLI 入口会 zip 好
        // 但 plain init 入口要兼容只传 URL 列表的简化写法
        var peers: [Config.PeerConfig] = []
        for (i, url) in peerURLs.enumerated() {
            let did = (i < peerDeviceIDs.count) ? peerDeviceIDs[i] : nil
            peers.append(Config.PeerConfig(url: url, deviceID: did))
        }

        // 读老 config 做 base（保留 hotkey / capture / ocr / shared_secret_keychain_account 等
        // 不动的字段）；老 config 不存在或解析失败时从 default 起步
        let oldConfig: Config = (try? Config.load(from: configPath)) ?? .default

        // 算 removedLegacyKeys——只用于报告（Config.write 内部已经 removeValue）。
        // 读原 dict 看是否有这两 key 决定要不要标
        var removedLegacy: [String] = []
        if FileManager.default.fileExists(atPath: configPath.path),
           let data = try? Data(contentsOf: configPath),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            if dict["primary_url"] != nil { removedLegacy.append("primary_url") }
            if dict["pull"] != nil { removedLegacy.append("pull") }
        }

        // TLS 选项：显式给 → 用 / nil → 沿用 oldConfig 现值。
        // serveTLS=true 时 cert/key 必须给（要么本次显式传，要么 oldConfig 已经有）
        // —— 路径存在性校验留到 Config.validate（启动时按现有逻辑 server 启动时再校验文件）
        let finalServeTLS = serveTLS ?? oldConfig.serveTLS
        let finalCertPath = tlsCertPath ?? oldConfig.tlsCertPath
        let finalKeyPath = tlsKeyPath ?? oldConfig.tlsKeyPath
        if finalServeTLS {
            guard let cert = finalCertPath, !cert.isEmpty,
                  let key = finalKeyPath, !key.isEmpty else {
                throw AdminError.writeConfigFailed(
                    underlying: "serve_tls=true 时 tls_cert_path 和 tls_key_path 必填（"
                        + "可用 --tls-cert / --tls-key 显式传，或先在 config.json 里配好）"
                )
            }
            // 文件存在性预检——cert / key 不在路径上启动时 server 跑 NIOSSLCertificate.fromPEMFile
            // 会挂，提前 throw 比让 daemon 起来后失败友好
            let fm = FileManager.default
            if !fm.fileExists(atPath: cert) {
                throw AdminError.writeConfigFailed(
                    underlying: "tls_cert_path 文件不存在：\(cert)"
                )
            }
            if !fm.fileExists(atPath: key) {
                throw AdminError.writeConfigFailed(
                    underlying: "tls_key_path 文件不存在：\(key)"
                )
            }
        }

        let newConfig = Config(
            serve: true,
            serveHost: serveHost ?? oldConfig.serveHost,
            servePort: servePort ?? oldConfig.servePort,
            serveTLS: finalServeTLS,
            tlsCertPath: finalCertPath,
            tlsKeyPath: finalKeyPath,
            peers: peers,
            mesh: oldConfig.mesh,
            ocr: oldConfig.ocr,
            capture: oldConfig.capture,
            hotkey: oldConfig.hotkey
        )

        // dry-run：跑完所有预检 + 组好 newConfig 但**不**真写
        if dryRun {
            return MeshInitResult(
                configWrittenTo: configPath,
                peerURLs: peerURLs,
                missingBlobsTotal: missingTotal,
                missingBlobsSamples: missingSamples,
                dryRun: true,
                removedLegacyKeys: removedLegacy
            )
        }

        // 4. 写 config（Config.write 内部 validate + removeValue 老字段 + nested merge）
        do {
            try Config.write(newConfig, to: configPath)
        } catch {
            throw AdminError.writeConfigFailed(underlying: "\(error)")
        }

        return MeshInitResult(
            configWrittenTo: configPath,
            peerURLs: peerURLs,
            missingBlobsTotal: missingTotal,
            missingBlobsSamples: missingSamples,
            dryRun: false,
            removedLegacyKeys: removedLegacy
        )
    }

    // MARK: - mesh-fetch-missing （PR cloudy-mirroring-walnut PR 2）

    /// 一次性 catch-up 入口：扫本机所有缺字节的 peer-origin blob sha → 并发拉回。
    /// 用户从老 lazy 模式 / `eager_blobs=false` 升级到新 `storage_mode=full` 默认后，
    /// 历史 peer 行可能仍缺 blob（PR 1 之后的新行 PullWorker eager 路径自动处理）。
    public struct FetchMissingReport: Sendable, Equatable {
        /// 总共需要拉的 sha 数（dedup 后；含 fetched + failed + skipped）
        public let totalMissing: Int
        /// 成功 GET + putVerified 写盘的 sha 数
        public let fetched: Int
        /// 失败（404 / shaMismatch / transient 重试耗尽 / put 失败）的 sha 数
        public let failed: Int
        /// dryRun=true 时全部入 skipped；非 dryRun 路径目前不进 skipped（保留字段
        /// 给未来 "blob 太大跳过" 等场景）
        public let skipped: Int
        /// 失败的 sha + reason，最多保留前 N 条。给用户日志看哪些 peer 上也没字节
        public let failures: [FetchFailure]
        public let dryRun: Bool

        public struct FetchFailure: Sendable, Equatable {
            public let sha: String
            public let reason: String
        }
    }

    /// Admin 不能依赖 DuoPasteSync 模块的 BlobFetcher 协议——用闭包接口。
    /// CLI 包装层把 HTTPPeerClient.getBlob 翻成这个 enum
    public enum BlobFetchOutcome: Sendable {
        case found(Data)
        case notFound
        case shaMismatch(expected: String, actual: String)
        case rejected(reason: String)
        case transient(reason: String)
    }

    public static let fetchMissingFailureSampleLimit = 20

    /// 一次性 catch-up：把本机缺字节的 peer-origin sha 全部拉回来。
    ///
    /// 设计要点：
    /// - **只扫 peer-origin**（origin_device != selfDeviceID）：own-origin 缺 blob 是
    ///   本地 BlobStore 被清的问题，拉对端也没有；mesh-fetch-missing 是补对端镜像
    /// - **并发 sha 而非并发 peer**：每个 sha 内部由 fetcher 闭包决定要打哪个 peer
    ///   （CLI 包装层按 peer 顺序尝试）；this 函数只控总并发数
    /// - **dryRun=true**：只扫描列出 missing，不真发 GET、不写盘；返回 total + 全入
    ///   skipped。给用户决定要不要真跑
    /// - **失败不抛**：单条 sha 失败 only log + 进 failures 列表；整个函数永远成功返回。
    ///   `Sources/DuoPasteSync/PullWorker.fetchBlobsFull` 路径同款契约
    /// - **putVerified**：拉回字节走 BlobStore.putVerified 二次校验 sha（防 MITM /
    ///   server bug 给错字节污染本机）
    public static func fetchMissingBlobs(
        dbPath: URL,
        selfDeviceID: String,
        blobs: BlobStore,
        fetcher: @escaping @Sendable (String) async -> BlobFetchOutcome,
        concurrency: Int = 4,
        dryRun: Bool = false,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> FetchMissingReport {
        precondition(concurrency >= 1, "concurrency 必须 >= 1")
        let missing = try scanMissingPeerBlobs(dbPath: dbPath, selfDeviceID: selfDeviceID, blobs: blobs)
        let total = missing.count

        if dryRun || total == 0 {
            return FetchMissingReport(
                totalMissing: total,
                fetched: 0, failed: 0,
                skipped: dryRun ? total : 0,
                failures: [],
                dryRun: dryRun
            )
        }

        // 并发桶：semaphore 模式控总并发 = concurrency。每个 sha 一个 child task，
        // 各自申请 semaphore 后才发 GET。简单 actor 计数即可
        let counter = FetchMissingCounter(sampleLimit: fetchMissingFailureSampleLimit)
        let oneSha: @Sendable (String) async -> Void = { sha in
            // BlobStore.exists 二次 check：扫描后到拉取间可能并发的 PullWorker eager 路径
            // 已经拉过；幂等防重
            if blobs.exists(sha256: sha) { return }
            let outcome = await fetcher(sha)
            switch outcome {
            case .found(let data):
                do {
                    _ = try blobs.putVerified(data, expectedSha256: sha)
                    await counter.recordSuccess()
                    log("fetched sha=\(sha)")
                } catch {
                    await counter.recordFailure(sha: sha, reason: "put failed: \(error)")
                }
            case .notFound:
                await counter.recordFailure(sha: sha, reason: "peer 上无此 blob（404）")
            case .shaMismatch(let expected, let actual):
                await counter.recordFailure(
                    sha: sha,
                    reason: "peer 返回字节 sha 不一致 (expected \(expected.prefix(8))... got \(actual.prefix(8))...)"
                )
            case .rejected(let reason):
                await counter.recordFailure(sha: sha, reason: "鉴权拒绝: \(reason)")
            case .transient(let reason):
                await counter.recordFailure(sha: sha, reason: "transient: \(reason)")
            }
        }

        await withTaskGroup(of: Void.self) { group in
            var running = 0
            var iter = missing.makeIterator()
            // 启动初始 batch
            while running < concurrency, let sha = iter.next() {
                running += 1
                group.addTask { await oneSha(sha) }
            }
            // 滚动入队剩余
            while await group.next() != nil {
                if let sha = iter.next() {
                    group.addTask { await oneSha(sha) }
                }
            }
        }

        let (fetched, failed, failures) = await counter.snapshot()
        return FetchMissingReport(
            totalMissing: total,
            fetched: fetched,
            failed: failed,
            skipped: 0,
            failures: failures,
            dryRun: false
        )
    }

    /// fetchMissingBlobs 的内部并发计数器
    private actor FetchMissingCounter {
        var fetched = 0
        var failed = 0
        var failures: [FetchMissingReport.FetchFailure] = []
        let sampleLimit: Int
        init(sampleLimit: Int) { self.sampleLimit = sampleLimit }
        func recordSuccess() { fetched += 1 }
        func recordFailure(sha: String, reason: String) {
            failed += 1
            if failures.count < sampleLimit {
                failures.append(.init(sha: sha, reason: reason))
            }
        }
        func snapshot() -> (Int, Int, [FetchMissingReport.FetchFailure]) {
            (fetched, failed, failures)
        }
    }

    /// 扫所有 peer-origin（origin != selfDeviceID）blob_sha256 非空 + image/file kind +
    /// 未删的去重 sha 集，跟 BlobStore 比对找出缺字节的。返回完整 sha 列表（catch-up
    /// 时要拉，不只是采样）
    public static func scanMissingPeerBlobs(
        dbPath: URL,
        selfDeviceID: String,
        blobs: BlobStore
    ) throws -> [String] {
        let db = try Database(path: dbPath)
        let allShas: [String] = try db.pool.read { conn -> [String] in
            try String.fetchAll(conn, sql: """
                SELECT DISTINCT blob_sha256 FROM item
                WHERE blob_sha256 IS NOT NULL
                  AND deleted_at_ns IS NULL
                  AND kind IN ('image', 'file')
                  AND origin_device != ?
            """, arguments: [selfDeviceID])
        }
        return allShas.filter { !blobs.exists(sha256: $0) }
    }

    /// 扫 item 表里 blob_sha256 非空 + image/file kind + 未删的去重 sha 集合，
    /// 跟 BlobStore 比对找出本机缺字节的。返回 (总数, 前 N 个 sha 样本)。
    /// 跟 promoteToPrimary 之前的同名预检逻辑同款（plan §"promoteToPrimary 不变量 #8"）
    private static func scanMissingBlobs(
        dbPath: URL,
        blobs: BlobStore
    ) throws -> (total: Int, samples: [String]) {
        let db = try Database(path: dbPath)
        let allShas: [String] = try db.pool.read { conn -> [String] in
            try String.fetchAll(conn, sql: """
                SELECT DISTINCT blob_sha256 FROM item
                WHERE blob_sha256 IS NOT NULL
                  AND deleted_at_ns IS NULL
                  AND kind IN ('image', 'file')
            """)
        }
        var missing: [String] = []
        for sha in allShas {
            if !blobs.exists(sha256: sha) { missing.append(sha) }
        }
        return (missing.count, Array(missing.prefix(missingBlobSampleLimit)))
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

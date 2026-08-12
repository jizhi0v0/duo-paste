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
    public struct PeerDoctorReport: Sendable, Equatable, Codable {
        public let url: URL
        /// config 里写死的 expected device_id（mesh-init 时显式传），nil 走学习模式
        public let expectedDeviceID: String?
        /// /health 探测结果。reachable 时填 (deviceID, nowMs, skewMs)，不可达填 reason
        public enum HealthOutcome: Sendable, Equatable, Codable {
            case ok(deviceID: String, nowMs: Int64, skewMs: Int64)
            case unreachable(reason: String)
            case rejected(reason: String)

            private enum CodingKeys: String, CodingKey {
                case status, deviceID, nowMs, skewMs, reason
            }

            private enum Status: String, Codable { case ok, unreachable, rejected }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .ok(let deviceID, let nowMs, let skewMs):
                    try c.encode(Status.ok, forKey: .status)
                    try c.encode(deviceID, forKey: .deviceID)
                    try c.encode(nowMs, forKey: .nowMs)
                    try c.encode(skewMs, forKey: .skewMs)
                case .unreachable(let reason):
                    try c.encode(Status.unreachable, forKey: .status)
                    try c.encode(reason, forKey: .reason)
                case .rejected(let reason):
                    try c.encode(Status.rejected, forKey: .status)
                    try c.encode(reason, forKey: .reason)
                }
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                switch try c.decode(Status.self, forKey: .status) {
                case .ok:
                    self = .ok(
                        deviceID: try c.decode(String.self, forKey: .deviceID),
                        nowMs: try c.decode(Int64.self, forKey: .nowMs),
                        skewMs: try c.decode(Int64.self, forKey: .skewMs)
                    )
                case .unreachable:
                    self = .unreachable(reason: try c.decode(String.self, forKey: .reason))
                case .rejected:
                    self = .rejected(reason: try c.decode(String.self, forKey: .reason))
                }
            }
        }
        public let health: HealthOutcome
        /// 跟 expectedDeviceID 是否匹配（health=ok 时才有意义）。
        /// nil = 没有 expected，true/false = expected 给了且匹配/不匹配
        public let deviceIDMatches: Bool?
        /// 本机 pull_cursor 表里这个 peer 的行（peer_device_id, cursor_ns, cursor_id）。
        /// nil = 还没 cursor 行（首次启动 / 学习模式 expected 跟 cursor PK 不同）
        public let pullCursor: PullCursorSnapshot?
        /// PR 4/5：当前 SmartTransport 决策给这个 peer 的 transport label，形如
        /// `ponte (mbp.sgponte:8443)` / `tailscale (mbp.tail.ts.net:8443)`。mesh-doctor
        /// 自己跑一遍 discover 拿决策（**只读不动**，不通过 daemon IPC）→ 等价"daemon 现在应
        /// 该用什么"。nil = CLI 没传 transportLabels（Core 不依赖 Sync，留可选）
        public let currentTransport: String?
    }

    public struct PullCursorSnapshot: Sendable, Equatable, Codable {
        public let peerDeviceID: String
        public let cursorNs: Int64
        public let cursorID: String
        public let updatedAtNs: Int64
    }

    /// mesh-doctor 总报告。
    public struct MeshDoctorReport: Sendable, Equatable, Codable {
        public let selfDeviceID: String
        public let tlsCertificate: TLSCertificateState
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
        nowNs: @Sendable () -> Int64 = { Clock.nowNs() },
        transportLabels: [URL: String] = [:],
        tlsCertificate: TLSCertificateState = .notConfigured
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
                // `nowMs` 来自对端 /health body，该响应不签名——极值会让裸减法溢出 trap
                // 掉整个 mesh-doctor / diagnostics-export。skew 只用于展示与告警阈值，
                // 溢出时钳到边界即可（一定会触发"时钟严重不同步"的判断，语义正确）
                let (rawSkew, skewOverflow) = nowMs.subtractingReportingOverflow(localNowMs)
                let skew = skewOverflow ? (nowMs < 0 ? Int64.min : Int64.max) : rawSkew
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
                pullCursor: cursor,
                currentTransport: transportLabels[peer.url]
            ))
        }

        return MeshDoctorReport(
            selfDeviceID: selfDeviceID,
            tlsCertificate: tlsCertificate,
            peers: peerReports,
            selfMaxIngestedNs: selfMax,
            missingBlobsTotal: missingTotal,
            missingBlobsSamples: missingSamples
        )
    }

    public static func encodeMeshDoctorJSON(_ report: MeshDoctorReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    public static func meshDoctorHasIssues(_ report: MeshDoctorReport) -> Bool {
        if report.tlsCertificate.requiresAttention || report.missingBlobsTotal > 0 { return true }
        return report.peers.contains { peer in
            switch peer.health {
            case .ok:
                return peer.deviceIDMatches == false
            case .unreachable, .rejected:
                return true
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

    /// OCR 范围 SQL 谓词——必须跟 `OCRWorker.fetchPending` 完全对齐:
    /// `kind='image'` OR `kind='file' + blob_mime LIKE 'image/%' + has blob`。
    ///
    /// 历史踩坑(2026-05):一开始只写 `kind='image'`,导致 UI"本机索引状态"
    /// 漏算 187 张 CleanShot screenshot——它们是 file kind 但 blob_mime=image/png,
    /// OCRWorker 早就识别为图片在跑 OCR,我这边 stats SQL 没跟上口径就显示 0。
    /// 任何"OCR 视角"的 SQL(stats / rebuild / abort)都必须用这条
    static let ocrScopeSQL = """
          AND (
                kind = 'image'
             OR (kind = 'file' AND blob_mime LIKE 'image/%' AND blob_sha256 IS NOT NULL)
          )
        """

    /// 本机 OCR 队列快照。只统计 `origin_device = self AND <ocrScopeSQL> AND deleted_at_ns IS NULL`
    /// 的行——peer 行由对端 worker 负责，文本行没有 OCR 概念。Settings UI 周期调它
    /// 显示"剩 X 张待处理"+ 灰字"已完成 N 条使用原配置"。
    public struct OCRStats: Sendable, Equatable {
        public var pending: Int
        public var done: Int
        public var skipped: Int
        public var failed: Int

        public init(pending: Int = 0, done: Int = 0, skipped: Int = 0, failed: Int = 0) {
            self.pending = pending
            self.done = done
            self.skipped = skipped
            self.failed = failed
        }

        public var total: Int { pending + done + skipped + failed }
    }

    /// 算本机 OCR 队列分布。read tx 即可。
    public static func ocrStats(dbPath: URL, selfDeviceID: String) throws -> OCRStats {
        let db = try Database(path: dbPath)
        return try db.pool.read { conn -> OCRStats in
            var stats = OCRStats()
            let rows = try Row.fetchAll(conn, sql: """
                SELECT ocr_state AS s, COUNT(*) AS c
                FROM item
                WHERE origin_device = ?
                  AND deleted_at_ns IS NULL
                  \(Self.ocrScopeSQL)
                GROUP BY ocr_state
            """, arguments: [selfDeviceID])
            for row in rows {
                let s: String = row["s"] ?? ""
                let c: Int = row["c"] ?? 0
                switch s {
                case "pending": stats.pending = c
                case "done":    stats.done = c
                case "skipped": stats.skipped = c
                case "failed":  stats.failed = c
                default:        break
                }
            }
            return stats
        }
    }

    /// 重建本机 OCR 索引：把 own-origin image 里 `ocr_state='done'` 行翻回 pending，
    /// 让 OCRWorker 用当前 config（语言/精度）重跑。仅动本机 origin，跟单一归属契约对齐。
    ///
    /// 跟 retryFailedOCR 分开：后者只翻 failed/skipped 不动 done。用户场景不同——
    /// 改 maxBlobMB 调大 → retryFailedOCR；改语言/精度 → rebuildOCRIndex。
    ///
    /// **不** bump ingested_at_ns——重置本身不改内容；worker 真跑完 markDone 时再 bump
    /// 让对端 PullWorker 同步到新 text_full（OCR Phase 2 路径）。
    ///
    /// - Returns: 受影响的行数
    public static func rebuildOCRIndex(dbPath: URL, selfDeviceID: String) throws -> Int {
        let db = try Database(path: dbPath)
        return try db.pool.write { conn -> Int in
            // **必须**同时清 extracted_text / extracted_text_source:
            // - 不清 → 旧 OCR 文本继续在 FTS 里可搜
            // - 若后续 markSkipped / markFailed (识别失败 / 缺 blob / 超 cap) 让行卡在终态,
            //   旧文本永久保留 → 用户改完配置点"重建"反而被骗
            // bump ingested_at_ns 让对端 PullWorker /since 同步到清空 → 对端 FTS 也更新
            let now = Clock.nowNs()
            let stamp = try DuoPasteCore.Database.nextIngestNs(conn, now: now)
            try conn.execute(sql: """
                UPDATE item
                SET ocr_state = 'pending',
                    extracted_text = NULL,
                    extracted_text_source = NULL,
                    ingested_at_ns = ?
                WHERE origin_device = ?
                  AND ocr_state = 'done'
                  AND deleted_at_ns IS NULL
                  \(Self.ocrScopeSQL)
            """, arguments: [stamp, selfDeviceID])
            return conn.changesCount
        }
    }

    /// 中止本机 OCR 队列：把 own-origin image `ocr_state='pending'` 翻成 `skipped`。
    /// 走 skipped 而非新增 cancelled 状态——skipped 语义本就是"本次不处理"；
    /// 用户日后想恢复直接 retryFailedOCR（`WHERE ocr_state IN ('failed','skipped')`）即可，
    /// 不需要为 cancel 单开一个状态值。
    ///
    /// 用户场景：reindex 跑到一半发现配置不对，想清场重来——abort + 改配置 + rebuild。
    ///
    /// - Returns: 受影响的行数
    public static func abortOCRQueue(dbPath: URL, selfDeviceID: String) throws -> Int {
        let db = try Database(path: dbPath)
        return try db.pool.write { conn -> Int in
            try conn.execute(sql: """
                UPDATE item
                SET ocr_state = 'skipped'
                WHERE origin_device = ?
                  AND ocr_state = 'pending'
                  AND deleted_at_ns IS NULL
                  \(Self.ocrScopeSQL)
            """, arguments: [selfDeviceID])
            return conn.changesCount
        }
    }

    // MARK: - 图片 file 行缺 blob 字节回填

    /// 回填本机 file kind 图片扩展但 `blob_sha256 IS NULL` 行的字节。
    ///
    /// **场景**:CleanShot/Lightshot 把截图复制到剪贴板时,PasteboardWatcher 当时
    /// 没读到字节(读失败 / 文件已不存在 / 超 capture cap)就只存了路径。这些行 OCR
    /// 路径(`fetchPending` 要求 `blob_mime LIKE 'image/%' AND blob_sha256 IS NOT NULL`)
    /// 看不到,跨设备同步也只能看到文件名搜不到内容。
    ///
    /// 回填策略:逐行扫描 → 读 text_full 里的本地绝对路径 → 文件存在且 ≤ maxBlobBytes →
    /// 字节进 BlobStore(content-addressed,自动 dedup)→ UPDATE 行的
    /// `blob_sha256/blob_size/blob_mime` + 标 `ocr_state='pending'` + 通过 nextIngestNs 单增
    /// bump `ingested_at_ns`(同 writer tx 内,/since 才能让对端拉到 metadata)。OCRWorker
    /// 下一 tick 自然扫到跑 OCR(Phase 2 路径再把 text_full 推给对端)。
    ///
    /// **只动**:`origin_device = self` + `kind='file'` + 图片扩展名 + `blob_sha256 IS NULL`
    /// + `deleted_at_ns IS NULL`。peer 行 / 已有 blob 的行 / 非图片 file / tombstone 都不动。
    /// **路径源**:用 `text_full`(file kind 的 authoritative path,见 CaptureService 写入
    /// 契约 `resolvedTextFull = c.text ?? c.fileName`)。preview 是被 makePreview 截短的展示值,
    /// 长路径会丢字节。text_full 以 `/` 开头且不含 `\n` 才尝试(排除多文件 `\n`-join)。
    ///
    /// 幂等:跑完后 blob_sha256 非 NULL,下次扫不到。
    public struct RefillImageBlobsReport: Sendable, Equatable {
        public var scanned: Int       // 候选行总数
        public var refilled: Int      // 成功填了 blob 的
        public var fileMissing: Int   // 路径指向的文件不存在
        public var tooLarge: Int      // 字节数超过 maxBlobBytes
        public var readFailed: Int    // 文件存在但读字节失败(权限/坏盘等)
        public var nonAbsolute: Int   // text_full 不是单条绝对路径(多文件 / 相对路径 / NULL)

        public init(
            scanned: Int = 0, refilled: Int = 0, fileMissing: Int = 0,
            tooLarge: Int = 0, readFailed: Int = 0, nonAbsolute: Int = 0
        ) {
            self.scanned = scanned
            self.refilled = refilled
            self.fileMissing = fileMissing
            self.tooLarge = tooLarge
            self.readFailed = readFailed
            self.nonAbsolute = nonAbsolute
        }

        public var summary: String {
            "scanned=\(scanned) refilled=\(refilled) missing=\(fileMissing) too_large=\(tooLarge) read_failed=\(readFailed) non_absolute=\(nonAbsolute)"
        }
    }

    public static func refillMissingImageBlobs(
        dbPath: URL,
        blobsDir: URL,
        selfDeviceID: String,
        maxBlobBytes: Int,
        log: (String) -> Void = { _ in }
    ) throws -> RefillImageBlobsReport {
        let db = try Database(path: dbPath)
        let blobs = BlobStore(root: blobsDir)
        var report = RefillImageBlobsReport()

        // 1) 拿候选行清单。read tx,不持锁。
        //    匹配 text_full(authoritative path)而非 preview(makePreview 截断后的展示值)
        struct Candidate { let id: String; let textFull: String? }
        let candidates: [Candidate] = try db.pool.read { conn -> [Candidate] in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT id, text_full
                FROM item
                WHERE origin_device = ?
                  AND kind = 'file'
                  AND blob_sha256 IS NULL
                  AND deleted_at_ns IS NULL
                  AND (
                        LOWER(IFNULL(text_full, '')) GLOB '*.png'
                     OR LOWER(IFNULL(text_full, '')) GLOB '*.jpg'
                     OR LOWER(IFNULL(text_full, '')) GLOB '*.jpeg'
                     OR LOWER(IFNULL(text_full, '')) GLOB '*.heic'
                     OR LOWER(IFNULL(text_full, '')) GLOB '*.heif'
                     OR LOWER(IFNULL(text_full, '')) GLOB '*.gif'
                     OR LOWER(IFNULL(text_full, '')) GLOB '*.webp'
                     OR LOWER(IFNULL(text_full, '')) GLOB '*.tiff'
                     OR LOWER(IFNULL(text_full, '')) GLOB '*.tif'
                     OR LOWER(IFNULL(text_full, '')) GLOB '*.bmp'
                  )
            """, arguments: [selfDeviceID])
            return rows.map { Candidate(id: $0["id"] ?? "", textFull: $0["text_full"]) }
        }
        report.scanned = candidates.count
        log("refill-image-blobs: 扫到 \(candidates.count) 条候选 file 行(own-origin · 图片扩展 · 无 blob · 未软删)")

        // 2) 逐行处理。文件 IO 不能在 writer tx 内
        for cand in candidates {
            // 多文件 capture 时 text_full 是 \n-join 多路径——不在回填范畴(无法关联到单一 blob)。
            // 相对路径 / 空 text_full 也跳过
            guard let raw = cand.textFull,
                  raw.hasPrefix("/"),
                  !raw.contains("\n") else {
                report.nonAbsolute += 1
                log("refill-image-blobs: skip id=\(cand.id) · text_full 非单条绝对路径")
                continue
            }
            let url = URL(fileURLWithPath: raw)
            // 文件存在性
            guard FileManager.default.fileExists(atPath: url.path) else {
                report.fileMissing += 1
                log("refill-image-blobs: skip id=\(cand.id) · 原文件不存在: \(url.path)")
                continue
            }
            // 大小检查(避免读 50GB)
            let fileSize: Int
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
            } catch {
                report.readFailed += 1
                log("refill-image-blobs: skip id=\(cand.id) · stat 失败: \(error)")
                continue
            }
            if fileSize <= 0 || fileSize > maxBlobBytes {
                report.tooLarge += 1
                log("refill-image-blobs: skip id=\(cand.id) · 大小 \(fileSize) 超过上限 \(maxBlobBytes) 或为 0")
                continue
            }
            // 读字节
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                report.readFailed += 1
                log("refill-image-blobs: skip id=\(cand.id) · 读字节失败: \(error)")
                continue
            }
            let ext = url.pathExtension.lowercased()
            let mime = Self.imageExtToMime(ext)
            // 进 BlobStore(content-addressed,同 sha 已有则 wasExisting=true,占用安全)
            let info: BlobInfo
            do {
                info = try blobs.put(data, ext: ext)
            } catch {
                report.readFailed += 1
                log("refill-image-blobs: skip id=\(cand.id) · BlobStore.put 失败: \(error)")
                continue
            }
            // UPDATE 行:补 blob_sha256/blob_size/blob_mime + 标 ocr_state=pending。
            // 同 tx 内 bump ingested_at_ns(走 nextIngestNs 保单增)——blob_* / ocr_state 都属
            // /since 同步字段,不 bump 对端拉不到 metadata;OCR 是否启用 / 是否最终成功跟 metadata
            // 可见性独立,不能依赖 worker 后续 markDone 才推送。captured_at_ns 不动(不是新 capture)
            do {
                try db.pool.write { conn in
                    let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
                    let ns = try DuoPasteCore.Database.nextIngestNs(conn, now: now)
                    try conn.execute(sql: """
                        UPDATE item
                        SET blob_sha256 = ?,
                            blob_size = ?,
                            blob_mime = ?,
                            ocr_state = 'pending',
                            ingested_at_ns = ?
                        WHERE id = ?
                          AND origin_device = ?
                          AND blob_sha256 IS NULL
                          AND deleted_at_ns IS NULL
                    """, arguments: [info.sha256, info.size, mime, ns, cand.id, selfDeviceID])
                }
                report.refilled += 1
                log("refill-image-blobs: ok id=\(cand.id) · sha=\(info.sha256.prefix(8))… · size=\(info.size) · ext=\(ext)")
            } catch {
                report.readFailed += 1
                log("refill-image-blobs: skip id=\(cand.id) · DB UPDATE 失败: \(error)")
                continue
            }
        }
        log("refill-image-blobs: 完成 · \(report.summary)")
        return report
    }

    /// 同 PasteboardWatcher.imageExtToMime,本仓库内复制一份(跨模块 private),
    /// 改的话两处一起改
    private static func imageExtToMime(_ ext: String) -> String {
        switch ext {
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic":        return "image/heic"
        case "heif":        return "image/heif"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "tiff", "tif": return "image/tiff"
        case "bmp":         return "image/bmp"
        default:            return "application/octet-stream"
        }
    }

    // MARK: - admin-soft-delete (plan hashed-allen §F)

    public struct AdminSoftDeleteHTTPResult: Sendable, Equatable {
        /// Server cascade 实际 tombstone 的 row 数(从 response.deleted_count 读)
        public let deletedCount: Int
        public let maxIngestedNs: Int64
    }

    public struct AdminSoftDeleteDirectDBResult: Sendable, Equatable {
        public let ids: [String]
        public let maxIngestedNs: Int64
    }

    public enum AdminSoftDeleteResult: Sendable, Equatable {
        case viaHTTP(AdminSoftDeleteHTTPResult)
        case directDB(AdminSoftDeleteDirectDBResult, warning: String)
    }

    public enum AdminSoftDeleteError: Error, CustomStringConvertible, Sendable, Equatable {
        case notFound
        case alreadyDeleted
        case httpFailed(statusCode: Int, body: String)
        case badResponse(String)

        public var description: String {
            switch self {
            case .notFound: return "item id 不存在"
            case .alreadyDeleted: return "item 已 tombstone(幂等成功)"
            case .httpFailed(let code, let body): return "HTTP delete 失败 status=\(code): \(body)"
            case .badResponse(let s): return "HTTP response 解析失败: \(s)"
            }
        }
    }

    /// HTTP DELETE 请求 sender(测试可注入 mock,生产用 URLSession.shared.data(for:))
    public typealias AdminHTTPSender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// 清存量孤儿 / Mac UI 没法删的远端行(plan hashed-allen §F)。
    ///
    /// 路径:
    /// 1. **HTTP localhost 优先**:DELETE baseURL/item/<id> 让 daemon 跑 softDelete cascade +
    ///    broadcaster fan-out → peers < 1s 看到 tombstone
    /// 2. **daemon offline 降级**:直 DB softDelete cascade(不发 broadcaster);
    ///    peers 等下次 PullWorker tick(默 30s)自然兜底
    ///
    /// `forceDirect=true` 跳过 HTTP path(用户明确不想走 daemon,如 daemon 卡死时)。
    ///
    /// HTTP 错误处理:
    /// - 404 → AdminSoftDeleteError.notFound (不降级)
    /// - 410 → AdminSoftDeleteError.alreadyDeleted (不降级,等价幂等成功)
    /// - cannotConnectToHost / timedOut → 降级直 DB
    /// - 其他 HTTP 错误 → throw httpFailed(不降级,避免静默继续)
    public static func softDelete(
        id: String,
        sharedSecret: Data,
        baseURL: URL,
        dbPath: URL,
        forceDirect: Bool = false,
        httpSender: AdminHTTPSender? = nil
    ) async throws -> AdminSoftDeleteResult {
        if !forceDirect {
            do {
                let r = try await deleteViaHTTP(
                    id: id, secret: sharedSecret, baseURL: baseURL, httpSender: httpSender
                )
                return .viaHTTP(r)
            } catch let urlErr as URLError where Self.isDaemonOffline(urlErr) {
                // 降级到下面 direct DB 路径
                FileHandle.standardError.write(Data(
                    "admin-soft-delete: HTTP 不可达 (\(urlErr.code)),降级直 DB\n".utf8
                ))
            }
            // 其他错误(notFound/alreadyDeleted/httpFailed/badResponse)沿用 throw
        }
        let db = try Database(path: dbPath)
        let now = Clock.nowNs()
        let results: [(id: String, ingestedAtNs: Int64)]
        do {
            results = try await db.softDelete(id: id, now: now)
        } catch BumpError.notFound {
            throw AdminSoftDeleteError.notFound
        } catch BumpError.alreadyDeleted {
            throw AdminSoftDeleteError.alreadyDeleted
        }
        return .directDB(
            AdminSoftDeleteDirectDBResult(
                ids: results.map(\.id),
                maxIngestedNs: results.map(\.ingestedAtNs).max() ?? 0
            ),
            warning: "daemon offline,broadcaster 未 fan-out;peers 等下次 PullWorker tick(默 30s)兜底"
        )
    }

    private static func isDaemonOffline(_ e: URLError) -> Bool {
        switch e.code {
        case .cannotConnectToHost, .timedOut, .networkConnectionLost,
             .notConnectedToInternet, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    /// 200 OK body schema:`{"ok": true, "ingested_at_ns": Int64, "deleted_count": Int}`。
    /// `deleted_count` 是 PR #32 新加,老 daemon 不返 → init 给 default 1。`ingested_at_ns`
    /// 跨平台 JSON 数值可能是 Int / Int64 / Double,JSONDecoder 自动 widen 到 Int64
    private struct DeleteResponseBody: Decodable {
        let ok: Bool
        let ingested_at_ns: Int64?
        let deleted_count: Int?
    }

    private static func deleteViaHTTP(
        id: String,
        secret: Data,
        baseURL: URL,
        httpSender: AdminHTTPSender?
    ) async throws -> AdminSoftDeleteHTTPResult {
        // **HMAC canonical path 必须跟 wire path 字节一致**:server middleware 校签时用
        // `request.uri.path`(Hummingbird 不 percent-decode),client 这边 wire path 是
        // URLSession 实际发出去的字节。生产 id 是 UUID(0-9a-fA-F + `-`)在 .urlPathAllowed
        // 范围内,encoding 是 no-op;但 future id 含 `/` `%` `#` 时,显式 encode + 用
        // encoded 形式签名才能两端对齐,避免静默 401
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let path = "/item/\(encodedID)"
        let canonical = HMACAuth.canonicalPath(path)
        let auth = HMACAuth(secret: secret)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let sig = auth.sign(
            timestampMs: ts,
            method: "DELETE",
            path: canonical,
            bodyHashHex: HMACAuth.emptyBodyHashHex
        )
        // 用 URLComponents 拼装,直接写 percentEncodedPath 不走 appendingPathComponent
        // 二次 encoding。base 的现有 path(可能为空 / "/" / "/api" 等)trim 尾斜杠后跟
        // path 字面拼接,保 wire path 跟 canonical 字节一致
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AdminSoftDeleteError.badResponse("URLComponents init failed from base=\(baseURL)")
        }
        let basePath = comps.percentEncodedPath
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        comps.percentEncodedPath = trimmedBase + path
        guard let url = comps.url else {
            throw AdminSoftDeleteError.badResponse("URL compose failed from base=\(baseURL) path=\(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

        let sender = httpSender ?? { req in try await URLSession.shared.data(for: req) }
        let (data, response) = try await sender(req)
        guard let http = response as? HTTPURLResponse else {
            throw AdminSoftDeleteError.badResponse("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            let decoded: DeleteResponseBody
            do {
                decoded = try JSONDecoder().decode(DeleteResponseBody.self, from: data)
            } catch {
                throw AdminSoftDeleteError.badResponse("decode 200 body failed: \(error)")
            }
            guard decoded.ok else {
                throw AdminSoftDeleteError.badResponse("ok!=true: \(String(data: data, encoding: .utf8) ?? "")")
            }
            return AdminSoftDeleteHTTPResult(
                deletedCount: decoded.deleted_count ?? 1,
                maxIngestedNs: decoded.ingested_at_ns ?? 0
            )
        case 404:
            throw AdminSoftDeleteError.notFound
        case 410:
            throw AdminSoftDeleteError.alreadyDeleted
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AdminSoftDeleteError.httpFailed(statusCode: http.statusCode, body: body)
        }
    }
}

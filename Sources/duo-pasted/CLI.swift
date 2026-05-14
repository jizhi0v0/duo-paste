import Foundation
import DuoPasteCore
import DuoPasteSync

/// 一次性命令行入口，在 SwiftUI App 接管 NSApp 之前被 App.swift 拦截。
/// 实际逻辑都在 `DuoPasteCore.Admin`（可单测）；这里只解析 argv + 打印 + exit。
///
/// PR 4 之后只剩 `init-secret` + `retry-failed-ocr`。push 链路相关命令
/// （retry-failed / audit-push / promote-to-primary / migrate-primary）随
/// PushWorker / RemoteIngester / Admin.promote/migrate 一起删。
enum CLI {
    static func dispatchAndExitIfApplicable(args: [String] = CommandLine.arguments) {
        guard args.count >= 2 else { return }
        let cmd = args[1]
        let rest = Array(args.dropFirst(2))
        switch cmd {
        case "init-secret":
            let force = rest.contains("--force") || rest.contains("-f")
            runInitSecret(force: force)
        case "retry-failed-ocr":
            runRetryFailedOCR(args: rest)
        case "mesh-init":
            runMeshInit(args: rest)
        case "mesh-doctor":
            runMeshDoctor(args: rest)
        case "--help", "-h", "help":
            printUsage()
            exit(0)
        default:
            // 未知第一个参数：不拦截。launchctl 这种无参调用走这里。
            return
        }
    }

    private static func printUsage() {
        let text = """
        duo-pasted [subcommand]

        subcommands:
          init-secret [--force]   生成 32 字节随机 shared secret，hex 编码写到
                                  ~/Library/Application Support/duo-paste/shared-secret
                                  （0600 权限）。已存在则拒绝，加 --force 覆盖。

          retry-failed-ocr [--all | --id <ITEM_ID>]
                                  把本机 own-origin image 行的 ocr_state 翻回 pending，
                                  让 OCRWorker 重 OCR。无参数等价 --all：只动
                                  ocr_state IN ('failed', 'skipped') 的行（done 不动）。
                                  --id 模式忽略 state 黑名单——给指定 image 行强制重
                                  OCR（如 Vision 模型升级后想刷某条 done 行）。

          mesh-init --peer URL[,DEVICE_ID] [--peer URL[,DEVICE_ID]]...
                    [--serve-host H] [--serve-port P]
                    [--serve-tls | --no-serve-tls]
                    [--tls-cert PATH] [--tls-key PATH]
                    [--allow-missing-blobs] [--dry-run]
                                  把本机切到 mesh 拓扑：写 config.json 的 peers/mesh 段，
                                  显式删老 primary_url / pull 字段。--peer 可重复，每个
                                  对端 URL 一次（DEVICE_ID 可选；省略走学习模式）。
                                  默认 serve_host=0.0.0.0 / serve_port=8443，给原值不变。
                                  --serve-tls 开 TLS（peer URL 用 https://）；要配
                                  --tls-cert / --tls-key（PEM 路径，文件不存在直接 throw）。
                                  通常先 `tailscale cert <hostname>` 拿一对 cert。
                                  完成后需手动重启 daemon 让新 config 生效。
                                  daemon 必须先停（先 launchctl bootout）。
                                  --allow-missing-blobs 跳过 blob 缺失预检（默认拒）。
                                  --dry-run 跑预检 + 算 result 但不真写 config。

          mesh-doctor             探所有 peer /health + 对账本机 pull_cursor + 算本机 BlobStore
                                  缺字节统计。**只读**，不动 DB / config / blobs。
                                  退出码 0=都健康；1=任一 peer unreachable / device_id 不匹配 /
                                  blob 缺失 → 给脚本接管。
        """
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static func runInitSecret(force: Bool) {
        let paths = Paths.makeDefault()
        paths.ensureExists()
        do {
            let r = try Admin.initSecret(at: paths.sharedSecretFile, force: force)
            print("wrote \(r.path.path) · 32 bytes · mode 0600\(r.replaced ? " (overwrote existing)" : "")")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("init-secret failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runRetryFailedOCR(args: [String]) {
        // --all / --id 互斥：用户拼错或 shell history 拼接时极易踩。track 两者出现的次数，
        // 解析完一起判断比"last wins"明确得多
        var sawAll = false
        var explicitID: String? = nil
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--all":
                sawAll = true
                i += 1
            case "--id":
                if i + 1 < args.count {
                    let v = args[i + 1]
                    if v.isEmpty {
                        FileHandle.standardError.write(Data("retry-failed-ocr: --id 值不能为空\n".utf8))
                        exit(1)
                    }
                    explicitID = v
                    i += 2
                } else {
                    FileHandle.standardError.write(Data("retry-failed-ocr: --id 缺值\n".utf8))
                    exit(1)
                }
            default:
                FileHandle.standardError.write(Data("retry-failed-ocr: 未知参数 \(args[i])\n".utf8))
                exit(1)
            }
        }
        let scope: Admin.OCRRetryScope
        if sawAll && explicitID != nil {
            FileHandle.standardError.write(Data("retry-failed-ocr: --all 和 --id 互斥\n".utf8))
            exit(1)
        } else if let id = explicitID {
            scope = .id(id)
        } else {
            scope = .all   // 无参 = --all
        }
        let paths = Paths.makeDefault()
        paths.ensureExists()
        let deviceID: String
        do {
            deviceID = try DeviceID.loadOrCreate(at: paths.deviceIDFile)
        } catch {
            FileHandle.standardError.write(Data("retry-failed-ocr: 读 device-id 失败: \(error)\n".utf8))
            exit(1)
        }
        do {
            let n = try Admin.retryFailedOCR(
                dbPath: paths.mainDB,
                selfDeviceID: deviceID,
                scope: scope
            )
            switch scope {
            case .all:
                print("reset \(n) image item(s) to ocr_state=pending")
            case .id(let id):
                print("reset \(n) row(s) for id=\(id) to ocr_state=pending")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("retry-failed-ocr failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runMeshInit(args: [String]) {
        var peerSpecs: [String] = []   // 原始 "URL[,DEVICE_ID]" 串，按出现顺序
        var serveHost: String? = nil
        var servePort: Int? = nil
        var serveTLS: Bool? = nil
        var tlsCertPath: String? = nil
        var tlsKeyPath: String? = nil
        var allowMissingBlobs = false
        var dryRun = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--peer":
                if i + 1 < args.count {
                    peerSpecs.append(args[i + 1])
                    i += 2
                } else {
                    FileHandle.standardError.write(Data("mesh-init: --peer 缺值\n".utf8))
                    exit(1)
                }
            case "--serve-host":
                if i + 1 < args.count {
                    serveHost = args[i + 1]
                    i += 2
                } else {
                    FileHandle.standardError.write(Data("mesh-init: --serve-host 缺值\n".utf8))
                    exit(1)
                }
            case "--serve-port":
                if i + 1 < args.count, let p = Int(args[i + 1]), (1...65535).contains(p) {
                    servePort = p
                    i += 2
                } else {
                    FileHandle.standardError.write(Data("mesh-init: --serve-port 缺值或越界 (1-65535)\n".utf8))
                    exit(1)
                }
            case "--serve-tls":
                serveTLS = true
                i += 1
            case "--no-serve-tls":
                serveTLS = false
                i += 1
            case "--tls-cert":
                if i + 1 < args.count {
                    tlsCertPath = args[i + 1]
                    i += 2
                } else {
                    FileHandle.standardError.write(Data("mesh-init: --tls-cert 缺值\n".utf8))
                    exit(1)
                }
            case "--tls-key":
                if i + 1 < args.count {
                    tlsKeyPath = args[i + 1]
                    i += 2
                } else {
                    FileHandle.standardError.write(Data("mesh-init: --tls-key 缺值\n".utf8))
                    exit(1)
                }
            case "--allow-missing-blobs":
                allowMissingBlobs = true
                i += 1
            case "--dry-run":
                dryRun = true
                i += 1
            default:
                FileHandle.standardError.write(Data("mesh-init: 未知参数 \(args[i])\n".utf8))
                exit(1)
            }
        }

        if peerSpecs.isEmpty {
            FileHandle.standardError.write(Data("mesh-init: 至少要 --peer 一次\n".utf8))
            exit(1)
        }

        // parse "URL[,DEVICE_ID]" → URL + optional deviceID
        var peerURLs: [URL] = []
        var peerDeviceIDs: [String?] = []
        for spec in peerSpecs {
            let parts = spec.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let urlStr = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: urlStr),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil
            else {
                FileHandle.standardError.write(Data("mesh-init: --peer URL 非法 (需 http/https + host)：\(urlStr)\n".utf8))
                exit(1)
            }
            peerURLs.append(url)
            if parts.count == 2 {
                let did = String(parts[1]).trimmingCharacters(in: .whitespaces)
                peerDeviceIDs.append(did.isEmpty ? nil : did)
            } else {
                peerDeviceIDs.append(nil)
            }
        }

        let paths = Paths.makeDefault()
        paths.ensureExists()
        let blobs = BlobStore(root: paths.blobsDir)
        // 同 promote 路径 #6：dev 跑 swift run 不在 launchctl 管理下 → false 放行
        // 用户手动 bootout 是责任
        let daemonRunning = LaunchAgent.isRunning(label: LaunchAgent.duoPastedLabel)

        let result: Admin.MeshInitResult
        do {
            result = try Admin.meshInit(
                configPath: paths.configFile,
                dbPath: paths.mainDB,
                blobs: blobs,
                peerURLs: peerURLs,
                peerDeviceIDs: peerDeviceIDs,
                serveHost: serveHost ?? "0.0.0.0",  // mesh 部署默认开 LAN，不像 standalone 默 127.0.0.1
                servePort: servePort,
                serveTLS: serveTLS,
                tlsCertPath: tlsCertPath,
                tlsKeyPath: tlsKeyPath,
                allowMissingBlobs: allowMissingBlobs,
                dryRun: dryRun,
                daemonRunning: daemonRunning,
                daemonLabel: LaunchAgent.duoPastedLabel
            )
        } catch {
            FileHandle.standardError.write(Data("mesh-init failed: \(error)\n".utf8))
            exit(1)
        }

        var lines: [String] = []
        if result.dryRun {
            lines.append("mesh-init dry-run · 未写 config")
        } else {
            lines.append("mesh-init done · config 已写到 \(result.configWrittenTo.path)")
        }
        lines.append("  peers: \(result.peerURLs.count)")
        for (i, url) in result.peerURLs.enumerated() {
            let did = (i < peerDeviceIDs.count) ? (peerDeviceIDs[i] ?? "(learn)") : "(learn)"
            lines.append("    - \(url.absoluteString) · device_id=\(did)")
        }
        if !result.removedLegacyKeys.isEmpty {
            lines.append("  removed legacy keys: \(result.removedLegacyKeys.joined(separator: ", "))")
        }
        if result.missingBlobsTotal > 0 {
            lines.append("")
            lines.append("⚠ WARNING: \(result.missingBlobsTotal) 个 blob 在本机 BlobStore 缺字节")
            lines.append("  这些 image/file 历史在本机 /blob/<sha> 上将返回 404。示例 sha：")
            for sha in result.missingBlobsSamples {
                lines.append("    - \(sha)")
            }
        }
        if !result.dryRun {
            lines.append("")
            lines.append("下一步：重启 daemon 让新 config 生效")
            lines.append("  launchctl bootstrap gui/$UID ~/Library/LaunchAgents/\(LaunchAgent.duoPastedLabel).plist")
            lines.append("  launchctl enable    gui/$UID/\(LaunchAgent.duoPastedLabel)")
            lines.append("  launchctl kickstart -k gui/$UID/\(LaunchAgent.duoPastedLabel)")
            lines.append("  （若 daemon 仍处于 loaded 状态，跳过 bootstrap/enable 直接 kickstart）")
        }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        exit(0)
    }

    private static func runMeshDoctor(args: [String]) {
        // mesh-doctor 当前没参数（未来可加 --json / --peer 限定）
        if !args.isEmpty {
            FileHandle.standardError.write(Data("mesh-doctor: 未知参数 \(args.joined(separator: " "))\n".utf8))
            exit(1)
        }
        let paths = Paths.makeDefault()
        paths.ensureExists()
        let cfg: Config
        do {
            cfg = try Config.load(from: paths.configFile)
        } catch {
            FileHandle.standardError.write(Data("mesh-doctor: 读 config 失败：\(error)\n".utf8))
            exit(1)
        }
        let deviceID: String
        do {
            deviceID = try DeviceID.loadOrCreate(at: paths.deviceIDFile)
        } catch {
            FileHandle.standardError.write(Data("mesh-doctor: 读 device-id 失败：\(error)\n".utf8))
            exit(1)
        }
        let blobs = BlobStore(root: paths.blobsDir)
        let secret: Data?
        do {
            secret = try SharedSecret.load(from: paths.sharedSecretFile)
        } catch {
            // 没 shared-secret 时仍能跑（只是不能探 /health），把所有 peer 标 unreachable
            secret = nil
            FileHandle.standardError.write(Data(
                "mesh-doctor: 加载 shared-secret 失败：\(error) — peer /health 全部 unreachable\n".utf8
            ))
        }
        // 把 HTTPPeerClient.fetchPrimaryHealth 翻译成 Admin.HealthProbeOutcome
        let probe: @Sendable (URL) async -> Admin.HealthProbeOutcome = { url in
            guard let secret else {
                return .unreachable(reason: "shared-secret 未配置")
            }
            // CLI 是 one-shot exit，没必要复用 keep-alive 连接池——URLSession.shared 够了
            let client = HTTPPeerClient(
                baseURL: url,
                auth: HMACAuth(secret: secret)
            )
            do {
                let r = try await client.fetchPrimaryHealth()
                switch r.outcome {
                case .ok(let did, let nowMs): return .ok(deviceID: did, nowMs: nowMs)
                case .unreachable(let reason): return .unreachable(reason: reason)
                case .rejected(let reason): return .rejected(reason: reason)
                }
            } catch {
                return .unreachable(reason: "\(error)")
            }
        }
        let report: Admin.MeshDoctorReport
        do {
            report = try runBlocking { @Sendable in
                try await Admin.meshDoctor(
                    selfDeviceID: deviceID,
                    peers: cfg.peers,
                    dbPath: paths.mainDB,
                    blobs: blobs,
                    healthProbe: probe
                )
            }
        } catch {
            FileHandle.standardError.write(Data("mesh-doctor failed: \(error)\n".utf8))
            exit(1)
        }
        printMeshDoctorReport(report)
        exit(meshDoctorExitCode(report))
    }

    /// async → sync 桥。CLI 路径上没有 runtime；用 DispatchSemaphore + 一个分离 task
    private static func runBlocking<T: Sendable>(_ op: @Sendable @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await op()) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    private static func printMeshDoctorReport(_ r: Admin.MeshDoctorReport) {
        var lines: [String] = []
        lines.append("mesh-doctor")
        lines.append("  self device_id: \(r.selfDeviceID)")
        lines.append("  self max ingested_at_ns: \(r.selfMaxIngestedNs)")
        lines.append("  peers: \(r.peers.count)")
        for peer in r.peers {
            lines.append("")
            lines.append("  peer: \(peer.url.absoluteString)")
            if let exp = peer.expectedDeviceID {
                lines.append("    expected device_id: \(exp)")
            } else {
                lines.append("    expected device_id: (learn mode — config 没指定)")
            }
            switch peer.health {
            case .ok(let did, let nowMs, let skewMs):
                let mark = (peer.deviceIDMatches == false) ? " ⚠ MISMATCH" : ""
                lines.append("    health: ✓ device_id=\(did)\(mark) · now_ms=\(nowMs) · skew=\(skewMs)ms")
            case .unreachable(let reason):
                lines.append("    health: ✗ unreachable — \(reason)")
            case .rejected(let reason):
                lines.append("    health: ✗ rejected — \(reason)")
            }
            if let cur = peer.pullCursor {
                let lag = max(0, r.selfMaxIngestedNs - cur.cursorNs)
                let lagDesc = lag == 0 ? "(同步)" : "(本机 own 比对端记录的 cursor 多 \(lag) ns；正常对端拉本机时这差额是 0+)"
                lines.append("    pull_cursor: ns=\(cur.cursorNs) id=\(cur.cursorID)")
                lines.append("    cursor lag: \(lag) \(lagDesc)")
            } else {
                lines.append("    pull_cursor: (无——首次启动 / device_id 学习中 / config 改 expected 后未追平)")
            }
        }
        if r.missingBlobsTotal > 0 {
            lines.append("")
            lines.append("⚠ missing blobs: \(r.missingBlobsTotal) 个 sha 在本机 BlobStore 缺字节")
            lines.append("  这些 image/file 历史在本机 /blob/<sha> 上将返回 404。示例 sha：")
            for sha in r.missingBlobsSamples {
                lines.append("    - \(sha)")
            }
        } else {
            lines.append("")
            lines.append("blobs: ✓ 本机 image/file 行的 sha 全部在 BlobStore")
        }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// 退出码：任一 peer unreachable/rejected/device_id 不匹配 / blob 缺失 → 1。便于脚本管控
    private static func meshDoctorExitCode(_ r: Admin.MeshDoctorReport) -> Int32 {
        if r.missingBlobsTotal > 0 { return 1 }
        for peer in r.peers {
            switch peer.health {
            case .ok:
                if peer.deviceIDMatches == false { return 1 }
            case .unreachable, .rejected:
                return 1
            }
        }
        return 0
    }
}

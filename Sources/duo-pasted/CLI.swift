import Foundation
import DuoPasteCore
import DuoPasteSync

/// 一次性命令行入口，在 SwiftUI App 接管 NSApp 之前被 App.swift 拦截。
/// 实际逻辑都在 `DuoPasteCore.Admin`（可单测）；这里只解析 argv + 打印 + exit。
enum CLI {
    static func dispatchAndExitIfApplicable(args: [String] = CommandLine.arguments) {
        guard args.count >= 2 else { return }
        let cmd = args[1]
        let rest = Array(args.dropFirst(2))
        switch cmd {
        case "init-secret":
            let force = rest.contains("--force") || rest.contains("-f")
            runInitSecret(force: force)
        case "retry-failed":
            runRetryFailed()
        case "retry-failed-ocr":
            runRetryFailedOCR(args: rest)
        case "audit-push":
            runAuditPush(args: rest)
        case "promote-to-primary":
            runPromoteToPrimary(args: rest)
        case "migrate-primary":
            runMigratePrimary(args: rest)
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

          retry-failed            把所有 push_state=failed 的 item 重置回 pending，
                                  下次 push worker 会重试。push_attempts 清零、
                                  last_push_error 清空。

          retry-failed-ocr [--all | --id <ITEM_ID>]
                                  把本机 own-origin image 行的 ocr_state 翻回 pending，
                                  让 OCRWorker 重 OCR。无参数等价 --all：只动
                                  ocr_state IN ('failed', 'skipped') 的行（done 不动）。
                                  --id 模式忽略 state 黑名单——给指定 image 行强制重
                                  OCR（如 Vision 模型升级后想刷某条 done 行）。
                                  last_push_error 清空。

          audit-push [--sample N] 拿本机 own-origin item 跟 primary /since 全量对账，
                                  报告 push_state 分布 + 哪些本地有但 primary 没收到。
                                  N 默认 20，限制 missing/failed 样本输出条数。
                                  promote-to-primary 之前的健康检查。需要 config.json
                                  里配 primary_url + 本机有 shared-secret。

          promote-to-primary [--serve-host H] [--serve-port P]
                             [--allow-missing-blobs]
                                  把本机从 client 升级为 primary：item_mirror → item、
                                  stamp own-origin null ingested_at_ns、清空 mirror/
                                  pull_cursor、写 primary_lineage、改 config.json
                                  （serve=true, primary_url 移除, pull.enabled=false）。
                                  默认预检 blob 缺失：mirror 元数据齐但本机 BlobStore 没
                                  字节的 sha 会让 promote 中止（DR 操作不该静默丢
                                  image/file 历史）。--allow-missing-blobs 跳过此检查
                                  让 promote 继续，缺失会被报告但不能自愈。
                                  仅在 client 模式下可用。完成后需手动 kickstart daemon
                                  让新配置生效，并到其他 client 改 primary_url。

          migrate-primary [--new-primary-host HOST]
                                  计划内换 primary 的 prepare 阶段：在老 primary 上跑，
                                  VACUUM INTO 落一份一致性 snapshot 到 snapshots/，
                                  统计 blobs/ 文件数和字节数 + item 行数，然后打印
                                  rsync 命令模板 + 新机配置步骤 + 其他 client 后续动作。
                                  本命令是只读操作（除了写 snapshot 文件这个副产物），
                                  不动 DB / config / blobs/。
                                  --new-primary-host 是可选 hint，只用于美化 rsync 命令
                                  模板里的 user@host 占位符；省略时模板用 <NEW-HOST>。
                                  仅在 primary 模式下可用。daemon 必须先停（避免 snapshot
                                  之后 ingest 新行被 rsync 漏掉）。
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

    private static func runAuditPush(args: [String]) {
        var sampleLimit = 20
        var i = 0
        while i < args.count {
            if args[i] == "--sample", i + 1 < args.count, let n = Int(args[i + 1]), n > 0 {
                sampleLimit = n
                i += 2
            } else {
                i += 1
            }
        }
        let paths = Paths.makeDefault()
        // 必须能读 primary_url + shared-secret + device-id，否则没法发请求
        let config: Config
        do {
            config = try Config.load(from: paths.configFile)
        } catch {
            FileHandle.standardError.write(Data("audit-push: 读 config 失败: \(error)\n".utf8))
            exit(1)
        }
        guard let primaryURL = config.primaryURL else {
            FileHandle.standardError.write(Data("audit-push: config.primary_url 未配置；这台机器没接 primary，无需对账\n".utf8))
            exit(1)
        }
        let secret: Data
        do {
            secret = try SharedSecret.load(from: paths.sharedSecretFile)
        } catch {
            FileHandle.standardError.write(Data("audit-push: 加载 shared-secret 失败: \(error)\n".utf8))
            exit(1)
        }
        let deviceID: String
        do {
            deviceID = try DeviceID.loadOrCreate(at: paths.deviceIDFile)
        } catch {
            FileHandle.standardError.write(Data("audit-push: 读 device-id 失败: \(error)\n".utf8))
            exit(1)
        }
        let database: Database
        do {
            database = try Database(path: paths.mainDB, role: config.derivedDatabaseRole)
        } catch {
            FileHandle.standardError.write(Data("audit-push: 打开 DB 失败: \(error)\n".utf8))
            exit(1)
        }
        let client = HTTPIngestClient(baseURL: primaryURL, auth: HMACAuth(secret: secret))
        let report: AuditPush.Report
        let capturedSampleLimit = sampleLimit
        do {
            report = try runBlocking { @Sendable in
                try await AuditPush.run(
                    database: database,
                    selfDeviceID: deviceID,
                    fetchPage: { @Sendable cursor, limit in
                        let r = try await client.fetchSince(cursor: cursor, limit: limit)
                        switch r.outcome {
                        case .ok(let p):           return p
                        case .unreachable(let r):  throw AuditPush.AuditError.sinceFailed(reason: r)
                        case .rejected(let r):    throw AuditPush.AuditError.sinceFailed(reason: r)
                        }
                    },
                    sampleLimit: capturedSampleLimit
                )
            }
        } catch {
            FileHandle.standardError.write(Data("audit-push failed: \(error)\n".utf8))
            exit(1)
        }
        printAuditReport(report, primaryURL: primaryURL, sampleLimit: sampleLimit)
        // exit 码：missing / failed / stale 任一非 0 → 1，便于脚本接管。
        // dedupAbsorbed 是预期行为不计入。stale 走 exit 1 是因为 RemoteIngester 当前不更新已有
        // 行，操作员需要先解决（手动重 push、或 promote 之后才能"修正"primary 状态）
        exit((report.missingTotal > 0 || report.failed > 0 || report.staleTotal > 0) ? 1 : 0)
    }

    /// async → sync 桥。CLI 路径上没有 runtime；用 DispatchSemaphore + 一个分离 task。
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

    private static func printAuditReport(_ r: AuditPush.Report, primaryURL: URL, sampleLimit: Int) {
        var lines: [String] = []
        lines.append("audit-push · primary=\(primaryURL.absoluteString)")
        lines.append("")
        lines.append("local own items: total=\(r.localOwnTotal) acked=\(r.acked) pending=\(r.pending) failed=\(r.failed)")
        lines.append("primary /since:  total=\(r.primaryItemTotal) (含所有 origin)")
        lines.append("missing on primary: \(r.missingTotal)\(r.missingTotal > sampleLimit ? " (展示前 \(sampleLimit) 条)" : "")")
        for id in r.missingOnPrimary {
            lines.append("  - \(id)")
        }
        if r.dedupAbsorbed > 0 {
            lines.append("")
            lines.append("continuity dedup absorbed: \(r.dedupAbsorbed)\(r.dedupAbsorbed > sampleLimit ? " (展示前 \(sampleLimit) 条)" : "") · 预期行为，跨设备同内容被 primary 用别的 id 承接")
            for s in r.dedupAbsorbedSamples {
                lines.append("  - \(s.localID) → \(s.absorbedByID)")
            }
        }
        if r.dedupAbsorbedThenDeleted > 0 {
            lines.append("")
            lines.append("continuity dedup absorbed (后被软删): \(r.dedupAbsorbedThenDeleted)\(r.dedupAbsorbedThenDeleted > sampleLimit ? " (展示前 \(sampleLimit) 条)" : "") · 吸收源已被 tombstone，确认是否预期删除")
            for s in r.dedupAbsorbedThenDeletedSamples {
                lines.append("  - \(s.localID) → \(s.absorbedByID) (deleted)")
            }
        }
        if r.staleTotal > 0 {
            lines.append("")
            lines.append("stale on primary: \(r.staleTotal)\(r.staleTotal > sampleLimit ? " (展示前 \(sampleLimit) 条)" : "") · 本地 state 已变但 primary 未更新（RemoteIngester 当前不更新已有行）")
            for s in r.staleSamples {
                lines.append("  - \(s.id): \(s.reasons.joined(separator: ", "))")
            }
        }
        if !r.failedSamples.isEmpty {
            lines.append("")
            lines.append("failed samples:")
            for s in r.failedSamples {
                let err = s.lastError ?? "(no error recorded)"
                lines.append("  - \(s.id) attempts=\(s.attempts) err=\(err)")
            }
        }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func runPromoteToPrimary(args: [String]) {
        var serveHost: String? = nil
        var servePort: Int? = nil
        var allowMissingBlobs = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--serve-host":
                if i + 1 < args.count {
                    serveHost = args[i + 1]
                    i += 2
                } else {
                    FileHandle.standardError.write(Data("promote-to-primary: --serve-host 缺值\n".utf8))
                    exit(1)
                }
            case "--serve-port":
                if i + 1 < args.count, let p = Int(args[i + 1]), (1...65535).contains(p) {
                    servePort = p
                    i += 2
                } else {
                    FileHandle.standardError.write(Data("promote-to-primary: --serve-port 缺值或越界 (1-65535)\n".utf8))
                    exit(1)
                }
            case "--allow-missing-blobs":
                allowMissingBlobs = true
                i += 1
            default:
                FileHandle.standardError.write(Data("promote-to-primary: 未知参数 \(args[i])\n".utf8))
                exit(1)
            }
        }

        let paths = Paths.makeDefault()
        let deviceID: String
        do {
            deviceID = try DeviceID.loadOrCreate(at: paths.deviceIDFile)
        } catch {
            FileHandle.standardError.write(Data("promote-to-primary: 读 device-id 失败: \(error)\n".utf8))
            exit(1)
        }

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let blobs = BlobStore(root: paths.blobsDir)
        // P1 review fix: 查 daemon 在不在跑。dev 场景 swift run 直接跑（不在 launchctl 管理下）
        // 会被识别为 false，进入 promote——CLAUDE.md 已写 dev 跑前先 bootout 是用户责任
        let daemonRunning = LaunchAgent.isRunning(label: LaunchAgent.duoPastedLabel)
        let result: Admin.PromoteResult
        do {
            result = try Admin.promoteToPrimary(
                dbPath: paths.mainDB,
                configPath: paths.configFile,
                blobs: blobs,
                selfDeviceID: deviceID,
                now: now,
                serveHost: serveHost,
                servePort: servePort,
                allowMissingBlobs: allowMissingBlobs,
                daemonRunning: daemonRunning,
                daemonLabel: LaunchAgent.duoPastedLabel
            )
        } catch {
            FileHandle.standardError.write(Data("promote-to-primary failed: \(error)\n".utf8))
            exit(1)
        }

        var lines: [String] = []
        lines.append("promote-to-primary done")
        lines.append("  promoted (mirror → item):       \(result.promotedRows) rows")
        lines.append("  cleared item_mirror:            \(result.mirrorClearedRows) rows")
        lines.append("  stamped ingested_at_ns:         \(result.stampedRows) rows (含 client 路径老 own-origin)")
        if let old = result.oldPrimaryURL {
            lines.append("  old primary_url removed:        \(old.absoluteString)")
        }
        if let oldID = result.lineageOldPrimaryID {
            lines.append("  lineage closed prior primary:   device_id=\(oldID) ended_at_ns=\(now)")
        } else {
            lines.append("  lineage closed prior primary:   (none — pull_cursor 之前为空)")
        }
        lines.append("  lineage opened self tenure:     device_id=\(deviceID) started_at_ns=\(now)")
        lines.append("  config rewritten:               \(result.configWrittenTo.path)")
        if result.missingBlobsTotal > 0 {
            lines.append("")
            lines.append("⚠ WARNING: \(result.missingBlobsTotal) 个 blob 在本机 BlobStore 缺失")
            lines.append("  image/file 类历史在 /blob/<sha> 上将返回 404。示例 sha：")
            for sha in result.missingBlobsSamples {
                lines.append("    - \(sha)")
            }
            lines.append("  --allow-missing-blobs 让 promote 继续，但缺失字节没法自愈。")
        }
        lines.append("")
        lines.append("下一步：")
        lines.append("  1. 装回 LaunchAgent 并以新 config 拉起 daemon（与 install-agent.sh 一致）：")
        lines.append("       launchctl bootstrap gui/$UID ~/Library/LaunchAgents/\(LaunchAgent.duoPastedLabel).plist")
        lines.append("       launchctl enable    gui/$UID/\(LaunchAgent.duoPastedLabel)")
        lines.append("       launchctl kickstart -k gui/$UID/\(LaunchAgent.duoPastedLabel)")
        lines.append("     （若 daemon 不是通过 launchctl bootout 停掉而是仍处于 loaded 状态，跳过 bootstrap/enable、直接 kickstart 即可）")
        lines.append("  2. 到其他 client 把 config.json 里的 primary_url 改成本机的可达地址，")
        lines.append("     然后跑 `duo-pasted audit-push` 补『老 primary acked 但 mirror 未拉到』的洞。")
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        exit(0)
    }

    private static func runMigratePrimary(args: [String]) {
        var newHost: String? = nil
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--new-primary-host":
                if i + 1 < args.count {
                    let h = args[i + 1]
                    // 严格 hostname 校验：拒绝 shell 元字符，防止打印的 rsync/ssh 模板
                    // 在被操作员复制到 shell 后被解释成命令注入（"mini; rm -rf ~" 之类）。
                    // 允许字符集：hostname / IP / Tailscale MagicDNS / 可选端口
                    if !ShellTemplate.isSafeHost(h) {
                        FileHandle.standardError.write(Data(
                            "migrate-primary: --new-primary-host 含非法字符（只允许 A-Za-z0-9 . - _ :）\n".utf8
                        ))
                        exit(1)
                    }
                    newHost = h
                    i += 2
                } else {
                    FileHandle.standardError.write(Data("migrate-primary: --new-primary-host 缺值\n".utf8))
                    exit(1)
                }
            default:
                FileHandle.standardError.write(Data("migrate-primary: 未知参数 \(args[i])\n".utf8))
                exit(1)
            }
        }

        let paths = Paths.makeDefault()
        let daemonRunning = LaunchAgent.isRunning(label: LaunchAgent.duoPastedLabel)
        let result: Admin.MigratePrimaryResult
        do {
            result = try Admin.migratePrimary(
                dbPath: paths.mainDB,
                configPath: paths.configFile,
                blobsRoot: paths.blobsDir,
                snapshotsDir: paths.snapshotsDir,
                daemonRunning: daemonRunning,
                daemonLabel: LaunchAgent.duoPastedLabel
            )
        } catch {
            FileHandle.standardError.write(Data("migrate-primary failed: \(error)\n".utf8))
            exit(1)
        }
        printMigrateReport(result, newHost: newHost)
        exit(0)
    }

    private static func printMigrateReport(_ r: Admin.MigratePrimaryResult, newHost: String?) {
        let hostPlaceholder = newHost ?? "<NEW-HOST>"
        let snapshotShellPath = ShellTemplate.singleQuote(r.snapshotPath.path)
        let blobsShellPath = ShellTemplate.singleQuote(r.blobsRoot.path)
        let totalBytes = r.snapshotBytes + r.blobsTotalBytes
        var lines: [String] = []
        lines.append("migrate-primary · snapshot 已落地")
        lines.append("")
        lines.append("快照：")
        lines.append("  \(r.snapshotPath.path)")
        lines.append("  \(formatBytes(r.snapshotBytes)) · item=\(r.itemRowCount) 行" +
                     (r.itemMirrorRowCount > 0 ? " · ⚠ item_mirror=\(r.itemMirrorRowCount) 行（本机历史 client 残留，会被一起迁过去）" : ""))
        lines.append("")
        lines.append("Blobs：")
        lines.append("  \(r.blobsRoot.path)")
        lines.append("  \(r.blobsTotalFiles) 个文件 · \(formatBytes(r.blobsTotalBytes))")
        lines.append("")
        lines.append("传输总量预估：\(formatBytes(totalBytes))（snapshot + blobs）")
        lines.append("")
        lines.append("下一步（手动执行）：")
        lines.append("  1. 把 snapshot + blobs/ rsync 到新机：")
        lines.append("       # 新机上先建好目标目录：")
        lines.append("       ssh user@\(hostPlaceholder) 'mkdir -p ~/Library/Application\\ Support/duo-paste/{db,blobs}'")
        lines.append("       # 拷快照（重命名为 main.sqlite 让 daemon 直接接管）：")
        lines.append("       scp \(snapshotShellPath) \\")
        lines.append("           user@\(hostPlaceholder):~/Library/Application\\ Support/duo-paste/db/main.sqlite")
        lines.append("       # 拷 blobs（--checksum 让 rsync 自己校验，跳过用 --size-only 加速）：")
        lines.append("       rsync -avh --checksum \(blobsShellPath)/ \\")
        lines.append("           user@\(hostPlaceholder):~/Library/Application\\ Support/duo-paste/blobs/")
        lines.append("  2. 在新机上：")
        lines.append("     - 拷一份 shared-secret 文件（三台机必须同份，0600 权限）")
        lines.append("     - 写 config.json：{ \"serve\": true, \"serve_host\": \"0.0.0.0\", \"serve_port\": 8443 }")
        lines.append("     - ./scripts/install-agent.sh 装 LaunchAgent 起 daemon")
        lines.append("  3. 在其他 client 上：")
        lines.append("     - 改 config.json 的 primary_url 指向新机的可达地址")
        lines.append("     - launchctl kickstart -k gui/$UID/\(LaunchAgent.duoPastedLabel) 重启")
        lines.append("     - 跑 `duo-pasted audit-push` 验证 own-origin item 在新 primary 上齐全")
        lines.append("")
        lines.append("提醒：本命令未修改本机 config / DB / blobs，老 primary 可保留或手动退役。")
        lines.append("      lineage 表的「新 primary 接管」行未写——audit-push 单 primary 部署不受影响，")
        lines.append("      多次换 primary 链路下可能产生跨任期 dedup 误判。")
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// 把字节数渲染成人类可读字符串（1.2 GB / 350 MB / 12 KB / 800 B）。
    /// 用于 migrate-primary 报告，操作员主要关心传输总量量级
    private static func formatBytes(_ b: Int64) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let v = Double(b)
        if v >= gb { return String(format: "%.2f GB", v / gb) }
        if v >= mb { return String(format: "%.2f MB", v / mb) }
        if v >= kb { return String(format: "%.1f KB", v / kb) }
        return "\(b) B"
    }


    private static func runRetryFailed() {
        let paths = Paths.makeDefault()
        do {
            let count = try Admin.retryFailed(dbPath: paths.mainDB)
            print("reset \(count) failed item(s) to pending")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("retry-failed failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runRetryFailedOCR(args: [String]) {
        var scope: Admin.OCRRetryScope = .all
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--all":
                scope = .all
                i += 1
            case "--id":
                if i + 1 < args.count {
                    scope = .id(args[i + 1])
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
}

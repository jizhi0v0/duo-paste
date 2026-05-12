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
        case "audit-push":
            runAuditPush(args: rest)
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

          audit-push [--sample N] 拿本机 own-origin item 跟 primary /since 全量对账，
                                  报告 push_state 分布 + 哪些本地有但 primary 没收到。
                                  N 默认 20，限制 missing/failed 样本输出条数。
                                  promote-to-primary 之前的健康检查。需要 config.json
                                  里配 primary_url + 本机有 shared-secret。
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
}

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
                    [--allow-missing-blobs] [--dry-run]
                                  把本机切到 mesh 拓扑：写 config.json 的 peers/mesh 段，
                                  显式删老 primary_url / pull 字段。--peer 可重复，每个
                                  对端 URL 一次（DEVICE_ID 可选；省略走学习模式）。
                                  默认 serve_host=0.0.0.0 / serve_port=8443，给原值不变。
                                  完成后需手动重启 daemon 让新 config 生效。
                                  daemon 必须先停（先 launchctl bootout）。
                                  --allow-missing-blobs 跳过 blob 缺失预检（默认拒）。
                                  --dry-run 跑预检 + 算 result 但不真写 config。
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
}

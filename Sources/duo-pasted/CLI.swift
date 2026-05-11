import Foundation
import DuoPasteCore

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

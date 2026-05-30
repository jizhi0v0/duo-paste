import Foundation
import os.log
import DuoPasteCore

private let logger = Logger(subsystem: "io.duopaste.daemon", category: "RelaunchHelper")

/// 方案 A 的 relaunch helper：把「Sparkle 装完新 bundle 后让 launchd 拉起新版」这步从
/// 宿主进程里分离出去。两段：
///   - `spawnDetached()`：宿主（updater delegate）在被 Sparkle terminate 前调用，用
///     posix_spawn + POSIX_SPAWN_SETSID 起一个**脱离进程组/session** 的子进程，跑本
///     binary 的 `__relaunch-helper` 子命令。脱离是必须的——launchd bootout 杀整个进程组
///     （Layer1-C 实测：plain `&` / nohup 子进程都被连带杀），只有 SETSID 新 session 能活。
///   - `run(...)`：helper 子进程逻辑。poll 安装目录 Info.plist 的 CFBundleVersion，变了
///     （= Sparkle Installer 已原子替换新 bundle）就 `launchctl kickstart -k` 让 launchd
///     启动新版。时序无关：不猜 Sparkle 内部 terminate/install 先后，只认「版本变了」这个
///     事实信号；超时未变则静默退出（用户取消更新 / install 失败的安全兜底）。
///
/// 为什么 helper 能在 bundle 被替换后存活：posix_spawn 在 spawn 时把 binary 映射进内存，
/// 之后 Sparkle 原子替换整个 .app 目录只是 unlink 旧 inode，运行中的 helper 持旧 inode
/// 不受影响（Unix 文件语义；Layer2b 实测 helper 在宿主 bootout 后存活并成功 kickstart）。
enum RelaunchHelper {
    /// LaunchAgent label，跟 install-agent.sh 写出的 plist 对齐（= LaunchAgent.duoPastedLabel）。
    static let agentLabel = "io.duopaste.agent"

    /// 隐藏子命令名。CLI.dispatch 命中后调 `run(args:)`，不进 printUsage 公开列表。
    static let subcommand = "__relaunch-helper"

    /// 宿主侧：spawn detached helper。在 `updaterShouldRelaunchApplication` 返回 NO 前调用。
    static func spawnDetached() {
        // 用当前可执行路径（旧 bundle 内的 duo-pasted）。spawn 时即载入内存，之后 bundle
        // 被替换不影响已运行的 helper。
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "/usr/bin/false"
        let bundlePath = Bundle.main.bundlePath
        let oldVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""

        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        // POSIX_SPAWN_SETSID：子进程进入新 session，脱离宿主进程组——bootout 不连带杀。
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        defer { posix_spawnattr_destroy(&attr) }

        let argv: [String] = [exe, subcommand, agentLabel, bundlePath, oldVersion]
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, nil, &attr, cArgv, environ)
        if rc == 0 {
            logger.info("relaunch helper spawned pid=\(pid, privacy: .public) bundle=\(bundlePath, privacy: .public) oldVer=\(oldVersion, privacy: .public)")
        } else {
            logger.error("relaunch helper spawn failed rc=\(rc, privacy: .public)")
        }
    }

    /// helper 子进程入口。args = [label, bundlePath, oldVersion]。
    /// 阻塞 poll 直到版本变化或超时，然后（变化时）kickstart。返回进程 exit code。
    static func run(args: [String]) -> Int32 {
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("__relaunch-helper: 需要 <label> <bundlePath> <oldVersion>\n".utf8))
            return 2
        }
        let label = args[0]
        let bundlePath = args[1]
        let oldVersion = args[2]
        let infoPlist = bundlePath + "/Contents/Info.plist"

        // poll：最多 120s（DERP 中继 + Installer XPC 慢路径留足余量），每 0.5s 一次。
        // 信号 = 安装目录 Info.plist 的 CFBundleVersion 不再等于 oldVersion。
        let deadline = Date().addingTimeInterval(120)
        var newVersion: String? = nil
        while Date() < deadline {
            if let v = readBundleVersion(infoPlist), v != oldVersion, !v.isEmpty {
                newVersion = v
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard let nv = newVersion else {
            // 版本一直没变：用户取消更新 / 安装失败 / 超时。不 kickstart——daemon 维持现状，
            // launchd 的 KeepAlive 仍管着旧版（若它被 terminate 了，崩溃自愈会拉回）。
            FileHandle.standardError.write(Data("__relaunch-helper: 120s 内版本未变（old=\(oldVersion)），不 kickstart 退出\n".utf8))
            return 0
        }

        // 版本变了 = 新 bundle 已就位。kickstart -k：有旧实例就 kill+restart，没有就 start。
        let uid = getuid()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(uid)/\(label)"]
        do {
            try p.run()
            p.waitUntilExit()
            FileHandle.standardError.write(Data("__relaunch-helper: kickstart \(label) status=\(p.terminationStatus) (\(oldVersion) → \(nv))\n".utf8))
            return p.terminationStatus == 0 ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("__relaunch-helper: kickstart 失败 \(error)\n".utf8))
            return 1
        }
    }

    /// 读**磁盘上安装目录** Info.plist 的 CFBundleVersion（被 Sparkle 替换的那个，不是本进程
    /// 载入时的版本）——直接 `Data(contentsOf:)` + `PropertyListSerialization`，不起 PlistBuddy
    /// 子进程（poll 每 0.5s 一次最多 240 次，逐次 spawn 没必要）。`Data(contentsOf:)` 不 cache，
    /// 每次都读最新磁盘内容，能看到 Sparkle 原子替换后的新 plist。
    private static func readBundleVersion(_ infoPlist: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: infoPlist)) else { return nil }
        return UpdateLogic.bundleVersion(fromInfoPlist: data)
    }
}

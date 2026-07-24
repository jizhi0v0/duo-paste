import DuoPasteCore
import Foundation

/// 保证 daemon 的长期运行权始终在 LaunchAgent 手里。
///
/// 每次启动问一句「我是 launchd 起的吗？不是的话，launchd 那边有没有一个指向同一个二进制的
/// job 在等着？」——是的话就 kickstart 它然后退出。判据和理由见
/// `DuoPasteCore.LaunchdAdoption`。
///
/// **不要退回到「Sparkle 写 marker → 下次启动读 marker」那套。** 那是事件驱动的：只覆盖
/// `updaterWillRelaunchApplication` 真的被调到的那条路径，marker 没写成、RelaunchHelper
/// 超时、或用户直接在 Finder 双击 DuoPaste.app，进程就永久跑在 launchd 之外——`KeepAlive`
/// 从此不生效，崩了没人拉起（2026-07-24 现场就是这样，用户手动开的）。marker 的读取已删，
/// 只保留清理，让升级过程中残留的旧文件自然消失。
enum SparkleLaunchdHandoff {
    private static var legacyMarkerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/duo-paste/sparkle-launchd-handoff")
    }

    /// 保留给 Sparkle 的 `updaterWillRelaunchApplication`：现在只是一条日志。真正的接管在
    /// 新进程启动时由 [adoptLaunchdIfNeeded] 无条件判定，不依赖这里有没有被调到。
    static func markForNextLaunch() {
        fputs("sparkle: will relaunch; next launch will hand off to launchd if needed\n", stderr)
    }

    static func adoptLaunchdIfNeeded() {
        try? FileManager.default.removeItem(at: legacyMarkerURL)

        let label = LaunchAgent.duoPastedLabel
        let decision = LaunchdAdoption.decide(
            xpcServiceName: ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
            label: label,
            jobIsLoaded: LaunchAgent.isRunning(label: label),
            executablePath: Bundle.main.executablePath,
            jobProgramPath: LaunchAgent.programPath(label: label)
        )
        guard decision == .handOffToLaunchd else { return }

        // 非 force：接管路径绝不能用 `kickstart -k`，理由见 LaunchAgent.kickstart
        let status = LaunchAgent.kickstart(label: label, force: false)
        guard status == 0 else {
            fputs("launchd handoff: kickstart \(label) failed status=\(status); staying up\n", stderr)
            return
        }
        // kickstart 返 0 只说明命令被接受。**确认 launchd 真的记上了一个不是我的 pid 才退出**
        // ——否则「我退了、job 也没起来」= daemon 彻底消失，比孤儿进程严重得多。
        guard let adopted = waitForServicePID(label: label, excluding: getpid()) else {
            fputs("launchd handoff: kickstart ok but no service pid appeared; staying up\n", stderr)
            return
        }
        fputs("launchd handoff: \(label) now running as pid=\(adopted); exiting orphan \(getpid())\n", stderr)
        exit(0)
    }

    /// launchd 记 pid 有一点延迟，poll 到 ~1s。返回 nil = 没等到，调用方必须继续跑。
    private static func waitForServicePID(label: String, excluding own: pid_t) -> pid_t? {
        for _ in 0..<10 {
            if let pid = LaunchAgent.servicePID(label: label), pid != own {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }
}

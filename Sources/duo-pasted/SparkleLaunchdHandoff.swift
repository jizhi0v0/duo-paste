import Foundation

/// Sparkle 的标准 "Install and Relaunch" 会通过 LaunchServices 重新打开 .app。
/// duo-paste 平时由 LaunchAgent 托管；这个小标记让 Sparkle 拉起的新进程只做一次
/// handoff：kickstart LaunchAgent 后退出，把长期运行权交回 launchd。
enum SparkleLaunchdHandoff {
    private static var markerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/duo-paste/sparkle-launchd-handoff")
    }

    static func markForNextLaunch() {
        do {
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "\(Date().timeIntervalSince1970)\n".write(to: markerURL, atomically: true, encoding: .utf8)
            fputs("sparkle handoff marker written: \(markerURL.path)\n", stderr)
        } catch {
            fputs("sparkle handoff marker failed: \(error)\n", stderr)
        }
    }

    static func consumeAndExitIfNeeded() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }

        let label = LaunchAgent.duoPastedLabel
        let currentPID = getpid()
        let servicePID = LaunchAgent.servicePID(label: label)

        if servicePID == currentPID {
            removeMarker()
            fputs("sparkle handoff: already running under LaunchAgent pid=\(currentPID)\n", stderr)
            return
        }

        guard LaunchAgent.isRunning(label: label) else {
            removeMarker()
            fputs("sparkle handoff: LaunchAgent not loaded; continuing in relaunched app\n", stderr)
            return
        }

        let status = LaunchAgent.kickstart(label: label)
        if status == 0 {
            removeMarker()
            fputs("sparkle handoff: kickstarted \(label); exiting transient relaunch pid=\(currentPID)\n", stderr)
            exit(0)
        }

        removeMarker()
        fputs("sparkle handoff: kickstart \(label) failed status=\(status); continuing in relaunched app\n", stderr)
    }

    private static func removeMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}

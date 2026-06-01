import Foundation
import AppKit
import os
import os.log
import Sparkle
import DuoPasteCore

private let logger = Logger(subsystem: "io.duopaste.daemon", category: "Updater")

/// duo-paste 是 LaunchAgent 托管的 accessory daemon，不是普通 Dock app。
/// Sparkle 的标准安装链路必须允许 relaunch（`updaterShouldRelaunchApplication == true`），
/// 否则 Sparkle 会在安装前直接 abort；安装后的 LaunchServices relaunch 只做一次
/// `SparkleLaunchdHandoff`，把长期运行权交回 launchd。
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    let controller: SPUStandardUpdaterController
    private let delegate = RelaunchDelegate()

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )
        logger.info("Sparkle updater started · canCheck=\(self.controller.updater.canCheckForUpdates, privacy: .public)")
    }

    /// 手动触发检查（Settings「检查更新」按钮）。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    /// 是否包含 beta channel。两台自用：一台跟 beta 一台跟 stable 做灰度。
    var includePrereleases: Bool {
        get { UserDefaults.standard.bool(forKey: "sparkleIncludePrereleases") }
        set {
            UserDefaults.standard.set(newValue, forKey: "sparkleIncludePrereleases")
            controller.updater.resetUpdateCycle()
        }
    }
}

// MARK: - Sparkle Delegate

final class RelaunchDelegate: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate, @unchecked Sendable {
    /// beta/stable channel 过滤。includePrereleases=true 看 beta，否则只看无 channel 的 stable。
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateLogic.allowedChannels(
            includePrereleases: UserDefaults.standard.bool(forKey: "sparkleIncludePrereleases")
        )
    }

    /// CDN 绕过：feed 在 raw.githubusercontent.com（Fastly CDN，源站 max-age=300）。
    /// CI publish 完到 edge 失效有 ~5min 窗口会拿到旧 appcast 误判「已最新」。拼时间戳
    /// query 强制不同 cache key。（与 claude-usage SparkleUpdater 同款。）
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else { return nil }
        return UpdateLogic.cacheBustedFeedURL(url, epochSeconds: Int(Date().timeIntervalSince1970))
    }

    /// 这里必须返回 true：Sparkle 在安装前用这个结果决定是否继续，false 会让
    /// "Install and Relaunch" 直接 abort，看起来像按钮没反应。
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        SparkleLaunchdHandoff.markForNextLaunch()
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        bringSparkleWindowsForward(reason: "update found")
    }

    func standardUserDriverDidShowModalAlert() {
        bringSparkleWindowsForward(reason: "modal alert")
    }

    func standardUserDriverAllowsMinimizableStatusWindow() -> Bool {
        false
    }

    private func bringSparkleWindowsForward(reason: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where Self.isSparkleWindow(window) {
                window.level = .floating
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
            logger.info("Sparkle UI brought forward: \(reason, privacy: .public)")
        }
    }

    private static func isSparkleWindow(_ window: NSWindow) -> Bool {
        let controllerName = window.windowController.map { String(describing: type(of: $0)) } ?? ""
        if controllerName.hasPrefix("SU") || controllerName.hasPrefix("SPU") {
            return true
        }
        let title = window.title.lowercased()
        return title.contains("software update")
            || title.contains("updating")
            || title.contains("update")
    }
}

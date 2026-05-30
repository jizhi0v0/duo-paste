import Foundation
import os.log
import Sparkle

private let logger = Logger(subsystem: "io.duopaste.daemon", category: "Updater")

/// duo-paste 是 `KeepAlive` launchd daemon（不是普通登录项 app），完整 Sparkle 在这个
/// 进程模型下走「方案 A：自控 relaunch」——已三层 spike 实测 + Sparkle 头文件 SPUUpdaterDelegate.h
/// 背书：`updaterShouldRelaunchApplication` 文档「This method can be used to explicitly
/// prevent a relaunch」；install-on-quit 文档「Sparkle will always attempt to install the
/// update when the app terminates」。即：返回 NO 只阻止 relaunch 这一步，**不**阻止 Sparkle
/// 替换 bundle + terminate 宿主。
///
/// 链路：
///   1) `updaterShouldRelaunchApplication` 返回 NO —— Sparkle 仍装更新（替换 bundle）+
///      terminate 宿主，但**不** open-relaunch（open relaunch 起的进程脱离 launchd 监管）。
///   2) 返回前 spawn 一个 detached（POSIX_SPAWN_SETSID）relaunch helper（= 本 binary 的
///      `__relaunch-helper` 隐藏子命令）。helper 脱离宿主进程组/session，宿主被 terminate
///      时不被连带杀（launchd bootout 杀整个进程组——Layer1-C 实测）。
///   3) helper poll 安装目录 Info.plist 的 CFBundleVersion，变了（= Sparkle Installer 已
///      把新 bundle 换到位）就 `launchctl kickstart -k` 让 launchd 拉起新版。时序无关、
///      自纠正：即便宿主非 clean-exit 被 launchd 抢先拉起旧版，helper 的 kickstart 仍会
///      强制换到新版。
///   4) plist 配 `KeepAlive={SuccessfulExit:false}`：宿主 clean exit 不被 launchd 抢重启
///      （让位给 Sparkle 安装），崩溃（非 0）才重启（自愈语义保留）。见 install-agent.sh。
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    let controller: SPUStandardUpdaterController
    private let delegate = RelaunchDelegate()

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
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

// MARK: - Sparkle Delegate（方案 A 核心）

final class RelaunchDelegate: NSObject, SPUUpdaterDelegate, @unchecked Sendable {
    /// 只 spawn 一次 helper：`updaterShouldRelaunchApplication` 可能被调多次（文档说装更新
    /// 流程里会多处 consult relaunch 决策）。helper 本身对「版本没变」幂等（poll 超时静默退出
    /// 不 kickstart），多 spawn 也安全，但仍去重省资源。
    private var helperSpawned = false

    /// beta/stable channel 过滤。includePrereleases=true 看 beta，否则只看无 channel 的 stable。
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: "sparkleIncludePrereleases") ? ["beta"] : []
    }

    /// CDN 绕过：feed 在 raw.githubusercontent.com（Fastly CDN，源站 max-age=300）。
    /// CI publish 完到 edge 失效有 ~5min 窗口会拿到旧 appcast 误判「已最新」。拼时间戳
    /// query 强制不同 cache key。（与 claude-usage SparkleUpdater 同款。）
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              var comps = URLComponents(string: url) else { return nil }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970))))
        comps.queryItems = items
        return comps.url?.absoluteString
    }

    /// 方案 A 的关键：返回 NO 阻止 Sparkle open-relaunch（脱离 launchd），spawn helper 接管。
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        if !helperSpawned {
            helperSpawned = true
            RelaunchHelper.spawnDetached()
            logger.info("updaterShouldRelaunchApplication → NO（已 spawn detached relaunch helper）")
        }
        return false
    }
}

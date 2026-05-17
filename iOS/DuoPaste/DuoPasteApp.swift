import SwiftUI
import UIKit
import OSLog
import QuartzCore
import DuoPasteCore

enum UILatencyLog {
    private static let logger = Logger(subsystem: "io.duopaste.ios", category: "ui-latency")

    static func mark(_ event: String, _ detail: String = "") {
        let t = String(format: "%.3f", CACurrentMediaTime())
        let main = Thread.isMainThread ? "1" : "0"
        let suffix = detail.isEmpty ? "" : " \(detail)"
        logger.notice("[ui-latency] \(event, privacy: .public)\(suffix, privacy: .public) t=\(t, privacy: .public) main=\(main, privacy: .public)")
    }

    static func elapsedMS(since start: CFTimeInterval) -> String {
        String(format: "%.1f", (CACurrentMediaTime() - start) * 1000)
    }
}

@main
struct DuoPasteApp: App {
    @State private var store: HistoryStore
    @State private var coordinator: PeerSyncCoordinator
    @State private var shareCoord = ShareCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("peerURL") private var peerURL: String = ""
    @AppStorage("sharedSecretHex") private var sharedSecretHex: String = ""

    init() {
        UILatencyLog.mark("app init begin")
        let store = HistoryStore()
        // restore() 必须在 PeerSyncCoordinator 起 reconfigure 之前——否则 /since pull 跟
        // 持久化文件 merge 时拿不到旧 cursor 之前的内容,首次 launch 重 pull 大量
        store.restore()
        _store = State(initialValue: store)
        _coordinator = State(initialValue: PeerSyncCoordinator(store: store))
        UILatencyLog.mark("app state ready")
        // BGTaskScheduler.register 必须在 init,不能延迟到 scenePhase
        BackgroundPullService.register()
        Self.prewarmSystemServices()
        Self.cleanupShareTempFiles()
        UILatencyLog.mark("app init end")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(coordinator)
                .environment(coordinator.blobCache)
                .environment(coordinator.appIconCache)
                .environment(shareCoord)
                .task {
                    if let cfg = try? PeerConfig.parse(
                        urlString: peerURL, secretHex: sharedSecretHex
                    ) {
                        coordinator.reconfigure(cfg)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        // app 进后台:持久化 + 申请下次 background refresh
                        store.persist()
                        BackgroundPullService.scheduleNext()
                    case .active:
                        // 回前台:磁盘可能被 BG task 更新,merge 一次让 UI 显示最新
                        if let data = try? Data(contentsOf: HistoryStore.itemsFile),
                           let restored = try? JSONDecoder().decode([Item].self, from: data) {
                            store.merge(restored)
                        }
                    default:
                        break
                    }
                }
        }
    }

    /// 启动时 prepare 触觉发生器 — 让首次"已复制"haptic 准点响。
    ///
    /// UIActivityViewController cold start (LSD share extension 枚举 + SharingService XPC)
    /// 是 iOS 系统级 lazy cost,无法从 app 进程暖到 — alloc-only 没用(LSD 是 present 时才跑),
    /// 隐藏 window present-then-dismiss 反而让真正 present 排队 / 污染 XPC 连接。
    /// 这是 Apple 系统的一次性成本,Notes/Messages 同样有(只是它们被 LSD 内部 prewarm 优待)。
    ///
    /// 注意 Xcode debug install 上 LSD cold start 可达 8s+(实测 8521ms),原因是 dev install
    /// 让 LSD 缓存指向 stale container path → `Failed to locate container app bundle record`
    /// + Code=-54 `canmaplsdatabase` → 全表 rescan。同会话第二次分享掉到 ~900ms。
    /// production / TestFlight install 路径不复现这个 8s 数字,看到不要被劝动去乱改 prewarm。
    private static func prewarmSystemServices() {
        let start = CACurrentMediaTime()
        UILatencyLog.mark("prewarm begin")
        UIImpactFeedbackGenerator(style: .light).prepare()
        UISelectionFeedbackGenerator().prepare()
        UINotificationFeedbackGenerator().prepare()
        UILatencyLog.mark("prewarm haptics prepared", "elapsed_ms=\(UILatencyLog.elapsedMS(since: start))")
    }

    /// 启动时清空 `tmp/share-images/` —— share 走 file URL 透传原始字节,
    /// 一次复杂 share 流可能给 UIActivityViewController 喂十几张 tmp 文件,
    /// iOS 系统回收周期不稳定,自己 nuke 干净。
    ///
    /// app 刚启动一定没有 in-flight share,整目录 remove 是安全的。
    /// 跑在 utility queue 不阻塞 init,失败静默(下次启动再清,无关键性)。
    private static func cleanupShareTempFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-images", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            let start = CACurrentMediaTime()
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                UILatencyLog.mark("share tmp cleanup skipped (no dir)")
                return
            }
            var removed = 0
            for url in items {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
            UILatencyLog.mark(
                "share tmp cleanup done",
                "removed=\(removed) elapsed_ms=\(UILatencyLog.elapsedMS(since: start))"
            )
        }
    }
}

import Foundation
import BackgroundTasks
import DuoPasteCore

/// iOS BGAppRefreshTask 后台 pull——app 后台挂起期间,系统**可能**每 N 分钟唤醒一次让我们
/// 跑 ~30s 工作。当前用法:读 AppStorage 里的 peer config + SQLite cursor → 拉 /since
/// 几页 → 通过与前台完全相同的 `MetadataMirrorStore.applyPage` 原子写 rows + cursor。
///
/// 这条路径**纯后台**——没 UI,没 NSPasteboard,没 BlobCache。新 image 行不拉 blob 字节
/// (没空,30s 跑完整 blob fetch 不现实);用户回前台 tap 那条 image 时再 lazy fetch。
///
/// 重要限制:
/// - BGAppRefreshTask 调度由系统决定,实测可能 15min ~ 几小时一次,锁屏后通常不跑
/// - 当前 task identifier 必须在 Info.plist BGTaskSchedulerPermittedIdentifiers 里
/// - 单次 task 最长 ~30s;超时系统会调 expirationHandler 让我们清理
/// - WS 后台不能跑(iOS 不允许长连接背景);这里只走 HTTP /since
///
/// 失败路径:
/// - peer config 没配 → 直接 setTaskCompleted(success: false)
/// - 网络抖 / 401 → 同上,等下次唤醒重试
@MainActor
enum BackgroundPullService {
    nonisolated static let taskIdentifier = "io.duopaste.ios.background-pull"
    /// 后台 task 单次拉的最大页数 — 30s 限制下 5-10 页够追平日常 backlog
    nonisolated private static let maxPages = 10
    /// 每页 limit
    nonisolated private static let pageLimit = 200
    /// 下一次唤醒至少间隔(系统会进一步推迟)
    nonisolated private static let nextRequestEarliestSec: TimeInterval = 15 * 60

    /// app init 调一次:注册 handler。BGTaskScheduler.register 必须在 didFinishLaunching
    /// 之前(SwiftUI app 在 init() 里调)。重复 register 系统会 fatalError——只调一次
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil   // 默认 DispatchQueue(系统选)
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: refresh)
        }
    }

    /// app 进后台时调:申请下一次 background refresh。系统决定何时真跑
    nonisolated static func scheduleNext() {
        let req = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: nextRequestEarliestSec)
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            DebugLog.shared.append("BG schedule failed: \(error)")
        }
    }

    private static func handle(task: BGAppRefreshTask) {
        // 安排下次调度——不管这次成功失败都得排,iOS 不会自动续
        scheduleNext()
        let work = Task { @MainActor in
            do {
                try await runPull()
                task.setTaskCompleted(success: true)
            } catch {
                DebugLog.shared.append("BG pull failed: \(error)")
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            // 系统快到 30s 上限了 — cancel 让 task 收尾
            work.cancel()
        }
    }

    private static func runPull() async throws {
        let defs = UserDefaults.standard
        guard let credential = try ClientCredentialKeychain.load() else {
            throw BackgroundPullError.notConfigured
        }
        let configuredURL = defs.string(forKey: "peerURL") ?? ""
        let endpointURL: String
        if !configuredURL.isEmpty {
            endpointURL = configuredURL
        } else if let json = defs.string(forKey: "peerEndpointsJSON"),
                  let data = json.data(using: .utf8),
                  let endpoints = try? JSONDecoder().decode([PeerEndpoint].self, from: data),
                  let first = endpoints.first {
            endpointURL = first.url
        } else {
            throw BackgroundPullError.notConfigured
        }
        guard let url = URL(string: endpointURL) else { throw BackgroundPullError.notConfigured }
        let cfg = PeerConfig(
            baseURL: url,
            sharedSecret: credential.requestSecret,
            credentialToken: credential.token
        )
        let client = PeerClient(config: cfg)

        let mirror = try HistoryStore.openMirror()
        _ = try await mirror.synchronize(
            pageLimit: pageLimit,
            maxPages: maxPages
        ) { cursor, limit in
            try await client.fetchSince(cursor: cursor, limit: limit)
        }
    }
}

enum BackgroundPullError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "peer 未配置,跳过后台 pull"
        }
    }
}

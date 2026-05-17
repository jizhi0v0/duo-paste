import Foundation
import Network

/// 监听 iOS 网络状态变化(Wi-Fi 切 cellular / 切网段 / 飞行模式 切换),给 PeerSyncCoordinator
/// 触发 endpoint re-probe + 重选。
///
/// 单例 (DuoPasteApp 启动注入),NWPathMonitor 一个 instance,onChange 回调走 main actor
@MainActor
final class NetworkChangeWatcher {
    static let shared = NetworkChangeWatcher()

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "io.duopaste.network-monitor")
    private(set) var currentPath: NWPath?
    private var listeners: [(NWPath) -> Void] = []
    private var started = false

    private init() {
        self.monitor = NWPathMonitor()
    }

    /// app 启动调一次。重复 start noop
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            // pathUpdateHandler 在 monitor queue 上,hop 回 main actor 通知 listeners
            Task { @MainActor [weak self] in
                self?.applyPath(path)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        started = false
    }

    /// 注册"网络变化"回调。每次 NWPath 变化(status / 接口类型 / pricier 等)调一次。
    /// 同一注册者复合多次注册不去重——调用方自己保证幂等
    func addListener(_ listener: @escaping (NWPath) -> Void) {
        listeners.append(listener)
    }

    private func applyPath(_ path: NWPath) {
        currentPath = path
        for listener in listeners {
            listener(path)
        }
    }
}

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
    /// token-keyed listeners 让调用方能精确 remove；旧 array 模式 SwiftUI 实例重建时
    /// 旧 listener 永远留在数组，长会话下 O(N) listener fan-out 浪费 + 闭包持有 weak self
    /// 在 nil-self 路径上反复跑空操作
    private var listeners: [UUID: (NWPath) -> Void] = [:]
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
    /// 返回 token，调用方在自己 stop / dealloc 时调 `removeListener(token)` 解绑——
    /// 不解绑会让数组单调增（SwiftUI @State 创建 owner 实例可能反复，每次 init 都注册）
    @discardableResult
    func addListener(_ listener: @escaping (NWPath) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = listener
        return token
    }

    /// 解绑某个先前注册的 listener；token 不存在时 no-op
    func removeListener(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }

    private func applyPath(_ path: NWPath) {
        currentPath = path
        for listener in listeners.values {
            listener(path)
        }
    }
}

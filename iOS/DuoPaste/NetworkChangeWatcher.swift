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
    /// 上次通知 listener 时 path 的指纹；用来在诊断日志里 diff 出"到底哪个字段变了"
    private var lastFingerprint: String?

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
        let fp = Self.fingerprint(path)
        let prev = lastFingerprint
        lastFingerprint = fp
        currentPath = path

        // NWPathMonitor 在 iOS 上对 Tailscale/Surge NetworkExtension 这种多扩展环境会反复
        // fire——切前台/后台、扩展内部 tick、metric 调整都触发,但实际 status/interfaces/flags
        // 没变。这种 noise callback 不应传播,否则下游 `handleNetworkChange` 会无意义触发
        // restartAll(砸掉刚握手成功的 WS)+ repickEndpoint(起 6 路并发 probe),造成日志里
        // "刚 ready 又被 cancel" 的反复抖动
        //
        // 同样 initial callback (`.start()` 后 framework 上报当前 path) 也不是变化事件——
        // 配对/重连等业务路径已经主动 kick 了 probe + WS pool,initial 通知没价值反而把刚
        // 起的 socket 砸一遍。`PeerSyncCoordinator` 仍可读 `currentPath` 决策 Ponte 偏好
        if let prev {
            if prev == fp {
                DebugLog.shared.append("nwpath callback (no diff, skipped): \(fp)")
                return
            }
            DebugLog.shared.append("nwpath changed: \(prev) → \(fp)")
        } else {
            DebugLog.shared.append("nwpath initial (skipped): \(fp)")
            return
        }

        for listener in listeners.values {
            listener(path)
        }
    }

    /// 把 NWPath 压成可比较的一行字符串。覆盖真正影响连通性的字段:
    /// - status (.satisfied / .unsatisfied / .requiresConnection)
    /// - **primary** 接口类型(availableInterfaces.first,反映 iOS 选的 default route)
    /// - 可用接口类型集合(wifi/cellular/wired/loopback/other,排序后)
    /// - isExpensive / isConstrained / supportsIPv4 / supportsIPv6 / supportsDNS
    /// **不**包括 interface name(同 type 不同 name 像 utun0/utun1 是 NetworkExtension 内部
    /// 重启常态,不该当作"网络变化")或 gateway/endpoint(只在已建立 NWConnection 上有意义)
    ///
    /// **primary vs Set**:iPhone 长期 wifi+cell 并存(cell 是 backup),wifi 退化时 iOS 把
    /// default route 从 wifi 切到 cell——`availableInterfaces` 是 `[wifi,cell]` → `[cell,wifi]`,
    /// **Set 不变**但 first 变了。光 Set 会漏掉这种 silent route swap,导致 preferPonteForCurrentPath
    /// 永远在 wifi 路径上跑(但实际走的是 cellular)直到 5min 周期 repick 兜底
    private static func fingerprint(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        let ifaceTypes = path.availableInterfaces.map { ifaceTypeString($0.type) }
        let primary = ifaceTypes.first ?? "none"
        let typesSig = Set(ifaceTypes).sorted().joined(separator: ",")
        var flags: [String] = []
        if path.isExpensive { flags.append("expensive") }
        if path.isConstrained { flags.append("constrained") }
        if !path.supportsIPv4 { flags.append("noV4") }
        if !path.supportsIPv6 { flags.append("noV6") }
        if !path.supportsDNS { flags.append("noDNS") }
        let flagsSig = flags.isEmpty ? "-" : flags.joined(separator: ",")
        return "[\(status) primary=\(primary) ifaces=\(typesSig) flags=\(flagsSig)]"
    }

    private static func ifaceTypeString(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cell"
        case .wiredEthernet: return "wired"
        case .loopback: return "loop"
        case .other: return "other"
        @unknown default: return "?"
        }
    }
}

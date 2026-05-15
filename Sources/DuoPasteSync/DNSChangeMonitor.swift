import Foundation
import SystemConfiguration

/// 监听系统 DNS 配置变化（resolver 列表、search domains 等)。Tailscale 启停、
/// MagicDNS toggle、WiFi 切换都会让 `State:/Network/Global/DNS` 改变。
///
/// 回调用途:让 WS client 立即丢弃当前 backoff sleep 重连——
/// SwiftNIO 进程内的 resolver state 在 client 创建时 snapshot,DNS 配置改了
/// 也不自动刷新;daemon 重连时正好走系统当前 resolver,因此 trigger reconnect
/// 等价"用新 DNS 重试一次"。详见 CLAUDE.md DNS / mesh 章节。
///
/// `SCDynamicStore` 是 macOS 系统 SystemConfiguration framework 的私有
/// notification 通道,不需要权限。GCD queue 串行执行回调,onChange 闭包必须
/// `@Sendable`(跨 actor 调度)。
public final class DNSChangeMonitor: @unchecked Sendable {
    private var store: SCDynamicStore?
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let log: @Sendable (String) -> Void

    public init(
        onChange: @escaping @Sendable () -> Void,
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("dns-monitor: \(msg)\n".utf8))
        }
    ) {
        self.onChange = onChange
        self.queue = DispatchQueue(label: "io.duopaste.dns-monitor", qos: .utility)
        self.log = log
    }

    /// 启动监听。幂等(已 start → no-op)
    public func start() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // C callback 桥到 Swift instance method
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<DNSChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.handleChange()
        }
        guard let s = SCDynamicStoreCreate(
            nil,
            "io.duopaste.dns-monitor" as CFString,
            callback,
            &context
        ) else {
            log("SCDynamicStoreCreate failed; DNS auto-recovery disabled")
            return
        }
        // 监听 global DNS state(resolver 列表 / search domain) + 接口 IPv4/IPv6
        // 配置变化(WiFi 切 ethernet、Tailscale tun 起伏会同时刷这俩 key)
        let keys: [CFString] = [
            "State:/Network/Global/DNS" as CFString,
            "State:/Network/Global/IPv4" as CFString,
            "State:/Network/Global/IPv6" as CFString,
        ]
        let patterns: [CFString] = []
        SCDynamicStoreSetNotificationKeys(s, keys as CFArray, patterns as CFArray)
        SCDynamicStoreSetDispatchQueue(s, queue)
        self.store = s
        log("started · watching DNS + IPv4/IPv6 global state")
    }

    public func stop() {
        guard let s = store else { return }
        SCDynamicStoreSetDispatchQueue(s, nil)
        self.store = nil
        log("stopped")
    }

    private func handleChange() {
        log("system DNS/network state changed → waking WS clients")
        onChange()
    }

    deinit {
        // best-effort:实际生命周期由 supervisor 显式 stop 管理
        if let s = store {
            SCDynamicStoreSetDispatchQueue(s, nil)
            _ = s  // 释放 CF 引用走 ARC bridge
        }
    }
}

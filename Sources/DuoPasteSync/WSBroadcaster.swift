import Foundation
import HummingbirdWebSocket
import DuoPasteCore

/// Server 侧活动 WS 连接注册中心。每个上游 client 一个 ConnectionID + outbound writer。
///
/// `CaptureService.onCursorAdvanced` 触发后调 `broadcastCursorAdvanced(...)` 把
/// `cursor_advanced` 帧 fan-out 给所有连接。
///
/// **慢消费者保护**：每条消息给单个连接 `perBroadcastTimeoutSec`（默认 2s）超时——
/// 超时即从 set 移除并触发 `onSlowKick` 让 connection handler 自然断开（autoPing 也会
/// 兜底，但显式踢更快）。这条不变量是为了让 `broadcast` 不被某个死连接卡住——capture
/// 路径在 main actor 上 `Task { ... await broadcaster.broadcast(...) }`，broadcaster
/// 阻塞会让 capture pipeline 整体卡住。
///
/// **actor 而非 NSLock**：`broadcast` 内部要 await（write + sleep），actor 让 register/
/// unregister/broadcast 串行天然防 dict mutate-while-iterate。`connections` 字段非 Sendable
/// dict 也不会逃出 actor。
///
/// **定期 rotation（auth 安全 hardening）**：`start()` 起周期任务，每 `rotationIntervalSec`
/// 秒主动 close 所有 connections。合法 client 走 backoff 重连 + 重 HMAC upgrade（用最新
/// secret），attacker 偷了旧 secret 维持的"永生连接"被压缩到最长一个 rotation 窗口。
/// **不调 start()** → broadcaster 仍然 work（fan-out 正常），只是不 rotation——测试可以
/// 不起 lifecycle 直接用
public actor WSBroadcaster {
    public struct ConnectionID: Hashable, Sendable, CustomStringConvertible {
        public let raw: UUID
        public init(_ raw: UUID = UUID()) { self.raw = raw }
        public var description: String { String(raw.uuidString.prefix(8)) }
    }

    private struct Connection {
        let writer: WebSocketOutboundWriter
        let onSlowKick: @Sendable () -> Void
        let peerHint: String?
    }

    private var connections: [ConnectionID: Connection] = [:]
    public let perBroadcastTimeoutNs: UInt64
    /// rotation 周期（秒）。0 = 不 rotation（测试 / 开发场景）。生产默 4h
    public let rotationIntervalSec: TimeInterval
    private let log: @Sendable (String) -> Void
    private var rotationTask: Task<Void, Never>?

    public init(
        perBroadcastTimeoutSec: TimeInterval = 2,
        rotationIntervalSec: TimeInterval = 4 * 3600,
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("ws-broadcast: \(msg)\n".utf8))
        }
    ) {
        self.perBroadcastTimeoutNs = UInt64(perBroadcastTimeoutSec * 1_000_000_000)
        self.rotationIntervalSec = rotationIntervalSec
        self.log = log
    }

    /// 起 rotation 任务。重入幂等。`rotationIntervalSec=0` → 不起。
    /// 应当在 daemon 启动时（AppDelegate.applicationDidFinishLaunching）调一次
    public func start() {
        guard rotationIntervalSec > 0, rotationTask == nil else { return }
        let interval = rotationIntervalSec
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return  // cancelled
                }
                await self?.rotateAllConnections()
            }
        }
        // 用 String(format:) 让 0.5s 这种亚秒值也能显示，不被 Int 截 0
        log("rotation task started · interval=\(String(format: "%.1f", interval))s")
    }

    /// 停 rotation 任务。daemon shutdown 路径调；测试 teardown 也调避免泄漏 Task
    public func stop() {
        rotationTask?.cancel()
        rotationTask = nil
    }

    /// 主动 close 所有当前 connections。Connection handler 的 inbound for-await 收到
    /// close 帧自然退出 → defer unregister 清掉 broadcaster 这边的状态 → client 端
    /// runLoop catch error → 走 backoff 重连 → 重新做 HMAC upgrade（带最新 secret）
    ///
    /// **`onSlowKick` 也调一次**——同 broadcast 慢消费者踢的语义保持一致：让 server 端
    /// onUpgrade 闭包尽快收尾不卡 inbound iterator
    func rotateAllConnections() async {
        guard !connections.isEmpty else { return }
        let snapshot = connections
        log("rotating \(snapshot.count) connection(s) for auth refresh")
        for (id, conn) in snapshot {
            // close 写帧——失败也无所谓（连接已经死了 client 端走重连），主要是发 close 信号
            // 让 client 端 inbound 收到 close 立刻退出 for-await 而不是等下次 ping/pong 超时
            try? await conn.writer.close(.policyViolation, reason: "auth rotation")
            conn.onSlowKick()
            // 主动从 set 移除——connection handler 的 defer unregister 也会跑，幂等
            connections.removeValue(forKey: id)
        }
    }

    /// 注册新连接。`onSlowKick` 在该连接被判定慢消费者踢掉时调用——通常实现为
    /// "cancel 当前 inbound for-loop 让 handler 退出"，hbws 的 outbound write 抛错也能达到同样效果。
    public func register(
        writer: WebSocketOutboundWriter,
        peerHint: String? = nil,
        onSlowKick: @escaping @Sendable () -> Void = {}
    ) -> ConnectionID {
        let id = ConnectionID()
        connections[id] = Connection(writer: writer, onSlowKick: onSlowKick, peerHint: peerHint)
        log("registered \(id) peer=\(peerHint ?? "?") · total=\(connections.count)")
        return id
    }

    /// 连接关闭时调用，幂等。`broadcast` 路径自己踢慢消费者时也走这里。
    public func unregister(_ id: ConnectionID) {
        if let c = connections.removeValue(forKey: id) {
            log("unregistered \(id) peer=\(c.peerHint ?? "?") · total=\(connections.count)")
        }
    }

    public var connectionCount: Int { connections.count }

    /// 广播 `cursor_advanced` 给所有当前连接。`latestIngestedAtNs` 是 self 设备本机最大
    /// `ingested_at_ns`——peer 收到后跟自己 cursor 比，决定是否立即 wake 拉一页。
    public func broadcastCursorAdvanced(deviceID: String, latestIngestedAtNs: Int64) async {
        let msg = WSMessage.cursorAdvanced(
            version: WSMessage.currentVersion,
            deviceID: deviceID,
            latestIngestedAtNs: latestIngestedAtNs
        )
        await broadcast(msg)
    }

    /// 通用广播。每个连接独立超时 + 独立踢——一条死连接不影响其他正常连接收到这条消息。
    public func broadcast(_ message: WSMessage) async {
        guard !connections.isEmpty else { return }
        let payload: String
        do {
            payload = try message.encodeJSON()
        } catch {
            log("encode failed: \(error)")
            return
        }
        // local copy 防 register/unregister 改动 dict 干扰本次广播视图
        let snapshot = connections
        var slowKicks: [ConnectionID] = []
        await withTaskGroup(of: (ConnectionID, Bool).self) { group in
            for (id, conn) in snapshot {
                let writer = conn.writer
                let timeout = perBroadcastTimeoutNs
                group.addTask {
                    let r = await Self.writeWithTimeout(writer: writer, text: payload, timeoutNs: timeout)
                    return (id, r)
                }
            }
            for await (id, ok) in group {
                if !ok { slowKicks.append(id) }
            }
        }
        for id in slowKicks {
            if let c = connections.removeValue(forKey: id) {
                log("kicked slow consumer \(id) peer=\(c.peerHint ?? "?")")
                c.onSlowKick()
            }
        }
    }

    /// 单 connection 写一帧 + 超时 race。返回 true=完成；false=write 抛错或超时——上层踢。
    /// 用 TaskGroup race 而非 `withTimeout` helper：write 抛错时立即返回，超时让 sleep 赢。
    private static func writeWithTimeout(
        writer: WebSocketOutboundWriter,
        text: String,
        timeoutNs: UInt64
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await writer.write(.text(text))
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

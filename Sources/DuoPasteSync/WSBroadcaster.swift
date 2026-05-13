import Foundation
import HummingbirdWebSocket

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
    private let log: @Sendable (String) -> Void

    public init(
        perBroadcastTimeoutSec: TimeInterval = 2,
        log: @escaping @Sendable (String) -> Void = { msg in
            FileHandle.standardError.write(Data("ws-broadcast: \(msg)\n".utf8))
        }
    ) {
        self.perBroadcastTimeoutNs = UInt64(perBroadcastTimeoutSec * 1_000_000_000)
        self.log = log
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

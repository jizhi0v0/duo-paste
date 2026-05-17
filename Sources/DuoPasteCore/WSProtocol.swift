import Foundation

/// `/sync/ws` 上传输的应用层消息。Wire 形态 = 一帧 WebSocket text + JSON。
///
/// 设计要点：
/// - **不**走 binary frame：JSON 在 stderr / 抓包 / Tailscale 监控里是人类可读的，
///   WebSocket 应用层消息在我们这种"低频通知 + 长连接 keep-alive"场景下走二进制省不下
///   多少（每帧本来就 KB 级以下）。
/// - WebSocket 协议层的 ping/pong 由 hummingbird-websocket `autoPing` 自动处理（不在这一层
///   编码）。`WSMessage.ping/.pong` 案例**预留**给"应用层心跳"未来扩展（如携带业务诊断
///   字段），目前 client/server 不主动发也不消费——decode 时遇到要兼容（向前兼容性占位）。
/// - `version` 字段每条消息都带，未来 schema 改动时让对端可识别。`init(from:)` 缺省 1，
///   兼容老 client / 测试 fixture。
///
/// JSON 形态例子：
/// ```json
/// {"type":"cursor_advanced","version":1,"device_id":"X","latest_ingested_at_ns":17000000000}
/// {"type":"hello","version":1,"device_id":"X","now_ms":17000,"latest_ingested_at_ns":17000000000}
/// ```
public enum WSMessage: Codable, Equatable, Sendable {
    /// 「我有新内容了」通知。Server 在 `CaptureService.onCursorAdvanced` 闭包触发后广播给
    /// 所有订阅 client；client 收到 → 调对应 `PullWorker.wake()` 立即追赶（不等 30s tick）。
    /// `latestIngestedAtNs` 是 server 当前最大 `ingested_at_ns`，client 拿来做"我已经追平了吗"
    /// 自检（比本地 cursor 大 → 仍需要拉一页）。
    case cursorAdvanced(version: Int, deviceID: String, latestIngestedAtNs: Int64)

    /// 连接握手后 server 主动下发的第一条消息。携带 baseline `latestIngestedAtNs` 让 client
    /// 重连后立刻自检要不要 pull——不靠 hello 就只能等下一次 server 端 capture 才触发 advance，
    /// 重连期间 missed advance 永远漏。
    /// `nowMs` 给 client 做时钟偏移 sanity check（同 `/health`）。
    case hello(version: Int, deviceID: String, nowMs: Int64, latestIngestedAtNs: Int64)

    /// 应用层 ping/pong 占位。当前不使用——WebSocket 协议层 autoPing 已处理 keep-alive。
    /// decode 时遇到不报错（向前兼容性占位）。
    case ping(version: Int)
    case pong(version: Int)

    public static let currentVersion: Int = 1

    private enum CodingKeys: String, CodingKey {
        case type
        case version
        case deviceID = "device_id"
        case nowMs = "now_ms"
        case latestIngestedAtNs = "latest_ingested_at_ns"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        switch type {
        case "cursor_advanced":
            let deviceID = try c.decode(String.self, forKey: .deviceID)
            let latest = try c.decode(Int64.self, forKey: .latestIngestedAtNs)
            self = .cursorAdvanced(version: version, deviceID: deviceID, latestIngestedAtNs: latest)
        case "hello":
            let deviceID = try c.decode(String.self, forKey: .deviceID)
            let nowMs = try c.decode(Int64.self, forKey: .nowMs)
            let latest = try c.decode(Int64.self, forKey: .latestIngestedAtNs)
            self = .hello(version: version, deviceID: deviceID, nowMs: nowMs, latestIngestedAtNs: latest)
        case "ping":
            self = .ping(version: version)
        case "pong":
            self = .pong(version: version)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "未知 WSMessage type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cursorAdvanced(let version, let deviceID, let latest):
            try c.encode("cursor_advanced", forKey: .type)
            try c.encode(version, forKey: .version)
            try c.encode(deviceID, forKey: .deviceID)
            try c.encode(latest, forKey: .latestIngestedAtNs)
        case .hello(let version, let deviceID, let nowMs, let latest):
            try c.encode("hello", forKey: .type)
            try c.encode(version, forKey: .version)
            try c.encode(deviceID, forKey: .deviceID)
            try c.encode(nowMs, forKey: .nowMs)
            try c.encode(latest, forKey: .latestIngestedAtNs)
        case .ping(let version):
            try c.encode("ping", forKey: .type)
            try c.encode(version, forKey: .version)
        case .pong(let version):
            try c.encode("pong", forKey: .type)
            try c.encode(version, forKey: .version)
        }
    }

    /// 编码成单行 JSON 字符串。WebSocket text frame 的 payload 形态。
    public func encodeJSON() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(self)
        guard let s = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "WSMessage 编码出非 UTF-8 数据"))
        }
        return s
    }

    public static func decodeJSON(_ s: String) throws -> WSMessage {
        guard let data = s.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "WSMessage 输入非 UTF-8"))
        }
        return try JSONDecoder().decode(WSMessage.self, from: data)
    }
}

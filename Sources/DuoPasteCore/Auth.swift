import Foundation
import CryptoKit

/// HMAC-SHA256 请求签名。Tailscale ACL 已经把可达性收口，这一层是纵深防御 +
/// 防止 tailnet 上其他设备误打到本服务。
///
/// 签名输入（canonical string，换行分隔）：
///
///     <timestamp_ms>\n<METHOD>\n<path>\n<body_sha256_hex>
///
/// - `timestamp_ms`：客户端 wall clock，毫秒。服务端校验在 ±`clockSkew` 秒内，
///   反 replay（攻击者就算抓到包，过期就用不了；同窗口内不防）。
/// - `path`：包含 query string。例如 `/since?cursor=12345`。
/// - `body_sha256_hex`：64 字符小写 hex。GET 等无 body 请求用空串的 sha256
///   （`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`）。
///   客户端**单独**把这个 hex 放在 `X-DP-Body-SHA256` header 里发出来——
///   服务端中间件只校验 header 上的值（不读 body），handler 自己读 body 时再核对一次。
///   这样中间件不必缓存 body，多 MB blob 请求也省内存。
public struct HMACAuth: Sendable {
    public static let timestampHeader = "X-DP-Timestamp"
    public static let bodyHashHeader  = "X-DP-Body-SHA256"
    public static let signatureHeader = "X-DP-Auth"
    /// 独立客户端 credential 的 mesh-root 密封 token。Header 一旦出现，服务端必须
    /// 只走 device credential 校验，失败时不能回退 shared-secret（防 downgrade）。
    public static let credentialTokenHeader = "X-DP-Credential"

    /// 空 body 的 sha256 hex，固定值，常用——客户端 GET 请求填这个。
    public static let emptyBodyHashHex =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public let secret: SymmetricKey
    public let clockSkew: TimeInterval

    public init(secret: Data, clockSkew: TimeInterval = 300) {
        self.secret = SymmetricKey(data: secret)
        self.clockSkew = clockSkew
    }

    /// 计算签名 hex。
    ///
    /// `path` **必须**是 HTTP wire 上的 raw percent-encoded 形式（包含 `?query`），
    /// 任何一侧做百分号解码都会让 client/server 签名串撕裂——见 `canonicalPath`
    /// helper 注释。client/server 都应该用 `HMACAuth.canonicalPath` 拼接，避免不同
    /// 调用点用不同 encoding 习惯
    public func sign(timestampMs: Int64, method: String, path: String, bodyHashHex: String) -> String {
        let canonical = "\(timestampMs)\n\(method.uppercased())\n\(path)\n\(bodyHashHex.lowercased())"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: secret)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 把签名用的 path + query 拼成 canonical 字符串。**唯一**真实来源，client / server
    /// middleware 必须用同一份拼接。
    ///
    /// 契约：
    /// - `path` 是 raw HTTP request-target 的 path 部分（如 `/since`、`/blob/<sha>`），
    ///   **不**百分号解码
    /// - `query` 是 raw query 部分（不含前导 `?`），如 `cursor_ns=12&cursor_id=01H...`；
    ///   nil 或 empty 表示无 query，不拼 `?`
    /// - 客户端用 `URLComponents.percentEncodedQuery` 取 query；服务端用 Hummingbird
    ///   `request.uri.query`（Hummingbird URI 不 percent-decode `path/query` 字段）。
    ///   两侧字节都应该跟 HTTP wire 上字面一致
    ///
    /// 如果未来引入 non-ASCII / `+` / `%20` 等用户可控字符的 cursor，调用方仍应通过这个
    /// helper 走——单点真相让 encoding 漂移没有立足处
    public static func canonicalPath(_ path: String, query: String? = nil) -> String {
        if let q = query, !q.isEmpty {
            return "\(path)?\(q)"
        }
        return path
    }

    /// 服务端校验：常量时间比较 + 时间窗口。
    /// 注意 `nowMs` 显式注入便于测试；运行时传 `Clock.nowMs()`。
    ///
    /// **本函数必须是 total function（任何输入都只返回 true/false，绝不 trap）**：
    /// `timestampMs` 直接来自请求 header `X-DP-Timestamp`，中间件用裸 `Int64(tsStr)` 解析
    /// 不做范围限制，而这道窗口检查跑在签名验证**之前**——攻击者不需要任何凭据就能控制它。
    /// 历史实现写的是 `abs(nowMs - timestampMs)`，两处都是陷阱算术：
    ///   - `X-DP-Timestamp: -9223372036854775808` → 减法溢出 → SIGTRAP
    ///   - delta 恰好等于 `Int64.min` → `abs` 溢出 → SIGTRAP
    /// 任一都让 daemon 当场死掉，且 launchd `KeepAlive` 拉起后下一个请求再杀一次
    /// （`ThrottleInterval=30` 只放慢重启，挡不住）。`serve_host=0.0.0.0` 时 tailnet /
    /// LAN 上任何设备都能打。
    ///
    /// 现在用溢出报告版减法 + `magnitude`（对 `Int64.min` 也有定义）：溢出意味着时间戳
    /// 离 now 有 Int64 量级的距离，必然超出任何合法窗口，一律 reject。`skewMs` 也走
    /// `Int64(exactly:)`，让 NaN / 越界的 `clockSkew` 退化成"全拒"而不是 trap。
    public func verify(
        timestampMs: Int64,
        method: String,
        path: String,
        bodyHashHex: String,
        signatureHex: String,
        nowMs: Int64
    ) -> Bool {
        let skewMs = Int64(exactly: (clockSkew * 1000).rounded(.towardZero)) ?? -1
        guard skewMs >= 0 else { return false }
        let (deltaMs, overflow) = nowMs.subtractingReportingOverflow(timestampMs)
        guard !overflow, deltaMs.magnitude <= UInt64(skewMs) else { return false }
        let expected = sign(
            timestampMs: timestampMs,
            method: method,
            path: path,
            bodyHashHex: bodyHashHex
        )
        return Self.constantTimeEquals(expected, signatureHex.lowercased())
    }

    /// 常量时间比较：避免按字节短路泄露签名前缀。
    /// 不是字符级 100% 严格（不同长度直接 false），但够防时序攻击。
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
        return diff == 0
    }

    /// 工具：算任意 Data 的 sha256 hex。
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

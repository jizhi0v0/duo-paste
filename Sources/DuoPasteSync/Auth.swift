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
    public func sign(timestampMs: Int64, method: String, path: String, bodyHashHex: String) -> String {
        let canonical = "\(timestampMs)\n\(method.uppercased())\n\(path)\n\(bodyHashHex.lowercased())"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: secret)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 服务端校验：常量时间比较 + 时间窗口。
    /// 注意 `nowMs` 显式注入便于测试；运行时传 `Clock.nowMs()`。
    public func verify(
        timestampMs: Int64,
        method: String,
        path: String,
        bodyHashHex: String,
        signatureHex: String,
        nowMs: Int64
    ) -> Bool {
        let skewMs = Int64(clockSkew * 1000)
        if abs(nowMs - timestampMs) > skewMs { return false }
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

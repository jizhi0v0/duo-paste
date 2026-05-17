import Foundation
import Hummingbird
import HTTPTypes
import DuoPasteCore

/// Hummingbird 中间件：校验 HMAC 签名 + 时间窗口。
///
/// 校验失败 → 401 Unauthorized + 不带详细错误（不要泄露"timestamp 过期"还是"sig 错"）。
/// 失败日志在服务端 stderr 写一行 with 原因，方便排查。
///
/// 中间件**不读 body**——签名包含的是 `X-DP-Body-SHA256` header 里的 hex。
/// Handler 读完 body 后**必须**自己 sha256 一次跟 header 对比，否则攻击者可以
/// 伪造一个合法签名但发任意 body。`HMACAuth.verifyBodyHash(...)` 工具方法待加。
public struct HMACAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    public let auth: HMACAuth
    public let now: @Sendable () -> Int64
    /// 路径前缀白名单——这些路径**跳过** HMAC 校验,handler 自己处理 auth(典型:`/pair/`
    /// PIN 配对路径,iOS 还没有 secret 不能签名,走 PIN + rate-limit 替代)
    public let skipPathPrefixes: [String]

    public init(
        auth: HMACAuth,
        now: @escaping @Sendable () -> Int64 = { Self.currentMs() },
        skipPathPrefixes: [String] = ["/pair/"]
    ) {
        self.auth = auth
        self.now = now
        self.skipPathPrefixes = skipPathPrefixes
    }

    public static func currentMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let rawPath = request.uri.path
        if skipPathPrefixes.contains(where: { rawPath.hasPrefix($0) }) {
            return try await next(request, context)
        }
        guard
            let tsName = HTTPField.Name(HMACAuth.timestampHeader),
            let hashName = HTTPField.Name(HMACAuth.bodyHashHeader),
            let sigName = HTTPField.Name(HMACAuth.signatureHeader),
            let tsStr = request.headers[tsName],
            let bodyHash = request.headers[hashName],
            let sig = request.headers[sigName],
            let ts = Int64(tsStr)
        else {
            return Self.unauth("missing or malformed auth headers")
        }

        let method = request.method.rawValue
        // Hummingbird 的 request.uri 是完整的 path + query
        let path = request.uri.path + (request.uri.query.map { "?\($0)" } ?? "")

        let ok = auth.verify(
            timestampMs: ts,
            method: method,
            path: path,
            bodyHashHex: bodyHash,
            signatureHex: sig,
            nowMs: now()
        )
        if !ok {
            return Self.unauth("hmac verify failed (ts=\(ts) method=\(method) path=\(path))")
        }
        return try await next(request, context)
    }

    private static func unauth(_ reason: String) -> Response {
        FileHandle.standardError.write(Data("auth reject: \(reason)\n".utf8))
        return Response(status: .unauthorized)
    }
}

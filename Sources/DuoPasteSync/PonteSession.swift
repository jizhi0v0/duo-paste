import Foundation

/// 当 peer URL 走 Surge Ponte 域名（`*.sgponte`）时使用的 URLSession 配置 + factory。
///
/// 背景：tailscale 在国内到对端 DERP 链路被严重限速（实测 0.07 Mbps），fetch-missing
/// 53 个 blob 跑不完。改走本机 Surge 的 Ponte 隧道（HTTP CONNECT proxy → ponte
/// UDP 隧道 → 对端 daemon），实测吞吐 8.85 Mbps 单流 / 13 Mbps 双流。
///
/// 两个细节决定 ponte 路径能用：
///
/// 1. **强制走 Surge HTTP proxy**（默认 127.0.0.1:6152）——因为 `*.sgponte` 域名
///    只在 Surge 内部解析，URLSession 默认走系统 DNS 找不到。`connectionProxyDictionary`
///    硬注入让所有请求走 HTTP CONNECT tunnel。
///
/// 2. **跳 hostname 校验**（仅 `.sgponte` 域名）——对端 daemon TLS cert SAN 是
///    `bobbys-mac-mini.tail*.ts.net`（tailscale cert 签的），client 请求 `mac.sgponte`
///    会因 SAN 不匹配 fail。HMAC 已提供端到端认证 + 完整性 + Ponte 隧道自身加密，
///    TLS 加密层是冗余的，跳 hostname check 风险可控。**仅 .sgponte host 跳过**，
///    其他域名（tailnet name）严格按系统默认验证。
///
/// 不动 `WSNotificationClient` —— 它用 NIOAsyncHTTP1 直接建 TCP connection
/// 不读系统 proxy 设置，跑不了 ponte。给 WS 留 tailscale URL（Config.PeerConfig.url），
/// 给 PullWorker / fetch-missing / paste-fetcher 用 ponte URL（Config.PeerConfig.pullURL）。
public enum PonteSession {
    /// Surge GUI 默认 HTTP/HTTPS proxy 端口。用户改了的话需要扩展 config 传入。
    public static let defaultSurgeProxyHost = "127.0.0.1"
    public static let defaultSurgeProxyPort = 6152

    /// `host.lowercased().hasSuffix(".sgponte")` 时认为是 ponte 路径。
    public static func isPonteHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h.hasSuffix(".sgponte")
    }

    /// 给定 baseURL，返回适合的 URLSession：
    /// - host 后缀是 `.sgponte` → `pontePool.session`（共享 keep-alive）
    /// - 其他 → `fallback`（一般是 syncURLSession / .shared）
    public static func session(for baseURL: URL, fallback: URLSession) -> URLSession {
        if isPonteHost(baseURL.host) {
            return pontePool.session
        }
        return fallback
    }

    /// 进程级共享 ponte URLSession——跨 caller 复用 HTTPS keep-alive 连接池。
    /// timeout 比 syncURLSession 宽：ponte 走 Surge LA cloud relay 单请求慢些，
    /// 大 blob 给 120s resource budget（53 MB 在 1 MB/s 下还要 ~50s）。
    public static let pontePool: PontePool = .default

    /// URLSession + 配套 delegate 的封装。一次性创建避免 delegate 跟 session 生命周期
    /// 错配（URLSession.delegate 是 strong ref，destroy session 才会释放 delegate）。
    public final class PontePool: @unchecked Sendable {
        public let session: URLSession
        private let delegate: PonteDelegate

        public init(proxyHost: String, proxyPort: Int) {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 120
            cfg.httpMaximumConnectionsPerHost = 6
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.httpAdditionalHeaders = ["User-Agent": "duo-paste/sync/ponte"]
            // 强制走 Surge HTTP proxy。kCFNetworkProxies* 常量解出来其实就是这些字符串
            // ("HTTPSEnable" 等)，是 URLSessionConfiguration 公开认可的 key——HTTP / HTTPS
            // 两套都填以防 ponte 域名上偶尔会被认作 HTTP（虽然我们只发 HTTPS）
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy  as String: proxyHost,
                kCFNetworkProxiesHTTPSPort   as String: proxyPort,
                kCFNetworkProxiesHTTPEnable  as String: 1,
                kCFNetworkProxiesHTTPProxy   as String: proxyHost,
                kCFNetworkProxiesHTTPPort    as String: proxyPort,
            ]
            let delegate = PonteDelegate()
            self.delegate = delegate
            self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        }

        public static let `default` = PontePool(
            proxyHost: PonteSession.defaultSurgeProxyHost,
            proxyPort: PonteSession.defaultSurgeProxyPort
        )
    }

    /// URLSessionDelegate：对 `.sgponte` host 的 TLS challenge 整体放行（含 hostname
    /// 不匹配）。非 ponte host 走系统默认验证（performDefaultHandling）。
    public final class PonteDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        public func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            // 仅给 .sgponte host 放行——其他域名仍走严格验证。注意 protectionSpace.host
            // 是真实请求目标 host（即使经 HTTP CONNECT proxy 也是 ponte 域名，不是 proxy host）
            if PonteSession.isPonteHost(challenge.protectionSpace.host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}

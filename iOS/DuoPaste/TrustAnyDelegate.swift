import Foundation
import Security
import DuoPasteCore

/// 接受任何 TLS cert 的 URLSession delegate。只用于已经持有 request secret/token 的
/// EndpointPicker 与业务请求；PIN onboarding 必须用 `PinnedCertificateDelegate`。
///
/// 用途:Bonjour 发现的 Mac 走 `.local` 主机名,而 Mac 用 Tailscale cert(CN=*.tail-xx.ts.net),
/// hostname 不匹配 → 默认信任拒。本 delegate 接受任何 cert 让 .local URL 也能 TLS 握手。
///
/// 这只保证 server 能验证已配对 client 的 HMAC/token，不给 response 增加签名，也不替代
/// Tailscale/Ponte 等可信 transport。绝不能把它重新用于会签发 credential 的 pairing。
///
/// **同时实现 URLSessionDelegate (session-level) + URLSessionTaskDelegate (task-level)**:
/// iOS 26 上 `URLSession.data(for: req)` 不可靠触发 session-level didReceive challenge,
/// 必须走 `data(for: req, delegate: delegate)` + task-level didReceive 才稳定。两个 protocol
/// 都实现让两种 API 调用都能正确接受 cert
/// iOS app 共享的"接受任何 cert"URLSession。PeerClient / PeerWebSocket / EndpointPicker
/// 用这个，让 .local hostname（cert 跟 Tailscale FQDN 不匹配）也能 TLS。
/// HMAC 签名层兜底,TLS cert 校验不是 trust anchor
enum TrustAnyHTTP {
    nonisolated static let shared: URLSession = {
        let delegate = TrustAnyDelegate()
        return URLSession(
            configuration: makeConfiguration(),
            delegate: delegate,
            delegateQueue: nil
        )
    }()

    nonisolated static func makeConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 20
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return cfg
    }
}

final class TrustAnyDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Self.accept(challenge: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Self.accept(challenge: challenge, completionHandler: completionHandler)
    }

    private static func accept(
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

import Foundation

/// 接受任何 TLS cert 的 URLSession delegate。共享给 PIN 配对 + EndpointPicker 用。
///
/// 用途:Bonjour 发现的 Mac 走 `.local` 主机名,而 Mac 用 Tailscale cert(CN=*.tail-xx.ts.net),
/// hostname 不匹配 → 默认信任拒。本 delegate 接受任何 cert 让 .local URL 也能 TLS 握手。
///
/// **安全**:trust anchor 不是 TLS cert,而是其他层——
/// - PIN 配对:用户物理看到 6 位 PIN + Mac server 端 PairingService 校验 + 5 次错锁
/// - EndpointPicker / HTTP 业务:HMAC-SHA256 签名 + ts 校验,LAN 内 MitM 拿不到 secret 也过不了
///
/// pairing 完成后所有通信用 HMAC,TLS 此时只是 transport 加密,cert 校验非 trust anchor
///
/// **同时实现 URLSessionDelegate (session-level) + URLSessionTaskDelegate (task-level)**:
/// iOS 26 上 `URLSession.data(for: req)` 不可靠触发 session-level didReceive challenge,
/// 必须走 `data(for: req, delegate: delegate)` + task-level didReceive 才稳定。两个 protocol
/// 都实现让两种 API 调用都能正确接受 cert
/// iOS app 共享的"接受任何 cert"URLSession。PeerClient / PeerWebSocket / EndpointPicker /
/// PinPairingClient 都用这个,让 .local hostname(cert 跟 Tailscale FQDN 不匹配)也能 TLS。
/// HMAC 签名层兜底,TLS cert 校验不是 trust anchor
enum TrustAnyHTTP {
    static let shared: URLSession = {
        let delegate = TrustAnyDelegate()
        return URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
    }()
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

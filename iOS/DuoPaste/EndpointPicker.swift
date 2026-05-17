import Foundation
import DuoPasteCore

/// 并发探活 Mac 暴露的所有 endpoint 候选,测 RTT 选最低延迟。
///
/// 输入:候选 list(从 Mac GET /endpoints 拿)+ HMAC secret(签 /health 请求)
/// 输出:按 RTT 升序的可用候选(失败 / 超时的不在列表)
///
/// 探活方式:HEAD /health (无 body) × 1 次,3s timeout。HEAD 比 GET 省字节,/health
/// 不像 /since 那么大,但 /health 也允许 HEAD(没有 body 影响)。
///
/// **不缓存**:每次 pickBest() 完整重测。调用方负责何时重测(NWPathMonitor 路径变 /
/// WS endpoints_changed / 周期 timer)
@MainActor
enum EndpointPicker {
    struct Probe: Equatable, Sendable {
        let endpoint: PeerEndpoint
        let rttMs: Int     // -1 = 失败
        var ok: Bool { rttMs >= 0 }
    }

    /// 并发探活所有 endpoint。返回完整结果(含失败的),按 RTT 升序。
    /// 失败的 RTT = -1,排在最后(用 .max sort key)
    static func probeAll(
        endpoints: [PeerEndpoint],
        secret: Data,
        timeoutSec: TimeInterval = 3
    ) async -> [Probe] {
        guard !endpoints.isEmpty else { return [] }
        let auth = HMACAuth(secret: secret)
        return await withTaskGroup(of: Probe.self, returning: [Probe].self) { group in
            for ep in endpoints {
                group.addTask {
                    await probe(endpoint: ep, auth: auth, timeoutSec: timeoutSec)
                }
            }
            var results: [Probe] = []
            for await r in group { results.append(r) }
            return results.sorted { a, b in
                let ra = a.rttMs < 0 ? Int.max : a.rttMs
                let rb = b.rttMs < 0 ? Int.max : b.rttMs
                return ra < rb
            }
        }
    }

    /// 选最快候选;全部失败返回 nil
    static func pickBest(
        endpoints: [PeerEndpoint],
        secret: Data,
        timeoutSec: TimeInterval = 3
    ) async -> PeerEndpoint? {
        let probes = await probeAll(endpoints: endpoints, secret: secret, timeoutSec: timeoutSec)
        return probes.first(where: { $0.ok })?.endpoint
    }

    // MARK: - 内部

    private static func probe(endpoint: PeerEndpoint, auth: HMACAuth, timeoutSec: TimeInterval) async -> Probe {
        guard let url = URL(string: endpoint.url + "/health") else {
            return Probe(endpoint: endpoint, rttMs: -1)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"   // server /health 只接 GET
        req.timeoutInterval = timeoutSec
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let bodyHash = HMACAuth.emptyBodyHashHex
        let sig = auth.sign(timestampMs: ts, method: "GET", path: "/health", bodyHashHex: bodyHash)
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(bodyHash, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

        // TrustAnyDelegate 接受任何 cert——.local hostname 走 Tailscale cert TLS 不匹配
        // 需要 bypass(HMAC 签名兜底防 MitM)。Tailscale FQDN 走默认信任也通过
        let delegate = TrustAnyDelegate()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let started = Date()
        do {
            let (_, resp) = try await session.data(for: req, delegate: delegate)
            let rtt = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return Probe(endpoint: endpoint, rttMs: -1)
            }
            return Probe(endpoint: endpoint, rttMs: rtt)
        } catch {
            return Probe(endpoint: endpoint, rttMs: -1)
        }
    }
}

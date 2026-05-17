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
    struct Probe: Equatable, Sendable, Identifiable {
        let endpoint: PeerEndpoint
        let rttMs: Int     // -1 = 失败
        var ok: Bool { rttMs >= 0 }
        var id: String { endpoint.url }
    }

    /// 并发探活所有 endpoint。返回完整结果(含失败的)。
    /// 排序按 (kind 优先级, RTT 升序)——跟 macOS SmartTransport 一致:reachability 决定
    /// 走哪条路 (ponte > tailscale > local),不是纯 RTT 比赛。RTT 只是评估证据 +
    /// 同 kind 内的 tiebreaker。
    /// timeout 默 5s——cellular 经 Surge ponte 路径首次握手可能慢
    static func probeAll(
        endpoints: [PeerEndpoint],
        secret: Data,
        timeoutSec: TimeInterval = 5
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
            // 按 (kind 优先级, RTT) 排:不可达的排到最后
            return results.sorted { a, b in
                let pa = kindPriority(a.endpoint.kind)
                let pb = kindPriority(b.endpoint.kind)
                if !a.ok && b.ok { return false }
                if a.ok && !b.ok { return true }
                if !a.ok && !b.ok { return pa < pb }
                if pa != pb { return pa < pb }
                return a.rttMs < b.rttMs
            }
        }
    }

    /// 选最优候选——按 kind 优先级 + RTT。跟 macOS SmartTransport 一致:
    /// **优先级** ponte > tailscale > local > lan_ip;**同 kind** 内按 RTT 升序。
    /// 全部不可达返回 nil。
    ///
    /// 设计动机:
    /// - ponte (Surge 代理) 是用户显式配过的"快路径",优先用
    /// - tailscale 是稳定 fallback,cert 匹配跨网络通
    /// - local mDNS 路径在 iOS 经常不稳(IPv6 link-local RST / DNS 缓存 stale),
    ///   只在 ponte / tailscale 都不通时兜底
    /// - **不**纯 RTT 比 60ms local vs 65ms tailscale,因为 local 那 5ms 优势经常被
    ///   mDNS 解析抖动抹掉,长尾 latency 更差
    static func pickBest(
        endpoints: [PeerEndpoint],
        secret: Data,
        timeoutSec: TimeInterval = 5
    ) async -> PeerEndpoint? {
        let probes = await probeAll(endpoints: endpoints, secret: secret, timeoutSec: timeoutSec)
        return probes.first(where: { $0.ok })?.endpoint
    }

    /// kind 优先级:小数字 = 高优先。ponte=0, tailscale=1, local=2, lan_ip=3
    nonisolated private static func kindPriority(_ k: PeerEndpoint.Kind) -> Int {
        switch k {
        case .ponte: return 0
        case .tailscale: return 1
        case .local: return 2
        case .lanIP: return 3
        }
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

        // TrustAnyDelegate 接受任何 cert——.local / *.sgponte hostname 跟 Tailscale cert
        // 不匹配需要 bypass(HMAC 签名兜底防 MitM)。Tailscale FQDN 走默认信任也通过
        let delegate = TrustAnyDelegate()
        let cfg = URLSessionConfiguration.ephemeral
        // request + resource 双层 timeout 都设到 timeoutSec,避免 DNS 阻塞早早超时但
        // resource 长 timeout 让总体等更久
        cfg.timeoutIntervalForRequest = timeoutSec
        cfg.timeoutIntervalForResource = timeoutSec + 2
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

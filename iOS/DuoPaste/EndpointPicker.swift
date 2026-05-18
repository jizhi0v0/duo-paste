import Foundation
import DuoPasteCore

/// 并发探活 Mac 暴露的所有 endpoint 候选,确认可达后按 route hint/策略选择。
///
/// 输入:候选 list(从 Mac GET /endpoints 拿)+ HMAC secret(签 /health 请求)
/// 输出:包含全部候选的 probe 结果。排序后的第一个 ok 候选即当前建议路线。
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
    /// 排序按 (Mac preferred hint, kind 优先级, RTT 升序)。
    /// Mac 端后续做 speed/transport 测试后只要把最佳路线标成 preferred,iOS 会优先跟随。
    /// RTT 只是 reachability 证据 + 同策略层级内的 tiebreaker,不是最终目标函数。
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
            // 按 (Mac hint, kind 优先级, RTT) 排:不可达的排到最后
            return results.sorted { a, b in
                if !a.ok && b.ok { return false }
                if a.ok && !b.ok { return true }
                if a.endpoint.preferred != b.endpoint.preferred {
                    return a.endpoint.preferred && !b.endpoint.preferred
                }
                let pa = kindPriority(a.endpoint.kind)
                let pb = kindPriority(b.endpoint.kind)
                if !a.ok && !b.ok { return pa < pb }
                if pa != pb { return pa < pb }
                return a.rttMs < b.rttMs
            }
        }
    }

    /// 选最优候选——先尊重 Mac preferred hint,再按 kind 优先级 + RTT。跟 macOS
    /// SmartTransport 一致:
    /// **优先级** preferred > ponte > tailscale > local > lan_ip;**同 kind** 内按 RTT 升序。
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

        // 复用 TrustAnyHTTP.shared（接受任何 cert + HMAC 兜底 MitM）。旧实现每次 probe
        // 都新建 URLSession + invalidateAndCancel，cellular 抖动期 repick 6 个 endpoint
        // 同时跑会让 6 个 session/delegate 短暂同时存活；shared session 走 task-level
        // cancellation（Task.cancel 让 URLSession 自己 cancel 底层连接），不需要 invalidate
        let session = TrustAnyHTTP.shared
        // URLRequest.timeoutInterval 覆盖 session 默认 timeout，shared session resource
        // timeout 是 20s，probe timeoutSec 通常 1-3s 远低于上限不会冲突
        let started = Date()
        do {
            let (_, resp) = try await session.data(for: req)
            let rtt = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                DebugLog.shared.append("probe failed: \(endpoint.kind.rawValue) \(endpoint.url) http=\(code)")
                return Probe(endpoint: endpoint, rttMs: -1)
            }
            return Probe(endpoint: endpoint, rttMs: rtt)
        } catch {
            DebugLog.shared.append("probe failed: \(endpoint.kind.rawValue) \(endpoint.url) error=\(error.localizedDescription)")
            return Probe(endpoint: endpoint, rttMs: -1)
        }
    }
}

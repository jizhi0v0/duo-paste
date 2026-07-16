import Foundation
import DuoPasteCore

/// 并发探活 Mac 暴露的所有 endpoint 候选,确认可达后按 route hint/策略选择。
///
/// 输入:候选 list(从 Mac GET /endpoints 拿)+ HMAC secret(签 /health 请求)
/// 输出:包含全部候选的 probe 结果。排序后的第一个 ok 候选即当前建议路线。
///
/// 探活方式:GET /health (HMAC 签名,空 body) × 1 次,走 NWHTTPTransport(NWConnection)——
/// 跟 WS 同一传输栈,让 probe 可达性 == WS 可达性(URLSession 在 cellular 对 .ts.net /
/// .sgponte 会失败但 NWConnection 能连,见 probe 注释)。
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
    /// timeout 默 12s——对齐 PeerClient./since 的 ponte 超时。cellular 经 Surge Ponte /
    /// DERP 中继首次 TLS 握手实测 6–10s，5s 太短会让本来可达的路径被判失败（RTT 显示 "—"）
    /// `onProbe`:每个 endpoint 探完即回调一次(MainActor),让 UI 增量刷新 RTT，不必等
    /// 整轮最慢的 endpoint(不可达 tailscale 要等满 timeoutSec)才显示其余 endpoint 的延迟。
    /// 最终仍返回排好序的完整结果给选路用
    static func probeAll(
        endpoints: [PeerEndpoint],
        secret: Data,
        credentialToken: String? = nil,
        timeoutSec: TimeInterval = 12,
        onProbe: (@MainActor @Sendable (Probe) -> Void)? = nil
    ) async -> [Probe] {
        guard !endpoints.isEmpty else { return [] }
        let auth = HMACAuth(secret: secret)
        return await withTaskGroup(of: Probe.self, returning: [Probe].self) { group in
            for ep in endpoints {
                group.addTask {
                    await probe(
                        endpoint: ep,
                        auth: auth,
                        credentialToken: credentialToken,
                        timeoutSec: timeoutSec
                    )
                }
            }
            var results: [Probe] = []
            for await r in group {
                results.append(r)
                await onProbe?(r)
            }
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
        credentialToken: String? = nil,
        timeoutSec: TimeInterval = 12
    ) async -> PeerEndpoint? {
        let probes = await probeAll(
            endpoints: endpoints,
            secret: secret,
            credentialToken: credentialToken,
            timeoutSec: timeoutSec
        )
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

    private static func probe(
        endpoint: PeerEndpoint,
        auth: HMACAuth,
        credentialToken: String?,
        timeoutSec: TimeInterval
    ) async -> Probe {
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
        if let credentialToken {
            req.setValue(credentialToken, forHTTPHeaderField: HMACAuth.credentialTokenHeader)
        }

        // 探活走 NWHTTPTransport(NWConnection)——**跟 WS 同一传输栈**。这是关键:UI 把
        // probe RTT 显示在 WS 状态(绿/橙)旁边,用户预期两者一致。iOS cellular 上 URLSession
        // 对 .ts.net / .sgponte 经常 NoSuchRecord / TLS error(DNS / 代理解析路径跟 NWConnection
        // 不一致),但 WS(NWConnection)能连上 → "WS 在线但 probe 失败 = 绿但无延迟"。统一走
        // NWConnection 让 probe 可达性 == WS 可达性,从根上消除这个分叉。
        // (/health 响应极小,NWHTTPTransport 手写 parser 足够;只有大响应的 /since 才需 URLSession)
        let started = Date()
        do {
            let (_, resp) = try await NWHTTPTransport.data(for: req, timeoutSec: timeoutSec)
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

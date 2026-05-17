import Foundation
import DuoPasteCore

/// 计算本机 daemon 可被外部访问到的 URL 候选 list。iOS PeerSyncCoordinator 拿到后并发
/// 探活确认可达,再按 Mac hint / route 策略选择。
///
/// 候选来源:
/// - **Tailscale**:`tls_cert_path` 文件名 stem(即 cert CN)。TLS valid,iOS 需装
///   Tailscale 客户端才能解析 hostname
/// - **Ponte**:`SurgePonte.discoverSelfHostname()`,iOS 装 Surge 才能用。TLS 名字不
///   匹配,iOS 端需要走自签或 HTTP——MVP 阶段先暴露 URL,客户端按场景自决定
/// - **.local mDNS**:`<hostname>.local`,同 Wi-Fi。TLS 不匹配同上
///
/// 不返:
/// - LAN IP 裸地址(原始 IPv4/IPv6)——TLS 永远不匹配,无显著优势 over .local
/// - serve_host (可能 0.0.0.0,无意义)
public enum EndpointDiscovery {
    public static func discover(
        config: Config,
        ponteHost: String? = SurgePonte.discoverSelfHostname(),
        localHostname: String = preferredLocalHostname()
    ) -> [PeerEndpoint] {
        let scheme = config.serveTLS ? "https" : "http"
        let port = config.servePort
        var out: [PeerEndpoint] = []

        if let cert = config.tlsCertPath {
            let stem = (cert as NSString).lastPathComponent
                .replacingOccurrences(of: ".crt", with: "")
            if !stem.isEmpty {
                out.append(PeerEndpoint(
                    url: "\(scheme)://\(stem):\(port)",
                    kind: .tailscale,
                    preferred: false
                ))
            }
        }
        if let pHost = ponteHost, !pHost.isEmpty {
            out.append(PeerEndpoint(
                url: "\(scheme)://\(pHost):\(port)",
                kind: .ponte,
                preferred: false
            ))
        }
        // local 永远加,即便重复(stem 可能等于 localHostname.local 罕见情形 → 去重)
        let localURL = "\(scheme)://\(localHostname):\(port)"
        if !out.contains(where: { $0.url == localURL }) {
            out.append(PeerEndpoint(url: localURL, kind: .local, preferred: false))
        }
        return out
    }

    /// 本机 Bonjour .local hostname。Host.current().localizedName 已是 ".local" 形式时不
    /// 重复加后缀。完全拿不到 hostname → 兜底 "mac.local"
    public static func preferredLocalHostname() -> String {
        // 不用 Host.current()——Host 是 Foundation macOS-only,DuoPasteSync 跨平台编译。
        // 用 ProcessInfo.processInfo.hostName 等价(返本机 hostname,可能含 .local 后缀)
        let raw = ProcessInfo.processInfo.hostName
        if raw.isEmpty { return "mac.local" }
        return raw.hasSuffix(".local") ? raw : "\(raw).local"
    }
}

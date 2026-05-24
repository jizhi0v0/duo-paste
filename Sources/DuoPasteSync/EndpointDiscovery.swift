import Foundation
import DuoPasteCore
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif
#if canImport(Darwin)
import Darwin
#endif

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

        if let cert = config.tlsCertPath, let stem = certHostnameStem(cert) {
            out.append(PeerEndpoint(
                url: "\(scheme)://\(stem):\(port)",
                kind: .tailscale,
                preferred: false
            ))
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

    /// 从 cert 文件路径提取 hostname。剥两层文件名约定:
    /// - `.crt` / `.pem` 扩展名
    /// - `.dual` 中间段(mkcert 双 SAN 命名习惯, 见 CLAUDE.md "TLS cert 双 SAN 部署")
    ///
    /// **不要**回退到只 `.replacingOccurrences(of: ".crt", with: "")`——配双 SAN cert
    /// (文件名 `<host>.dual.crt`) 时会 leak `.dual` 当 hostname 进 /endpoints 响应,iOS
    /// 端 DNS 永久解析失败。回归测试 `EndpointDiscoveryTests.certStemStripsDualSuffix`
    static func certHostnameStem(_ path: String) -> String? {
        var stem = (path as NSString).lastPathComponent
        for ext in [".crt", ".pem"] {
            if stem.lowercased().hasSuffix(ext) {
                stem = String(stem.dropLast(ext.count))
                break
            }
        }
        if stem.lowercased().hasSuffix(".dual") {
            stem = String(stem.dropLast(".dual".count))
        }
        return stem.isEmpty ? nil : stem
    }

    /// 本机 Bonjour `.local` hostname(如 `bobbys-mac-mini.local`)。
    ///
    /// **macOS**: 走 `SCDynamicStoreCopyLocalHostName()` (等价 `scutil --get LocalHostName`),
    /// 保证返 Bonjour 短名,跟 mDNSResponder 注册的 `<host>.local` A 记录硬对齐。
    ///
    /// **不要**回退到 `ProcessInfo.processInfo.hostName`——Darwin 上它走 `Host.current()`
    /// → 反 DNS 查询。Tailscale MagicDNS 在场时反查 100.x.x.x 拿到 `<host>.tail<id>.ts.net`,
    /// 进程启动早期 cache 住,再被本函数拼上 `.local` 后缀 → 出现 `bobbys-mac-mini.tail<id>.ts.net.local`
    /// 这种永远不可解析的双 suffix URL leak 进 /endpoints 响应。回归测试
    /// `EndpointDiscoveryTests.preferredLocalHostnameNeverDoublesLocal`
    ///
    /// **Linux / 非 Darwin** fallback: `gethostname()` + 取第一段 + `.local`
    public static func preferredLocalHostname() -> String {
        #if canImport(SystemConfiguration)
        if let cf = SCDynamicStoreCopyLocalHostName(nil) {
            let name = (cf as String).lowercased()
            if !name.isEmpty && name != "localhost" {
                return name.hasSuffix(".local") ? name : "\(name).local"
            }
        }
        #endif
        #if canImport(Darwin)
        var buf = [CChar](repeating: 0, count: 256)
        if gethostname(&buf, buf.count) == 0 {
            let nullIdx = buf.firstIndex(of: 0) ?? buf.count
            let bytes = buf[0..<nullIdx].map { UInt8(bitPattern: $0) }
            let raw = String(decoding: bytes, as: UTF8.self)
            let first = raw.split(separator: ".").first.map(String.init) ?? raw
            let lower = first.lowercased()
            if !lower.isEmpty && lower != "localhost" {
                return lower.hasSuffix(".local") ? lower : "\(lower).local"
            }
        }
        #endif
        return "mac.local"
    }
}

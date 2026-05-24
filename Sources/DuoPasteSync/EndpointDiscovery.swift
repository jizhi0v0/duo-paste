import Foundation
import DuoPasteCore
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Darwin)
import Darwin
#endif

/// 计算本机 daemon 可被外部访问到的 URL 候选 list。iOS PeerSyncCoordinator 拿到后并发
/// 探活确认可达,再按 Mac hint / route 策略选择。
///
/// 候选来源:
/// - **Tailscale**:读 `tls_cert_path` cert 的 SubjectAltName,首选 `.ts.net` SAN
///   (Tailscale FQDN, SNI 校验稳)。读不到 / 无 ts.net SAN → fallback 到 cert
///   文件名 stem(向后兼容非 tailscale TLS 部署)。iOS 需装 Tailscale 客户端才能
///   解析 hostname
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

        if let cert = config.tlsCertPath,
           let host = certTailscaleHost(cert) ?? certHostnameStem(cert) {
            out.append(PeerEndpoint(
                url: "\(scheme)://\(host):\(port)",
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

    /// 读 cert SAN 拿 tailscale 候选 hostname。SAN 是 TLS SNI 校验的**唯一可信源**——
    /// cert 文件名只是部署习惯,SAN 才是真相。
    ///
    /// 选取规则:
    /// 1. 首选**首条** `.ts.net` 结尾的 DNS SAN(Tailscale MagicDNS FQDN)
    /// 2. 次选**首条**非 `.sgponte` 结尾的 DNS SAN(`.sgponte` 留给独立 ponte 候选)
    /// 3. 无可用 SAN / 读 cert 失败 → nil(caller fallback `certHostnameStem`)
    ///
    /// **为什么需要这条路径**:mkcert 双 SAN 命名约定让 cert 文件名是短名
    /// (`bobbys-mac-mini.dual.crt`),`certHostnameStem` 剥完只剩 `bobbys-mac-mini`,
    /// iOS 端 SNI 校验会失败(cert SAN 是 FQDN,短名匹配不上)。读 SAN 才能拿出 cert
    /// 真正能验证的 hostname。
    static func certTailscaleHost(_ certPath: String) -> String? {
        guard let sans = readCertDnsSANs(certPath), !sans.isEmpty else { return nil }
        return pickTailscaleHostFromSANs(sans)
    }

    /// 纯函数:从 DNS SAN 列表挑首选 tailscale 候选 hostname。提出来便于单测——
    /// `readCertDnsSANs` 走 Security framework 不可控,选取规则要独立验证。
    static func pickTailscaleHostFromSANs(_ names: [String]) -> String? {
        let lower = names.map { $0.lowercased() }
        if let ts = lower.first(where: { $0.hasSuffix(".ts.net") }) {
            return ts
        }
        if let nonPonte = lower.first(where: { !$0.hasSuffix(".sgponte") }) {
            return nonPonte
        }
        return nil
    }

    /// 读 cert 文件(PEM 或 DER),解 X.509 SubjectAltName,返 DNS Name 列表。
    /// 失败(文件读不到 / 非合法 cert / 无 SAN ext / Linux 无 Security framework)
    /// 返 nil,caller fallback 到 `certHostnameStem`。
    static func readCertDnsSANs(_ certPath: String) -> [String]? {
        #if canImport(Security)
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: certPath)) else { return nil }
        let der = pemToDER(raw) ?? raw
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        let keys = [kSecOIDSubjectAltName] as CFArray
        var err: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(cert, keys, &err) as? [String: Any] else { return nil }
        guard let sanEntry = values[kSecOIDSubjectAltName as String] as? [String: Any] else { return nil }
        guard let entries = sanEntry[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        var names: [String] = []
        for entry in entries {
            // SecCertificateCopyValues 返的 DNS SAN entry label 在 macOS 是字面 "DNS Name"。
            // value 字段直接是字符串
            guard let label = entry[kSecPropertyKeyLabel as String] as? String, label == "DNS Name" else { continue }
            guard let value = entry[kSecPropertyKeyValue as String] as? String, !value.isEmpty else { continue }
            names.append(value)
        }
        return names.isEmpty ? nil : names
        #else
        return nil
        #endif
    }

    /// PEM(`-----BEGIN CERTIFICATE-----` + base64 + `-----END CERTIFICATE-----`)→ DER。
    /// 已是 DER(二进制)直接返 nil,caller 用原数据继续。多 cert PEM 取首个。
    private static func pemToDER(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .ascii) else { return nil }
        guard text.contains("-----BEGIN CERTIFICATE-----") else { return nil }
        let afterBegin = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().first ?? ""
        let body = afterBegin.components(separatedBy: "-----END CERTIFICATE-----").first ?? ""
        let stripped = body
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: stripped)
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
            // UInt8(truncatingIfNeeded:) 跨 CChar=Int8 (Darwin/x86_64 Linux) 和
            // CChar=UInt8 (aarch64 Linux) 都成立——比 UInt8(bitPattern:) (只 Int8→UInt8)
            // 更便携。截到 NUL 再 UTF8 解,避开已 deprecated 的 String(cString:)。
            let nullIdx = buf.firstIndex(of: 0) ?? buf.count
            let bytes = buf[..<nullIdx].map { UInt8(truncatingIfNeeded: $0) }
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

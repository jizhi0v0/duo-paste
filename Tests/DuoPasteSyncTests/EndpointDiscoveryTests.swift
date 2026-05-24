import Testing
import Foundation
import DuoPasteCore
@testable import DuoPasteSync

/// EndpointDiscovery 单元测试。两条契约硬不变量:
/// 1. cert filename `.dual` 中间段必须被剥掉(mkcert 双 SAN 命名约定)
/// 2. `.local` 后缀**不能**叠加 —— Tailscale MagicDNS 场景下 ProcessInfo.hostName 会
///    返 tailnet FQDN, 早期实现拼上 ".local" 得出 ".tail<id>.ts.net.local" 双 suffix
///    永久不可解析 URL。新实现走 SCDynamicStore Bonjour LocalHostName, 绕开反 DNS
///    陷阱
///
/// 见 Sources/DuoPasteSync/EndpointDiscovery.swift 头注释 + CLAUDE.md 部署节
@Suite
struct EndpointDiscoveryTests {

    // MARK: - certHostnameStem

    @Test func certStemStripsCrtOnly() {
        #expect(EndpointDiscovery.certHostnameStem("/tls/bobbys-mac-mini.crt") == "bobbys-mac-mini")
    }

    @Test func certStemStripsDualSuffix() {
        // mkcert 双 SAN 命名: `<host>.dual.crt` —— `.dual` 必须剥掉,
        // 否则 hostname leak 出 "bobbys-mac-mini.dual" 进 /endpoints,iOS 端 DNS 永久失败
        #expect(EndpointDiscovery.certHostnameStem("/tls/bobbys-mac-mini.dual.crt") == "bobbys-mac-mini")
        #expect(EndpointDiscovery.certHostnameStem("/tls/bobbys-macbook-pro.dual.crt") == "bobbys-macbook-pro")
    }

    @Test func certStemStripsPemExtension() {
        #expect(EndpointDiscovery.certHostnameStem("/tls/host.pem") == "host")
        #expect(EndpointDiscovery.certHostnameStem("/tls/host.dual.pem") == "host")
    }

    @Test func certStemKeepsFqdnDots() {
        // 单 SAN tailscale 命名 `<host>.tail<id>.ts.net.crt` —— FQDN 中间的 dot
        // 不能误剥(只剥 .crt 跟 .dual 两个具体后缀)
        #expect(
            EndpointDiscovery.certHostnameStem("/tls/bobbys-mac-mini.tail69730a.ts.net.crt")
                == "bobbys-mac-mini.tail69730a.ts.net"
        )
    }

    @Test func certStemNilForEmpty() {
        #expect(EndpointDiscovery.certHostnameStem(".crt") == nil)
        #expect(EndpointDiscovery.certHostnameStem(".dual.crt") == nil)
    }

    @Test func certStemHandlesNoExtension() {
        // 不该发生(config 总配 .crt),但 graceful: 没扩展名当 hostname 用
        #expect(EndpointDiscovery.certHostnameStem("/tls/host") == "host")
    }

    @Test func certStemSuffixMatchIsCaseInsensitive() {
        // 用户手写 config 大写扩展名概率低但合法,小写化对比避免漏剥
        #expect(EndpointDiscovery.certHostnameStem("/tls/HOST.CRT") == "HOST")
        #expect(EndpointDiscovery.certHostnameStem("/tls/Host.Pem") == "Host")
        #expect(EndpointDiscovery.certHostnameStem("/tls/host.Dual.crt") == "host")
        #expect(EndpointDiscovery.certHostnameStem("/tls/host.DUAL.CRT") == "host")
    }

    // MARK: - preferredLocalHostname

    @Test func preferredLocalHostnameNeverDoublesLocal() {
        // 硬不变量: 结果以 ".local" 结尾,且剥掉一次后不再以 ".local" 结尾。早期实现在
        // Tailscale MagicDNS 在场时 ProcessInfo.hostName 返 "host.tail<id>.ts.net",
        // hasSuffix(".local")=false 又拼一次 → "host.tail<id>.ts.net.local" 双 suffix。
        // 新实现走 SCDynamicStore 绝不踩。
        //
        // 不用 components(separatedBy: ".local").count 这种"子串出现次数"统计——
        // `host.localnet.local` 这种合法 hostname 会被误报 2,松。
        let name = EndpointDiscovery.preferredLocalHostname()
        #expect(name.hasSuffix(".local"))
        #expect(!name.dropLast(".local".count).hasSuffix(".local"),
                "preferredLocalHostname returned \(name) with doubled .local suffix")
    }

    @Test func preferredLocalHostnameEndsWithLocal() {
        let name = EndpointDiscovery.preferredLocalHostname()
        #expect(name.hasSuffix(".local"))
    }

    @Test func preferredLocalHostnameIsLowercase() {
        // SCDynamicStore 返大小写混合(scutil LocalHostName 用户原始 case),
        // URL hostname 统一小写更稳——大小写在 URLSession SNI / cache key 上有时敏感
        let name = EndpointDiscovery.preferredLocalHostname()
        #expect(name == name.lowercased())
    }

    @Test func preferredLocalHostnameNotLocalhost() {
        // localhost.local 是合法 mDNS 名但语义错——意味着 SCDynamicStore 跟 gethostname
        // 都没拿到真实 hostname。函数应该 fallback 到 "mac.local"
        let name = EndpointDiscovery.preferredLocalHostname()
        #expect(name != "localhost.local")
    }

    // MARK: - discover() 端到端

    private func makeConfig(tlsCertPath: String?) -> Config {
        Config(
            serve: true,
            serveHost: "0.0.0.0",
            servePort: 8443,
            serveTLS: true,
            tlsCertPath: tlsCertPath,
            tlsKeyPath: nil,
            peers: []
        )
    }

    @Test func discoverEmitsCertStemForTailscaleWhenCertUnreadable() {
        // cert path 指向不存在的文件 → readCertDnsSANs 返 nil → fallback 到 certHostnameStem
        let cfg = makeConfig(tlsCertPath: "/tls/bobbys-mac-mini.dual.crt")
        let eps = EndpointDiscovery.discover(
            config: cfg,
            ponteHost: nil,
            localHostname: "bobbys-mac-mini.local"
        )
        let tailscale = eps.first(where: { $0.kind == PeerEndpoint.Kind.tailscale })
        #expect(tailscale?.url == "https://bobbys-mac-mini:8443",
                "expected .dual stem fallback; got \(tailscale?.url ?? "nil")")
    }

    @Test func discoverNeverLeaksDualOrDoubleLocal() {
        let cfg = makeConfig(tlsCertPath: "/tls/bobbys-mac-mini.dual.crt")
        let eps = EndpointDiscovery.discover(
            config: cfg,
            ponteHost: nil,
            localHostname: "bobbys-mac-mini.local"
        )
        for ep in eps {
            #expect(!ep.url.contains(".dual"), "leaked .dual in \(ep.url)")
            #expect(!ep.url.contains(".local.local"), "double .local in \(ep.url)")
            #expect(!ep.url.contains(".ts.net.local"), "ts.net.local double-suffix in \(ep.url)")
        }
    }

    @Test func discoverInjectedLocalHostnameOverride() {
        // 让 caller 显式注入 localHostname (default 走 SCDynamicStore) —— 测试不依赖
        // 跑测试机器的实际 LocalHostName 状态
        let cfg = makeConfig(tlsCertPath: nil)
        let eps = EndpointDiscovery.discover(
            config: cfg,
            ponteHost: nil,
            localHostname: "test-host.local"
        )
        #expect(eps.count == 1)
        #expect(eps.first?.kind == PeerEndpoint.Kind.local)
        #expect(eps.first?.url == "https://test-host.local:8443")
    }

    // MARK: - pickTailscaleHostFromSANs(选取规则)

    @Test func pickPrefersTsNetSAN() {
        // 双 SAN cert (`.ts.net` + `.sgponte`):优先返 `.ts.net`,`.sgponte` 留给 ponte 候选
        let names = ["bobbys-mac-mini.tail69730a.ts.net", "mac.sgponte"]
        #expect(EndpointDiscovery.pickTailscaleHostFromSANs(names)
            == "bobbys-mac-mini.tail69730a.ts.net")
    }

    @Test func pickPrefersTsNetRegardlessOfOrder() {
        let names = ["mac.sgponte", "bobbys-mac-mini.tail69730a.ts.net"]
        #expect(EndpointDiscovery.pickTailscaleHostFromSANs(names)
            == "bobbys-mac-mini.tail69730a.ts.net")
    }

    @Test func pickSkipsSgponteOnly() {
        // 只 `.sgponte` SAN 无可用 tailscale 候选(那条本就该走 ponte 候选,
        // 别让 tailscale 候选偷用,否则跟 SurgePonte.discoverSelfHostname 重复)
        let names = ["mac.sgponte"]
        #expect(EndpointDiscovery.pickTailscaleHostFromSANs(names) == nil)
    }

    @Test func pickFallsBackToNonPonteDNS() {
        // 无 `.ts.net` 但有其它 DNS SAN(非 sgponte)——取首条
        let names = ["bobbys-mac-mini.example.com", "mac.sgponte"]
        #expect(EndpointDiscovery.pickTailscaleHostFromSANs(names)
            == "bobbys-mac-mini.example.com")
    }

    @Test func pickHandlesEmpty() {
        #expect(EndpointDiscovery.pickTailscaleHostFromSANs([]) == nil)
    }

    @Test func pickLowercasesOutput() {
        // SAN 在 cert 里可能任意大小写; URL hostname 统一小写,跟 preferredLocalHostname 对齐
        let names = ["BOBBYS-MAC-MINI.TAIL69730A.TS.NET"]
        #expect(EndpointDiscovery.pickTailscaleHostFromSANs(names)
            == "bobbys-mac-mini.tail69730a.ts.net")
    }

    @Test func pickIsCaseInsensitiveOnSuffixMatch() {
        // 大小写不影响 `.ts.net` / `.sgponte` 后缀匹配
        let names = ["Host.Tail123.Ts.Net", "Server.SGPONTE"]
        #expect(EndpointDiscovery.pickTailscaleHostFromSANs(names)
            == "host.tail123.ts.net")
    }

    // MARK: - readCertDnsSANs + 端到端 cert SAN 解析

    /// 测试 fixture: 双 SAN cert,SAN = [`test-host.tail69730a.ts.net`, `test.sgponte`]。
    /// 由 openssl req -x509 -newkey rsa:2048 + 双 SAN config 离线生成,自包含不依赖外部文件。
    /// 365 天有效,2027-05-24 过期——到期前重新生成。
    private static let dualSANPEM = """
    -----BEGIN CERTIFICATE-----
    MIIDEzCCAfugAwIBAgIUMTbdZJ6WQ2vDJeN1rQt4+jt01jQwDQYJKoZIhvcNAQEL
    BQAwFzEVMBMGA1UEAwwMdGVzdC1maXh0dXJlMB4XDTI2MDUyNDEyMDkyMVoXDTI3
    MDUyNDEyMDkyMVowFzEVMBMGA1UEAwwMdGVzdC1maXh0dXJlMIIBIjANBgkqhkiG
    9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxvGnlm0FvmJdkHg6uWbCaXZFuCkVVqBFGFp/
    Lw7SokSH5cLbqdvBMOHaEDwB1zIrZrX3yV012myTv6HLF6Ggq98xBNjIwB04m/rn
    wnwfSHaq49Z+W/zhn+0KzspqG6H8Fz5P2AVk0jkXg0Z5fGz8TI6j6lj7/cblwbHE
    fSqi4Tpf7GokZJBWBc/MK1hixcJ/ggNgs+dXg/NMhTwiB6AwAa1JlHl6UNwGzcuZ
    SofvPgaTj3p4g80TpUE0qFHQ9lQCWY+aMmaFG0feEgn0C2lvNLXnFRKaU4yRLXLj
    p54uAshPVmu1IBEzaC7za2QPzqnZczMRnQF6ZLL45Dvla+Pu0QIDAQABo1cwVTA0
    BgNVHREELTArght0ZXN0LWhvc3QudGFpbDY5NzMwYS50cy5uZXSCDHRlc3Quc2dw
    b250ZTAdBgNVHQ4EFgQUwDT9utKXQxcnMtr7yFrKdbfSKMUwDQYJKoZIhvcNAQEL
    BQADggEBAIz7OeklczlbRAJoOmVpxF6ytNZM/++ZC/ZMdqmmsu5hHPB6wdCoeT37
    imSwgs+jgGkhEaNe6qO0YX+xQLOGm2XLD+tHyceqq5Ciyy/6pDcDSSulyHLnPUsz
    0wqYAAGs0IGpMpgvRTnsZ0KQclYiUeTOr0/jjN/0LX+hG73Mfeby+2riWnvg9NC4
    FCjZZy8im2KkwX9ZZiZsbd4eC/o5cwlhoNwOHh83fYibbPtLWL2W2OUbnyqPi9sq
    f7+QTm82rBVDUtofdFQnflZmk6Ux7MnmFbyLesM6fwLYzeFTJdeFLLyKSBwAjSP2
    r8xQHTQCyZTOcZgTeGLiRSSzM7Cxaf8=
    -----END CERTIFICATE-----
    """

    /// 单 SAN cert,SAN = [`test.sgponte`]
    private static let sgponteOnlyPEM = """
    -----BEGIN CERTIFICATE-----
    MIIC9jCCAd6gAwIBAgIUcYa1Me0y0bS56QUZtlmY649GkfMwDQYJKoZIhvcNAQEL
    BQAwFzEVMBMGA1UEAwwMdGVzdC1maXh0dXJlMB4XDTI2MDUyNDEyMDkyNFoXDTI3
    MDUyNDEyMDkyNFowFzEVMBMGA1UEAwwMdGVzdC1maXh0dXJlMIIBIjANBgkqhkiG
    9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyOCq4eU14UQ1DA7Hssvkkd5nU2IoSq56T9f+
    /JRX/hK1MKEn0/mEIMazf+3ipRQfcy0CXTDLbd18toccsxECAhbayfygvE+bAT+D
    WEbNItA1hX4Pafwkf0iTZJ4FkAMLtlHu/ffp9RfUtuBQllL4vQu4Vha2MtNWqiSD
    NEUiQKLLBvfTrxLVraxEotTqctMwNhCxTywiLGWeNGv5/anx48tV+7dGdw27cL9W
    MwA1CTI6xBU08/ti0z0Kew94c7XB+8gr/VKWJPA9YV9imvxD7XlntF5gkMGfOgk0
    8E7ljCj2I+UEoW1CQOe9bx47PkfINuav5eutSpE3uu1Ptba5AwIDAQABozowODAX
    BgNVHREEEDAOggx0ZXN0LnNncG9udGUwHQYDVR0OBBYEFLCcgupwGPdhO+x+2P3o
    nrWv5xlJMA0GCSqGSIb3DQEBCwUAA4IBAQAJWCMKK6uixQLnzPYPhWZ8lDS1u+OP
    Ksauy3IrQ5N47nG0ZLOg95yMNxhLmzqpDqp+cVI8i2az7GU2ISutk9WRMfFIcSsw
    0IYyYSoXsX26vrn7tvDARw78VAPabpEqfJ5LdoyrIdz7JRFvBMgdmjTGbhcaiZ8D
    io6ogkLY2Y7GPdtB/lddel4tkR5iVEMxTlyG0qVvH51bgolx/Mr9l9d2RSQPjlqY
    VGR/ZGutEmjE3DR90dtco+E0Eqb3E97bwhsnUBf22hVSTwO27Scb8jl7rTAhmyHt
    btdjJcfp3QpB8smeHnTYrs0PwS0+rvkXNVmKm2iEUSW/GumPrxoyn5uT
    -----END CERTIFICATE-----
    """

    /// 单 SAN cert,SAN = [`some-short-name`] (非 ts.net, 非 sgponte)
    private static let shortOnlyPEM = """
    -----BEGIN CERTIFICATE-----
    MIIC+TCCAeGgAwIBAgIUBVErOVTt30LXSimwjwd6YlZY5W4wDQYJKoZIhvcNAQEL
    BQAwFzEVMBMGA1UEAwwMdGVzdC1maXh0dXJlMB4XDTI2MDUyNDEyMDkyNloXDTI3
    MDUyNDEyMDkyNlowFzEVMBMGA1UEAwwMdGVzdC1maXh0dXJlMIIBIjANBgkqhkiG
    9w0BAQEFAAOCAQ8AMIIBCgKCAQEAp7HCqJgShYuN3oGcwz6r84IdnN3QTCuEy5i6
    +NDD3lcfgefVx1U/KLAl85psld33ZEiZjF99Fi5gGKoKwBFOirLlUsM16Dd2Gg1G
    +W94ZcKywLD/i1CLxHq0Ps+Q5vE8B57BvPzzRcu3s0RypbZvkTht1NhZ4jQ7BIn0
    7kIOf2uftB5yvwS3miR3eSfkn32RokEbO6Osc9vxWjPuhaoeEm6/GtrZcRRJaA73
    t2DxOkRMt8fu1fYqqCTBh7hTfbxXKNKqRRFEqhcBIE+QNx28w60BFW+BB+k1suPa
    791IozKdBNz8Qfv6SAiyrtbwFtiftbapLss19oDtgA7tHfoUIQIDAQABoz0wOzAa
    BgNVHREEEzARgg9zb21lLXNob3J0LW5hbWUwHQYDVR0OBBYEFIWMqO3OXfjt7dLI
    Vlpr7ZqlxU6vMA0GCSqGSIb3DQEBCwUAA4IBAQCeRTClBjXyisJ7ryzYYgBHhUDW
    QjshmhJf/ac27jWyhvEWf9iqY8X7ySTX3cLPoH6zfYMmj96/lMmQR/v98/evijJ7
    JX0iZZaGjYhk3oZqbvnObQmIHJjNjakCJSolDtCLbWpJvCL+Samv7dzXP2Z8H1I2
    +LRNkaenbVATiOK4RV9uH6ORRQ353rrJW0EKM3CZ6c2aNf+2S/WqTN5zXw3VIm/w
    n88dq/k41Pn1g0mfY8fnXM3g+2b07R8HJhJHaB2M1fIdmnuIcUFVxCYnBsVE4RK+
    GbkGPIv3iLkJ0PXqdc6YZ5lwpARV5ElojpuYndxDXPj0yAA0XXj92QknsZIi
    -----END CERTIFICATE-----
    """

    /// 写 PEM 到临时文件,返路径。测试结束 caller 不必清理(系统 tmp 会清)
    private func writeTempPEM(_ pem: String, suffix: String) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dp-test-\(UUID().uuidString)-\(suffix).crt")
        try? pem.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func readCertDnsSANsReturnsBothSANsFromDualCert() throws {
        let path = writeTempPEM(Self.dualSANPEM, suffix: "dual")
        let names = try #require(EndpointDiscovery.readCertDnsSANs(path))
        #expect(names.contains("test-host.tail69730a.ts.net"))
        #expect(names.contains("test.sgponte"))
    }

    @Test func readCertDnsSANsReturnsNilForMissingFile() {
        #expect(EndpointDiscovery.readCertDnsSANs("/nonexistent/path/no-such.crt") == nil)
    }

    @Test func certTailscaleHostPicksTsNetFromDualCert() {
        let path = writeTempPEM(Self.dualSANPEM, suffix: "dual")
        #expect(EndpointDiscovery.certTailscaleHost(path)
            == "test-host.tail69730a.ts.net")
    }

    @Test func certTailscaleHostReturnsNilForSgponteOnlyCert() {
        // 只 `.sgponte` SAN → 不该当 tailscale 候选;caller 走 stem fallback
        let path = writeTempPEM(Self.sgponteOnlyPEM, suffix: "ponte")
        #expect(EndpointDiscovery.certTailscaleHost(path) == nil)
    }

    @Test func certTailscaleHostReturnsShortNameForShortOnlyCert() {
        // 无 ts.net 但有非 sgponte DNS SAN → 取那个(短名 / 自定义域 cert)
        let path = writeTempPEM(Self.shortOnlyPEM, suffix: "short")
        #expect(EndpointDiscovery.certTailscaleHost(path) == "some-short-name")
    }

    @Test func discoverUsesSANNotFilenameStemWhenCertExists() {
        // 核心回归:cert 文件名 `<short>.dual.crt` 让 stem 剥成 `<short>`,但 SAN
        // 含 `.ts.net` FQDN——`discover()` 必须读 SAN 拿 FQDN,不能用 stem。
        // 修复前 f4e711a 走 stem path 让 iOS 看到裸短名 → SNI 校验失败
        let path = writeTempPEM(Self.dualSANPEM, suffix: "regression")
        let cfg = Config(
            serve: true,
            serveHost: "0.0.0.0",
            servePort: 8443,
            serveTLS: true,
            tlsCertPath: path,
            tlsKeyPath: nil,
            peers: []
        )
        let eps = EndpointDiscovery.discover(
            config: cfg,
            ponteHost: nil,
            localHostname: "test-host.local"
        )
        let tailscale = eps.first(where: { $0.kind == PeerEndpoint.Kind.tailscale })
        #expect(tailscale?.url == "https://test-host.tail69730a.ts.net:8443",
                "expected SAN-derived FQDN, got \(tailscale?.url ?? "nil")")
    }
}

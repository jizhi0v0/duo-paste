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

    // MARK: - preferredLocalHostname

    @Test func preferredLocalHostnameNeverDoublesLocal() {
        // 硬不变量: 结果只含**一个** ".local" 后缀。早期实现在 Tailscale MagicDNS 在场时
        // ProcessInfo.hostName 返 "host.tail<id>.ts.net", hasSuffix(".local")=false 又拼一次
        // → "host.tail<id>.ts.net.local" 双 suffix。新实现走 SCDynamicStore 绝不踩
        let name = EndpointDiscovery.preferredLocalHostname()
        let dotLocalCount = name.components(separatedBy: ".local").count - 1
        #expect(dotLocalCount == 1, "preferredLocalHostname returned \(name) with \(dotLocalCount) .local suffixes")
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

    @Test func discoverEmitsCertStemForTailscale() {
        let cfg = makeConfig(tlsCertPath: "/tls/bobbys-mac-mini.dual.crt")
        let eps = EndpointDiscovery.discover(
            config: cfg,
            ponteHost: nil,
            localHostname: "bobbys-mac-mini.local"
        )
        let tailscale = eps.first(where: { $0.kind == PeerEndpoint.Kind.tailscale })
        #expect(tailscale?.url == "https://bobbys-mac-mini:8443",
                "expected .dual to be stripped; got \(tailscale?.url ?? "nil")")
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
}

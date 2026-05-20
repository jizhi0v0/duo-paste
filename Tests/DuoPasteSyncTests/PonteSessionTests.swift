import Foundation
import Testing
@testable import DuoPasteSync

@Suite("PonteSession host detection + factory")
struct PonteSessionTests {
    @Test func isPonteHostMatchesSgponteSuffix() {
        #expect(PonteSession.isPonteHost("mac.sgponte"))
        #expect(PonteSession.isPonteHost("mbpmbp.sgponte"))
        #expect(PonteSession.isPonteHost("anything.sgponte"))
        #expect(PonteSession.isPonteHost("sub.deep.sgponte"))
    }

    @Test func isPonteHostCaseInsensitive() {
        #expect(PonteSession.isPonteHost("MAC.SGPONTE"))
        #expect(PonteSession.isPonteHost("Mac.SgPonte"))
    }

    @Test func isPonteHostRejectsOtherDomains() {
        #expect(!PonteSession.isPonteHost(nil))
        #expect(!PonteSession.isPonteHost(""))
        #expect(!PonteSession.isPonteHost("bobbys-mac-mini.tail69730a.ts.net"))
        #expect(!PonteSession.isPonteHost("localhost"))
        #expect(!PonteSession.isPonteHost("sgponte"))  // 没前缀点，不算
        #expect(!PonteSession.isPonteHost("foo.sgponte.com"))  // sgponte 不是末段
    }

    @Test func sessionForPonteURLReturnsPonteSession() {
        let fallback = URLSession.shared
        let s = PonteSession.session(
            for: URL(string: "https://mac.sgponte:8443/health")!,
            fallback: fallback
        )
        #expect(s === PonteSession.pontePool.session)
        #expect(s !== fallback)
    }

    @Test func sessionForTailscaleURLReturnsFallback() {
        let fallback = URLSession.shared
        let s = PonteSession.session(
            for: URL(string: "https://bobbys-mac-mini.tail69730a.ts.net:8443/health")!,
            fallback: fallback
        )
        #expect(s === fallback)
    }

    @Test func ponteSessionConfiguredWithSurgeProxy() {
        let cfg = PonteSession.pontePool.session.configuration
        let proxy = cfg.connectionProxyDictionary ?? [:]
        // 至少一种 key 命中（HTTPSProxy / kCFNetworkProxiesHTTPSProxy）。两种都填
        // 是因为不同 macOS 版本 Foundation 认不同 key
        let host = (proxy["HTTPSProxy"] as? String) ?? (proxy[kCFNetworkProxiesHTTPSProxy as String] as? String)
        let port = (proxy["HTTPSPort"] as? Int) ?? (proxy[kCFNetworkProxiesHTTPSPort as String] as? Int)
        #expect(host == "127.0.0.1")
        #expect(port == 6152)
    }

    /// Step 2 网络栈隔离不变量:
    /// 1. PontePool 用 `.ephemeral` 基底 —— 不持久化 cookie/cache + 不从 SystemConfiguration
    ///    继承 proxy (避免 macOS 26 Foundation 内部 "先继承再覆盖" 的合并歧义)
    /// 2. SOCKS proxy 显式 disable —— 避免任何 SOCKS 路径残留
    /// 3. HTTP / HTTPS proxy 同时显式启用 + 指向 Surge —— ponte 流量必走 Surge HTTP CONNECT
    ///
    /// 这条测试是回归防护:有人把 base 改回 `.default` 或忘配 SOCKSEnable=0 会立刻挂
    @Test func pontePoolUsesEphemeralBaseWithExplicitProxyOverrides() {
        let pool = PonteSession.PontePool(proxyHost: "127.0.0.1", proxyPort: 6152)
        let cfg = pool.session.configuration
        // (1) ephemeral 基底:它的 urlCache / httpCookieStorage 都是 nil(或非默认 shared 实例)
        //     —— `.default` 会指向 .shared,`.ephemeral` 会是 nil
        #expect(cfg.httpCookieStorage == nil || cfg.httpCookieStorage !== HTTPCookieStorage.shared,
                "PontePool 不应该用 .default 基底(会继承 shared cookie storage)")
        // (2) SOCKS disabled
        let proxy = cfg.connectionProxyDictionary ?? [:]
        let socksEnable = (proxy["SOCKSEnable"] as? Int)
            ?? (proxy[kCFNetworkProxiesSOCKSEnable as String] as? Int)
        #expect(socksEnable == 0, "SOCKS 必须显式 disable,实际:\(String(describing: socksEnable))")
        // (3) HTTP + HTTPS enable + 指向 Surge
        let httpsEnable = (proxy["HTTPSEnable"] as? Int)
            ?? (proxy[kCFNetworkProxiesHTTPSEnable as String] as? Int)
        let httpEnable = (proxy["HTTPEnable"] as? Int)
            ?? (proxy[kCFNetworkProxiesHTTPEnable as String] as? Int)
        #expect(httpsEnable == 1)
        #expect(httpEnable == 1)
    }
}

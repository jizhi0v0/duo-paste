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
}

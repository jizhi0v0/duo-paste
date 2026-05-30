import Testing
import Foundation
@testable import DuoPasteCore

@Suite("UpdateLogic — Sparkle 自动更新纯逻辑")
struct UpdateLogicTests {

    // MARK: - cacheBustedFeedURL

    @Test("无 query 的 feed 拼上时间戳 _ 参数")
    func cacheBustAppendsTimestamp() throws {
        let out = try #require(UpdateLogic.cacheBustedFeedURL(
            "https://example.com/appcast.xml", epochSeconds: 1_700_000_000
        ))
        #expect(out == "https://example.com/appcast.xml?_=1700000000")
    }

    @Test("已有 query 的 feed 追加而非覆盖")
    func cacheBustPreservesExistingQuery() throws {
        let out = try #require(UpdateLogic.cacheBustedFeedURL(
            "https://example.com/appcast.xml?channel=beta", epochSeconds: 42
        ))
        #expect(out.contains("channel=beta"))
        #expect(out.contains("_=42"))
    }

    @Test("URLComponents 解不出的 base 返 nil")
    func cacheBustInvalidBaseReturnsNil() {
        // 含非法字符（控制字符）URLComponents(string:) 解不出 → nil，调用方放弃 override
        // 走 Sparkle 默认 feed。（空串 / 普通相对路径 URLComponents 都能解，不算非法。）
        #expect(UpdateLogic.cacheBustedFeedURL("http://exa mple.com/\u{7F}appcast", epochSeconds: 1) == nil)
    }

    // MARK: - allowedChannels

    @Test("includePrereleases=true → beta channel")
    func allowedChannelsBeta() {
        #expect(UpdateLogic.allowedChannels(includePrereleases: true) == ["beta"])
    }

    @Test("includePrereleases=false → 空集合（只 stable）")
    func allowedChannelsStable() {
        #expect(UpdateLogic.allowedChannels(includePrereleases: false).isEmpty)
    }

    // MARK: - bundleVersion(fromInfoPlist:)

    @Test("合法 Info.plist 解出 CFBundleVersion")
    func bundleVersionParsesValidPlist() throws {
        let data = try plistData(["CFBundleVersion": "1042", "CFBundleName": "DuoPaste"])
        #expect(UpdateLogic.bundleVersion(fromInfoPlist: data) == "1042")
    }

    @Test("缺 CFBundleVersion 键 → nil")
    func bundleVersionMissingKeyReturnsNil() throws {
        let data = try plistData(["CFBundleName": "DuoPaste"])
        #expect(UpdateLogic.bundleVersion(fromInfoPlist: data) == nil)
    }

    @Test("CFBundleVersion 空串 / 纯空白 → nil")
    func bundleVersionEmptyReturnsNil() throws {
        #expect(UpdateLogic.bundleVersion(fromInfoPlist: try plistData(["CFBundleVersion": ""])) == nil)
        #expect(UpdateLogic.bundleVersion(fromInfoPlist: try plistData(["CFBundleVersion": "   "])) == nil)
    }

    @Test("CFBundleVersion 前后空白被 trim")
    func bundleVersionTrimsWhitespace() throws {
        let data = try plistData(["CFBundleVersion": "  2050\n"])
        #expect(UpdateLogic.bundleVersion(fromInfoPlist: data) == "2050")
    }

    @Test("非 plist 字节 → nil（不崩）")
    func bundleVersionGarbageReturnsNil() {
        #expect(UpdateLogic.bundleVersion(fromInfoPlist: Data("not a plist".utf8)) == nil)
    }

    // MARK: - helpers

    private func plistData(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
}

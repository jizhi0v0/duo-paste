import Testing
import Foundation
@testable import DuoPasteCore

private func tmpConfig(_ json: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    try json.data(using: .utf8)!.write(to: url)
    return url
}

@Test func configMissingFileReturnsDefaults() throws {
    let nonexistent = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-no-config-\(UUID().uuidString).json")
    let cfg = try Config.load(from: nonexistent)
    #expect(cfg == Config.default)
    #expect(cfg.derivedDatabaseRole == .primary)  // standalone == primary 语义
    #expect(cfg.summary == "standalone")
}

@Test func configEmptyJSONUsesDefaults() throws {
    let url = try tmpConfig("{}")
    let cfg = try Config.load(from: url)
    #expect(cfg == Config.default)
}

@Test func configClientMode() throws {
    let url = try tmpConfig("""
    {
        "primary_url": "https://primary.tail.ts.net:8443",
        "shared_secret_keychain_account": "io.duopaste.secret"
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.primaryURL?.absoluteString == "https://primary.tail.ts.net:8443")
    #expect(cfg.derivedDatabaseRole == .client)
    #expect(cfg.capturesNeedPush == true)
    #expect(cfg.summary.hasPrefix("client→"))
}

@Test func configMirrorClientMode() throws {
    let url = try tmpConfig("""
    {
        "primary_url": "https://primary.tail.ts.net:8443",
        "pull": { "enabled": true, "interval_sec": 30, "eager_blobs": false }
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.pull.enabled == true)
    #expect(cfg.summary.hasPrefix("client+mirror→"))
}

@Test func configPrimaryMode() throws {
    let url = try tmpConfig("""
    {
        "serve": true
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.serve == true)
    #expect(cfg.primaryURL == nil)
    #expect(cfg.derivedDatabaseRole == .primary)
    #expect(cfg.summary.hasPrefix("primary @"))
}

@Test func configRejectsServeWithPrimaryURL() throws {
    let url = try tmpConfig("""
    {
        "serve": true,
        "primary_url": "https://other.tail.ts.net:8443"
    }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func configRejectsPullWithoutPrimary() throws {
    let url = try tmpConfig("""
    {
        "pull": { "enabled": true, "interval_sec": 30, "eager_blobs": false }
    }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func configRejectsMalformedJSON() throws {
    let url = try tmpConfig("not json at all {")
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func configRejectsInvalidPrimaryURL() throws {
    // 包含空格的 string 不是合法 URL
    let url = try tmpConfig("""
    { "primary_url": "not a url at all" }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func captureMergeWindowDefaultsTo300() throws {
    let url = try tmpConfig("{}")
    let cfg = try Config.load(from: url)
    #expect(cfg.capture.mergeWindowSec == 300)
}

@Test func captureMergeWindowReadsFromConfig() throws {
    let url = try tmpConfig("""
    { "capture": { "merge_window_sec": 600 } }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.capture.mergeWindowSec == 600)
}

@Test func captureMergeWindowZeroAllowed() throws {
    // 0 = 关闭 merge（任何重复都新插），仍属合法配置
    let url = try tmpConfig("""
    { "capture": { "merge_window_sec": 0 } }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.capture.mergeWindowSec == 0)
}

@Test func captureMergeWindowNegativeRejected() throws {
    let url = try tmpConfig("""
    { "capture": { "merge_window_sec": -1 } }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func configEmptyPrimaryURLStringTreatedAsNil() throws {
    // 用户手抖把 primary_url 留空字符串，应当走默认（standalone），不报错
    let url = try tmpConfig("""
    { "primary_url": "" }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.primaryURL == nil)
    #expect(cfg.derivedDatabaseRole == .primary)
}

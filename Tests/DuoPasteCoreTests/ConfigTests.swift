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

// MARK: - hotkey

@Test func hotkeyDefaultsToOptCmdV() throws {
    let url = try tmpConfig("{}")
    let cfg = try Config.load(from: url)
    #expect(cfg.hotkey.key == "V")
    #expect(Set(cfg.hotkey.modifiers) == Set(["cmd", "option"]))
}

@Test func hotkeyCustomReadsFromConfig() throws {
    let url = try tmpConfig("""
    { "hotkey": { "key": "L", "modifiers": ["cmd", "shift"] } }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.hotkey.key == "L")
    #expect(Set(cfg.hotkey.modifiers) == Set(["cmd", "shift"]))
}

@Test func hotkeyRejectsUnsupportedKey() throws {
    let url = try tmpConfig("""
    { "hotkey": { "key": "F1", "modifiers": ["cmd"] } }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func hotkeyRejectsEmptyModifiers() throws {
    let url = try tmpConfig("""
    { "hotkey": { "key": "V", "modifiers": [] } }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func hotkeyRejectsUnknownModifier() throws {
    let url = try tmpConfig("""
    { "hotkey": { "key": "V", "modifiers": ["fn"] } }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func hotkeyAcceptsModifierAliases() throws {
    let url = try tmpConfig("""
    { "hotkey": { "key": "v", "modifiers": ["command", "alt"] } }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.hotkey.key == "v")  // 不归一化原始字段，由 translate 层 uppercase
    #expect(cfg.hotkey.modifiers == ["command", "alt"])
}

// MARK: - ocr

@Test func ocrDefaultsWhenAbsent() throws {
    let url = try tmpConfig("{}")
    let cfg = try Config.load(from: url)
    #expect(cfg.ocr.enabled == true)
    #expect(cfg.ocr.languages == ["zh-Hans", "en-US"])
    #expect(cfg.ocr.maxBlobMB == 16)
    #expect(cfg.ocr.recognitionLevel == "accurate")
    #expect(cfg.ocr.perItemPauseMs == 100)
}

@Test func ocrRoundtripsAllFields() throws {
    let url = try tmpConfig("""
    {
        "ocr": {
            "enabled": false,
            "languages": ["en-US", "ja-JP"],
            "max_blob_mb": 32,
            "recognition_level": "fast",
            "per_item_pause_ms": 200
        }
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.ocr.enabled == false)
    #expect(cfg.ocr.languages == ["en-US", "ja-JP"])
    #expect(cfg.ocr.maxBlobMB == 32)
    #expect(cfg.ocr.recognitionLevel == "fast")
    #expect(cfg.ocr.perItemPauseMs == 200)
    // 再写出来 + 重读，字段保真
    try Config.write(cfg, to: url)
    let cfg2 = try Config.load(from: url)
    #expect(cfg2.ocr == cfg.ocr)
}

@Test func ocrWritePreservesUnknownNestedFields() throws {
    // 用户/未来给 ocr 子段加 debug_dump、custom_words 等键，write 后仍在
    let url = try tmpConfig("""
    {
        "ocr": {
            "enabled": true,
            "debug_dump": true,
            "custom_words": ["RAII", "k8s"]
        }
    }
    """)
    var cfg = try Config.load(from: url)
    cfg.ocr.maxBlobMB = 24
    try Config.write(cfg, to: url)
    let raw = try Data(contentsOf: url)
    let dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    let ocr = dict["ocr"] as! [String: Any]
    #expect((ocr["debug_dump"] as? Bool) == true)
    #expect((ocr["custom_words"] as? [String]) == ["RAII", "k8s"])
    #expect((ocr["max_blob_mb"] as? Int) == 24)
}

@Test func ocrRejectsInvalidRecognitionLevel() throws {
    let url = try tmpConfig("""
    { "ocr": { "recognition_level": "ultra" } }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func ocrRejectsEmptyLanguages() throws {
    let url = try tmpConfig("""
    { "ocr": { "languages": [] } }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func ocrRejectsZeroMaxBlobMB() throws {
    let url = try tmpConfig("""
    { "ocr": { "max_blob_mb": 0 } }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func hotkeyWritePreservesUnknownNestedFields() throws {
    // hotkey 子 dict 也走 nested merge，未来加 "label" 之类字段不丢
    let url = try tmpConfig("""
    {
        "hotkey": {
            "key": "V",
            "modifiers": ["cmd", "option"],
            "description": "用户起的别名"
        }
    }
    """)
    var cfg = try Config.load(from: url)
    cfg.hotkey = .init(key: "K", modifiers: ["cmd", "shift"])
    try Config.write(cfg, to: url)
    // 重读，未知字段 description 还在
    let raw = try Data(contentsOf: url)
    let dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    let hk = dict["hotkey"] as! [String: Any]
    #expect((hk["description"] as? String) == "用户起的别名")
    #expect((hk["key"] as? String) == "K")
}

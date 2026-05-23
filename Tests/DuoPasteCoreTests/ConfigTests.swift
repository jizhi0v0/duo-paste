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
    #expect(cfg.summary == "standalone")
}

@Test func configEmptyJSONUsesDefaults() throws {
    let url = try tmpConfig("{}")
    let cfg = try Config.load(from: url)
    #expect(cfg == Config.default)
}

@Test func configMeshSinglePeer() throws {
    // 单 peer 部署：本机 serve + 配一个 peer URL。
    // 老 shared_secret_keychain_account 键残留也允许（unknown key 被 decoder 忽略）
    let url = try tmpConfig("""
    {
        "serve": true,
        "peers": [{ "url": "https://other.tail.ts.net:8443" }],
        "shared_secret_keychain_account": "io.duopaste.secret"
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.serve == true)
    #expect(cfg.peers.count == 1)
    #expect(cfg.peers[0].url.absoluteString == "https://other.tail.ts.net:8443")
    #expect(cfg.peers[0].deviceID == nil)
    #expect(cfg.summary.contains("mesh"))
    #expect(cfg.summary.contains("1 peer"))
}

@Test func configMeshMultiPeerWithDeviceIDs() throws {
    // 多 peer 部署：每条带 device_id 走严格模式
    let url = try tmpConfig("""
    {
        "serve": true,
        "peers": [
            { "url": "https://mini.ts.net:8443", "device_id": "mini-device-uuid" },
            { "url": "https://mbp.ts.net:8443", "device_id": "mbp-device-uuid" }
        ]
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.peers.count == 2)
    #expect(cfg.peers[0].deviceID == "mini-device-uuid")
    #expect(cfg.peers[1].deviceID == "mbp-device-uuid")
    #expect(cfg.summary.contains("2 peers"))
}

@Test func configPeerPullURLOptional() throws {
    // pull_url 缺省时 effectivePullURL fallback 到 url
    let url = try tmpConfig("""
    {
        "peers": [{ "url": "https://only-url.tail.ts.net:8443" }]
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.peers[0].pullURL == nil)
    #expect(cfg.peers[0].effectivePullURL.absoluteString == "https://only-url.tail.ts.net:8443")
}

@Test func configPeerPullURLPresent() throws {
    // pull_url 配了 → effectivePullURL 用它，url 留给 WS 等其他路径
    let url = try tmpConfig("""
    {
        "peers": [{
            "url": "https://bobbys-mac-mini.tail.ts.net:8443",
            "pull_url": "https://mac.sgponte:8443"
        }]
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.peers[0].url.absoluteString == "https://bobbys-mac-mini.tail.ts.net:8443")
    #expect(cfg.peers[0].pullURL?.absoluteString == "https://mac.sgponte:8443")
    #expect(cfg.peers[0].effectivePullURL.absoluteString == "https://mac.sgponte:8443")
}

@Test func configPeerPullURLRejectsBogusScheme() throws {
    // pull_url 必须 http/https，scheme 错 → ConfigError.invalidPeerURL
    let url = try tmpConfig("""
    {
        "peers": [{
            "url": "https://valid.tail.ts.net:8443",
            "pull_url": "ftp://wrong-scheme.example:21"
        }]
    }
    """)
    do {
        _ = try Config.load(from: url)
        Issue.record("expected to throw invalidPeerURL")
    } catch {
        // 任意 throw 即可——具体匹配 ConfigError 要看 enum 是否 Equatable，简单起见只验 throw
    }
}

@Test func configStandalonePrimaryMode() throws {
    // 只 serve 不连任何 peer——standalone primary（接受其他人来连，但本机不主动出去）
    let url = try tmpConfig("""
    { "serve": true }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.serve == true)
    #expect(cfg.peers.isEmpty)
    #expect(cfg.summary.hasPrefix("standalone"))
}

@Test func configMeshSegmentDefaults() throws {
    // mesh 段没写 → 全默认值。
    // plan settings-cleanup：内部 tuning 字段大部分从 Config.MeshConfig 撤掉；
    // plan hashed-allen §D §C：cross_device_dedup_window_ns / delete_cascade_enabled
    // 重新引入做回滚口
    let url = try tmpConfig("{}")
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.enabled == true)
    #expect(cfg.mesh.pullIntervalSec == 30)
    #expect(cfg.mesh.wsEnabled == true)
    #expect(cfg.mesh.storageMode == .full)
    #expect(cfg.mesh.crossDeviceDedupWindowNs == 0)
    #expect(cfg.mesh.deleteCascadeEnabled == true)
}

@Test func configMeshSegmentRoundtrip() throws {
    // ws_heartbeat_sec 是老 tuning 键 → unknown key 被 decoder 忽略不报错
    let url = try tmpConfig("""
    {
        "mesh": {
            "enabled": true,
            "pull_interval_sec": 60,
            "ws_enabled": false,
            "storage_mode": "optimized",
            "ws_heartbeat_sec": 45
        }
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.pullIntervalSec == 60)
    #expect(cfg.mesh.wsEnabled == false)
    #expect(cfg.mesh.storageMode == .optimized)
}

/// plan settings-cleanup：老 mesh tuning 字段（pull_batch_limit / *_backoff_sec /
/// clock_skew_warn_ms / ws_reconnect_*_sec / ws_heartbeat_sec / ws_rotation_sec）
/// 从 Config.MeshConfig 撤掉。老 config 残留这些键时 decoder 必须容忍（unknown key
/// 忽略），不能报错让 daemon 启动挂。
/// 注：cross_device_dedup_window_ns 不再是 legacy（plan hashed-allen §D 重新引入）
@Test func configIgnoresLegacyMeshTuningKeys() throws {
    let url = try tmpConfig("""
    {
        "mesh": {
            "enabled": true,
            "pull_interval_sec": 30,
            "pull_batch_limit": 500,
            "pull_initial_backoff_sec": 2,
            "pull_max_backoff_sec": 120,
            "clock_skew_warn_ms": 30000,
            "ws_enabled": true,
            "ws_reconnect_initial_sec": 1,
            "ws_reconnect_max_sec": 60,
            "ws_heartbeat_sec": 30,
            "ws_rotation_sec": 14400
        }
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.enabled == true)
    #expect(cfg.mesh.pullIntervalSec == 30)
    #expect(cfg.mesh.wsEnabled == true)
}

/// 写入路径必须 removeValue 老 tuning 键——升级后 config.json 不残留。
/// 注：cross_device_dedup_window_ns 不再是 legacy（plan hashed-allen §D 重新引入），
/// write 路径会保留并写为正式字段
@Test func configWriteRemovesLegacyMeshTuningKeys() throws {
    let url = try tmpConfig("""
    {
        "mesh": {
            "pull_interval_sec": 30,
            "pull_batch_limit": 500,
            "ws_heartbeat_sec": 30,
            "ws_rotation_sec": 14400
        }
    }
    """)
    let cfg = try Config.load(from: url)
    try Config.write(cfg, to: url)
    let raw = try Data(contentsOf: url)
    let dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    let mesh = dict["mesh"] as! [String: Any]
    for legacy in [
        "pull_batch_limit", "pull_initial_backoff_sec", "pull_max_backoff_sec",
        "clock_skew_warn_ms",
        "ws_reconnect_initial_sec", "ws_reconnect_max_sec",
        "ws_heartbeat_sec", "ws_rotation_sec",
    ] {
        #expect(mesh[legacy] == nil, "legacy key \(legacy) 应已被洗掉")
    }
    // 用户可见字段仍在（含新引入的 cross_device_dedup_window_ns + delete_cascade_enabled）
    #expect(mesh["pull_interval_sec"] as? Int == 30)
    #expect(mesh["cross_device_dedup_window_ns"] as? Int == 0)
    #expect(mesh["delete_cascade_enabled"] as? Bool == true)
}

/// 老 shared_secret_keychain_account 字段同款撤掉（实际从未在启动路径上读，
/// shared-secret 走文件路径）
@Test func configWriteRemovesSharedSecretKeychainAccount() throws {
    let url = try tmpConfig("""
    { "shared_secret_keychain_account": "io.duopaste.secret" }
    """)
    let cfg = try Config.load(from: url)
    try Config.write(cfg, to: url)
    let raw = try Data(contentsOf: url)
    let dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    #expect(dict["shared_secret_keychain_account"] == nil)
}

// MARK: - storage_mode 兼容（plan cloudy-mirroring-walnut §设计决策 老 config 兼容）

@Test func storageModeDefaultsToFull() throws {
    // 既没 storage_mode 也没老 eager_blobs → 默认 .full（mesh 字面语义）
    let url = try tmpConfig("{}")
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.storageMode == .full)
}

@Test func storageModeExplicitOptimized() throws {
    let url = try tmpConfig("""
    { "mesh": { "storage_mode": "optimized" } }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.storageMode == .optimized)
}

@Test func storageModeExplicitFull() throws {
    let url = try tmpConfig("""
    { "mesh": { "storage_mode": "full" } }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.storageMode == .full)
}

@Test func storageModeLegacyEagerBlobsTrueMapsToFull() throws {
    // 老 config 显式 eager_blobs=true → 升级后映射 .full（语义一致）
    let url = try tmpConfig("""
    { "mesh": { "eager_blobs": true } }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.storageMode == .full)
}

@Test func storageModeLegacyEagerBlobsFalseMapsToFull() throws {
    // 老 config 显式 eager_blobs=false（PR cloudy-mirroring-walnut 之前默认）
    // → 升级后映射 .full（默认翻新——「修复后的正确语义」）
    let url = try tmpConfig("""
    { "mesh": { "eager_blobs": false } }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.storageMode == .full)
}

@Test func storageModeNewKeyWinsOverLegacy() throws {
    // 同时存在两个键 → 新键 storage_mode 优先
    let url = try tmpConfig("""
    { "mesh": { "storage_mode": "optimized", "eager_blobs": true } }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.storageMode == .optimized)
}

@Test func storageModeWriteRemovesLegacyEagerBlobs() throws {
    // 写新 config 时洗掉老 eager_blobs 字段
    let url = try tmpConfig("""
    { "mesh": { "eager_blobs": true, "pull_interval_sec": 30 } }
    """)
    var cfg = try Config.load(from: url)
    cfg.mesh.storageMode = .optimized
    try Config.write(cfg, to: url)
    let raw = try Data(contentsOf: url)
    let dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    let mesh = dict["mesh"] as! [String: Any]
    #expect(mesh["eager_blobs"] == nil)
    #expect((mesh["storage_mode"] as? String) == "optimized")
}

@Test func configRejectsDuplicatePeerURLs() throws {
    let url = try tmpConfig("""
    {
        "peers": [
            { "url": "https://a.ts.net:8443" },
            { "url": "https://a.ts.net:8443" }
        ]
    }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func configRejectsDuplicatePeerDeviceIDs() throws {
    let url = try tmpConfig("""
    {
        "peers": [
            { "url": "https://a.ts.net:8443", "device_id": "X" },
            { "url": "https://b.ts.net:8443", "device_id": "X" }
        ]
    }
    """)
    #expect(throws: ConfigError.self) {
        _ = try Config.load(from: url)
    }
}

@Test func configRejectsInvalidPeerURL() throws {
    let url = try tmpConfig("""
    { "peers": [{ "url": "not a url at all" }] }
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

@Test func configWriteRemovesLegacyKeys() throws {
    // 老 config.json 含 primary_url + pull 字段，write 必须显式 removeValue 这两 key——
    // 否则升级后 daemon 启动看到两套字段共存（虽然代码忽略，但用户读 config 困惑）
    let url = try tmpConfig("""
    {
        "primary_url": "https://old.ts.net:8443",
        "pull": { "enabled": true, "interval_sec": 30 },
        "serve": false
    }
    """)
    var cfg = try Config.load(from: url)
    cfg.peers = [Config.PeerConfig(url: URL(string: "https://new.ts.net:8443")!)]
    cfg.serve = true
    try Config.write(cfg, to: url)
    let raw = try Data(contentsOf: url)
    let dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    #expect(dict["primary_url"] == nil)
    #expect(dict["pull"] == nil)
    #expect(dict["peers"] != nil)
    #expect(dict["mesh"] != nil)
    let peersArr = dict["peers"] as! [[String: Any]]
    #expect(peersArr.count == 1)
    #expect(peersArr[0]["url"] as? String == "https://new.ts.net:8443")
}

@Test func configWriteMeshSegmentNestedMerge() throws {
    // mesh 段 nested merge——用户/未来加的未知字段不丢
    let url = try tmpConfig("""
    {
        "mesh": {
            "enabled": true,
            "pull_interval_sec": 30,
            "future_field": "preserved",
            "debug_dump": true
        }
    }
    """)
    var cfg = try Config.load(from: url)
    cfg.mesh.pullIntervalSec = 60
    try Config.write(cfg, to: url)
    let raw = try Data(contentsOf: url)
    let dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    let mesh = dict["mesh"] as! [String: Any]
    #expect((mesh["future_field"] as? String) == "preserved")
    #expect((mesh["debug_dump"] as? Bool) == true)
    #expect((mesh["pull_interval_sec"] as? Int) == 60)
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

@Test func configIgnoresUnknownLegacyPrimaryURLKey() throws {
    // PR 5 删了 primary_url 字段——老 config.json 里残留这个 key 时
    // Config.load 应当忽略（unknown key），不报错。peers 仍走默认空数组。
    let url = try tmpConfig("""
    { "primary_url": "https://old.ts.net:8443" }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.peers.isEmpty)  // primary_url 不被映射成 peer
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

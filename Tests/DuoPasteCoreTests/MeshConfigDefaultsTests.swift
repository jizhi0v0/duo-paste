import Testing
import Foundation
@testable import DuoPasteCore

// plan hashed-allen §D §C：MeshConfig 新增的两个 feature flag 默认值锁死。
// 防未来误改 default 让 cascade 删除 / cross-device dedup 行为悄悄翻转。

private func tmpConfig(_ json: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    try json.data(using: .utf8)!.write(to: url)
    return url
}

@Test func meshConfigDefaultsCrossDeviceDedupOff() {
    // default 必须是 0——cross-device 副本进 mirror，UI 靠 fold 兜底。
    // cascade 删除依赖两台机器行集合对称
    #expect(Config.MeshConfig.default.crossDeviceDedupWindowNs == 0)
}

@Test func meshConfigDefaultsCascadeOn() {
    // default 必须 true——删一条 = 三端 fold group 全部 tombstone
    #expect(Config.MeshConfig.default.deleteCascadeEnabled == true)
}

@Test func meshConfigOldJSONFallsBackToNewDefaults() throws {
    // 老 config.json（无新字段）decode 后应 fallback 到 default
    let url = try tmpConfig("""
    {
        "mesh": {
            "enabled": true,
            "pull_interval_sec": 30,
            "ws_enabled": true,
            "storage_mode": "full"
        }
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.crossDeviceDedupWindowNs == 0)
    #expect(cfg.mesh.deleteCascadeEnabled == true)
}

@Test func meshConfigExplicitOverrideRoundtrip() throws {
    // 用户显式回滚（5s dedup + cascade off）必须正确 decode
    let url = try tmpConfig("""
    {
        "mesh": {
            "cross_device_dedup_window_ns": 5000000000,
            "delete_cascade_enabled": false
        }
    }
    """)
    let cfg = try Config.load(from: url)
    #expect(cfg.mesh.crossDeviceDedupWindowNs == 5_000_000_000)
    #expect(cfg.mesh.deleteCascadeEnabled == false)
    // write 后能 round-trip 不丢值
    try Config.write(cfg, to: url)
    let raw = try Data(contentsOf: url)
    let dict = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    let mesh = dict["mesh"] as! [String: Any]
    #expect(mesh["cross_device_dedup_window_ns"] as? Int == 5_000_000_000)
    #expect(mesh["delete_cascade_enabled"] as? Bool == false)
}

import Testing
import Foundation
@testable import DuoPasteCore

/// PR 5 mesh-init 子命令的纯函数实现 (`Admin.meshInit`)：daemon guard /
/// blob 缺失预检 / dry-run / config 写入 + 老字段清理 / nested merge 保未知字段。

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-mesh-init-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeConfig(_ json: String, to dir: URL) throws -> URL {
    let path = dir.appendingPathComponent("config.json")
    try json.data(using: .utf8)!.write(to: path)
    return path
}

private func makeBlobs(at dir: URL) throws -> BlobStore {
    let root = dir.appendingPathComponent("blobs")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BlobStore(root: root)
}

private func makeEmptyDB(at dir: URL) throws -> URL {
    let dbDir = dir.appendingPathComponent("db")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let dbPath = dbDir.appendingPathComponent("main.sqlite")
    _ = try Database(path: dbPath)   // 跑 migration 建空表
    return dbPath
}

@Test func meshInitRefusesWhenDaemonRunning() throws {
    let dir = tempDir()
    let cfg = try writeConfig("{}", to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.meshInit(
            configPath: cfg, dbPath: dbPath, blobs: blobs,
            peerURLs: [URL(string: "https://x.ts.net:8443")!],
            daemonRunning: true,
            daemonLabel: "io.duopaste.agent"
        )
    }
}

@Test func meshInitProceedsWhenDaemonStopped() throws {
    let dir = tempDir()
    let cfg = try writeConfig("{}", to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let result = try Admin.meshInit(
        configPath: cfg, dbPath: dbPath, blobs: blobs,
        peerURLs: [URL(string: "https://x.ts.net:8443")!],
        daemonRunning: false,
        daemonLabel: "io.duopaste.agent"
    )
    #expect(result.dryRun == false)
    #expect(result.peerURLs.count == 1)
    let written = try Data(contentsOf: cfg)
    let dict = try JSONSerialization.jsonObject(with: written) as! [String: Any]
    #expect((dict["serve"] as? Bool) == true)
    let peers = dict["peers"] as! [[String: Any]]
    #expect(peers.count == 1)
    #expect(peers[0]["url"] as? String == "https://x.ts.net:8443")
}

@Test func meshInitDryRunDoesNotWriteConfig() throws {
    let dir = tempDir()
    let original = "{\"serve\": false}"
    let cfg = try writeConfig(original, to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let result = try Admin.meshInit(
        configPath: cfg, dbPath: dbPath, blobs: blobs,
        peerURLs: [URL(string: "https://x.ts.net:8443")!],
        dryRun: true,
        daemonRunning: false,
        daemonLabel: "io.duopaste.agent"
    )
    #expect(result.dryRun == true)
    let after = String(data: try Data(contentsOf: cfg), encoding: .utf8)
    #expect(after == original)
}

@Test func meshInitRefusesWhenBlobsMissingByDefault() throws {
    // item 表里有 blob_sha256 但 BlobStore 没字节 → throw missingBlobs
    let dir = tempDir()
    let cfg = try writeConfig("{}", to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let db = try Database(path: dbPath)
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, kind,
                              blob_sha256, pinned)
            VALUES ('img-no-bytes', 'self', 100, 'image',
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                    0)
        """)
    }
    let blobs = try makeBlobs(at: dir)   // 空 BlobStore，sha 找不到
    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.meshInit(
            configPath: cfg, dbPath: dbPath, blobs: blobs,
            peerURLs: [URL(string: "https://x.ts.net:8443")!],
            daemonRunning: false,
            daemonLabel: "io.duopaste.agent"
        )
    }
}

@Test func meshInitWithAllowMissingBlobsContinues() throws {
    let dir = tempDir()
    let cfg = try writeConfig("{}", to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let db = try Database(path: dbPath)
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, kind, blob_sha256, pinned)
            VALUES ('img-no-bytes', 'self', 100, 'image',
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                    0)
        """)
    }
    let blobs = try makeBlobs(at: dir)
    let result = try Admin.meshInit(
        configPath: cfg, dbPath: dbPath, blobs: blobs,
        peerURLs: [URL(string: "https://x.ts.net:8443")!],
        allowMissingBlobs: true,
        daemonRunning: false,
        daemonLabel: "io.duopaste.agent"
    )
    #expect(result.missingBlobsTotal == 1)
    #expect(result.missingBlobsSamples.count == 1)
}

@Test func meshInitTombstoneBlobsNotMissingChecked() throws {
    // 软删的 image 行不计入 missing blob 检查（plan §"promoteToPrimary 不变量 #8"）
    let dir = tempDir()
    let cfg = try writeConfig("{}", to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let db = try Database(path: dbPath)
    try db.pool.write { conn in
        try conn.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, kind,
                              blob_sha256, pinned, deleted_at_ns)
            VALUES ('img-tombstone', 'self', 100, 'image',
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                    0, 200)
        """)
    }
    let blobs = try makeBlobs(at: dir)
    // 不抛——deleted_at_ns 非空被排除
    let result = try Admin.meshInit(
        configPath: cfg, dbPath: dbPath, blobs: blobs,
        peerURLs: [URL(string: "https://x.ts.net:8443")!],
        daemonRunning: false,
        daemonLabel: "io.duopaste.agent"
    )
    #expect(result.missingBlobsTotal == 0)
}

@Test func meshInitRemovesLegacyKeysFromConfig() throws {
    // 老 config 含 primary_url + pull → mesh-init 写完后这两 key 消失
    let dir = tempDir()
    let cfg = try writeConfig("""
    {
        "primary_url": "https://old.ts.net:8443",
        "pull": { "enabled": true, "interval_sec": 30 },
        "serve": false
    }
    """, to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let result = try Admin.meshInit(
        configPath: cfg, dbPath: dbPath, blobs: blobs,
        peerURLs: [URL(string: "https://new.ts.net:8443")!],
        daemonRunning: false,
        daemonLabel: "io.duopaste.agent"
    )
    #expect(result.removedLegacyKeys.contains("primary_url"))
    #expect(result.removedLegacyKeys.contains("pull"))
    let written = try Data(contentsOf: cfg)
    let dict = try JSONSerialization.jsonObject(with: written) as! [String: Any]
    #expect(dict["primary_url"] == nil)
    #expect(dict["pull"] == nil)
}

@Test func meshInitMultiPeerWithDeviceIDs() throws {
    let dir = tempDir()
    let cfg = try writeConfig("{}", to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let result = try Admin.meshInit(
        configPath: cfg, dbPath: dbPath, blobs: blobs,
        peerURLs: [
            URL(string: "https://a.ts.net:8443")!,
            URL(string: "https://b.ts.net:8443")!,
        ],
        peerDeviceIDs: ["a-id", "b-id"],
        daemonRunning: false,
        daemonLabel: "io.duopaste.agent"
    )
    #expect(result.peerURLs.count == 2)
    let dict = try JSONSerialization.jsonObject(with: try Data(contentsOf: cfg)) as! [String: Any]
    let peers = dict["peers"] as! [[String: Any]]
    #expect(peers.count == 2)
    #expect(peers[0]["device_id"] as? String == "a-id")
    #expect(peers[1]["device_id"] as? String == "b-id")
}

@Test func meshInitWritesTLSFieldsWhenServeTLSGiven() throws {
    let dir = tempDir()
    let cfg = try writeConfig("{}", to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    // 准备假 cert / key 文件（内容不需是真 PEM，meshInit 只查文件存在）
    let certPath = dir.appendingPathComponent("test.crt").path
    let keyPath = dir.appendingPathComponent("test.key").path
    try "fake cert".data(using: .utf8)!.write(to: URL(fileURLWithPath: certPath))
    try "fake key".data(using: .utf8)!.write(to: URL(fileURLWithPath: keyPath))

    _ = try Admin.meshInit(
        configPath: cfg, dbPath: dbPath, blobs: blobs,
        peerURLs: [URL(string: "https://x.ts.net:8443")!],
        serveTLS: true, tlsCertPath: certPath, tlsKeyPath: keyPath,
        daemonRunning: false,
        daemonLabel: "io.duopaste.agent"
    )
    let written = try Data(contentsOf: cfg)
    let dict = try JSONSerialization.jsonObject(with: written) as! [String: Any]
    #expect((dict["serve_tls"] as? Bool) == true)
    #expect((dict["tls_cert_path"] as? String) == certPath)
    #expect((dict["tls_key_path"] as? String) == keyPath)
}

@Test func meshInitRefusesServeTLSWithoutCertAndKey() throws {
    let dir = tempDir()
    let cfg = try writeConfig("{}", to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    // 没传 cert/key 也没在 oldConfig 里 → throw writeConfigFailed
    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.meshInit(
            configPath: cfg, dbPath: dbPath, blobs: blobs,
            peerURLs: [URL(string: "https://x.ts.net:8443")!],
            serveTLS: true,
            daemonRunning: false,
            daemonLabel: "io.duopaste.agent"
        )
    }
}

@Test func meshInitRefusesServeTLSWhenCertFileMissing() throws {
    let dir = tempDir()
    let cfg = try writeConfig("{}", to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    let certPath = "/does/not/exist.crt"
    let keyPath = dir.appendingPathComponent("test.key").path
    try "fake key".data(using: .utf8)!.write(to: URL(fileURLWithPath: keyPath))
    #expect(throws: Admin.AdminError.self) {
        _ = try Admin.meshInit(
            configPath: cfg, dbPath: dbPath, blobs: blobs,
            peerURLs: [URL(string: "https://x.ts.net:8443")!],
            serveTLS: true, tlsCertPath: certPath, tlsKeyPath: keyPath,
            daemonRunning: false,
            daemonLabel: "io.duopaste.agent"
        )
    }
}

@Test func meshInitInheritsTLSFromOldConfigWhenNotGiven() throws {
    // oldConfig 已经有 serve_tls + cert/key（之前手动配过 / 老 promote 留下）
    // → mesh-init 不传 --serve-tls 时应当**沿用**老值，而不是默 false
    let dir = tempDir()
    let certPath = dir.appendingPathComponent("inherit.crt").path
    let keyPath = dir.appendingPathComponent("inherit.key").path
    try "c".data(using: .utf8)!.write(to: URL(fileURLWithPath: certPath))
    try "k".data(using: .utf8)!.write(to: URL(fileURLWithPath: keyPath))
    let cfg = try writeConfig("""
    {
        "serve": true,
        "serve_tls": true,
        "tls_cert_path": "\(certPath)",
        "tls_key_path": "\(keyPath)"
    }
    """, to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    _ = try Admin.meshInit(
        configPath: cfg, dbPath: dbPath, blobs: blobs,
        peerURLs: [URL(string: "https://x.ts.net:8443")!],
        // serveTLS / tlsCertPath / tlsKeyPath 都不传
        daemonRunning: false,
        daemonLabel: "io.duopaste.agent"
    )
    let after = try Config.load(from: cfg)
    #expect(after.serveTLS == true)
    #expect(after.tlsCertPath == certPath)
    #expect(after.tlsKeyPath == keyPath)
}

@Test func meshInitPreservesUnrelatedConfigFields() throws {
    // hotkey / capture / ocr / shared_secret_keychain_account 不动
    let dir = tempDir()
    let cfg = try writeConfig("""
    {
        "hotkey": { "key": "K", "modifiers": ["cmd", "shift"] },
        "capture": { "max_blob_mb": 64, "max_text_kb": 1024 },
        "ocr": { "enabled": false, "languages": ["zh-Hans"] },
        "shared_secret_keychain_account": "io.duopaste.secret"
    }
    """, to: dir)
    let dbPath = try makeEmptyDB(at: dir)
    let blobs = try makeBlobs(at: dir)
    _ = try Admin.meshInit(
        configPath: cfg, dbPath: dbPath, blobs: blobs,
        peerURLs: [URL(string: "https://x.ts.net:8443")!],
        daemonRunning: false,
        daemonLabel: "io.duopaste.agent"
    )
    let after = try Config.load(from: cfg)
    #expect(after.hotkey.key == "K")
    #expect(Set(after.hotkey.modifiers) == Set(["cmd", "shift"]))
    #expect(after.capture.maxBlobBytes == 64 * 1024 * 1024)
    #expect(after.capture.maxTextBytes == 1024 * 1024)
    #expect(after.ocr.enabled == false)
    #expect(after.ocr.languages == ["zh-Hans"])
    #expect(after.sharedSecretKeychainAccount == "io.duopaste.secret")
}

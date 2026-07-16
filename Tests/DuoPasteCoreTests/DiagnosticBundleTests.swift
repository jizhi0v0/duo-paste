import Foundation
import GRDB
import Testing
@testable import DuoPasteCore

@Test func diagnosticBundleIsAllowlistedAndContainsNoContentOrSecrets() async throws {
    let sentinelText = "CLIPBOARD-SENTINEL-8f26c9"
    let sentinelBlob = "BLOB-SENTINEL-2e17aa"
    let sentinelSecret = "SECRET-SENTINEL-6d31f0"
    let sentinelPrivateKey = "PRIVATE-KEY-SENTINEL-c8a441"
    let sentinelCredential = "dpc1.Q1JFREVOVElBTC1TRU5USU5FTC03YzQx"

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-diagnostics-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(root: root.appendingPathComponent("data", isDirectory: true))
    paths.ensureExists()
    let database = try Database(path: paths.mainDB)
    try await database.pool.write { db in
        try db.execute(sql: """
            INSERT INTO item (id, origin_device, captured_at_ns, kind, preview, text_full, pinned)
            VALUES ('sensitive-item', 'self', 1, 'text', ?, ?, 0)
        """, arguments: [sentinelText, sentinelText])
    }
    let blobFile = paths.blobsDir.appendingPathComponent("raw-sensitive-blob")
    try Data(sentinelBlob.utf8).write(to: blobFile)
    try Data((sentinelSecret + "\n").utf8).write(to: paths.sharedSecretFile)
    let keyFile = paths.root.appendingPathComponent("server.key")
    try Data(("-----BEGIN PRIVATE KEY-----\n" + sentinelPrivateKey).utf8).write(to: keyFile)

    let logFile = root.appendingPathComponent("duo-pasted.err.log")
    try Data("""
        pull: tick applied=2 hasMore=false
        pull: auth X-DP-Credential: (sentinelCredential)
        pull: peer=https://operator:\(sentinelSecret)@peer.example:8443 unreachable
        capture suspect kind=text preview=\(sentinelText)
        arbitrary line carrying \(sentinelBlob)
        """.utf8).write(to: logFile)

    var config = Config.default
    config.serveTLS = true
    config.tlsCertPath = "/safe/public.crt"
    config.tlsKeyPath = keyFile.path
    config.peers = [Config.PeerConfig(
        url: URL(string: "https://operator:\(sentinelSecret)@peer.example:8443")!,
        deviceID: "peer"
    )]

    let doctor = try await Admin.meshDoctor(
        selfDeviceID: "self",
        peers: [],
        dbPath: paths.mainDB,
        blobs: BlobStore(root: paths.blobsDir),
        healthProbe: { _ in .unreachable(reason: "unused") }
    )
    let output = root.appendingPathComponent("bundle", isDirectory: true)
    let result = try DiagnosticBundleExporter.export(
        to: output,
        config: config,
        meshDoctorReport: doctor,
        databasePath: paths.mainDB,
        logFiles: [logFile],
        version: .init(
            appVersion: "1.2.3",
            buildVersion: "456",
            osVersion: "testOS",
            architecture: "arm64"
        ),
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(Set(result.relativeFiles) == [
        "config.redacted.json",
        "logs/duo-pasted.err.log",
        "manifest.json",
        "mesh-doctor.json",
        "quick-check.json",
        "version.json",
    ])

    var allBytes = Data()
    for relative in result.relativeFiles {
        allBytes.append(try Data(contentsOf: output.appendingPathComponent(relative)))
    }
    let all = String(decoding: allBytes, as: UTF8.self)
    #expect(!all.contains(sentinelText))
    #expect(!all.contains(sentinelBlob))
    #expect(!all.contains(sentinelSecret))
    #expect(!all.contains(sentinelPrivateKey))
    #expect(!all.contains(sentinelCredential))
    #expect(!all.contains("BEGIN PRIVATE KEY"))
    #expect(all.contains("pull: tick applied=2 hasMore=false"))
    #expect(all.contains("redacted non-operational log line"))
    #expect(all.contains("\"result\" : \"ok\"") || all.contains("\"result\":\"ok\""))

    let bundleAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
    #expect((bundleAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let logsAttributes = try FileManager.default.attributesOfItem(
        atPath: output.appendingPathComponent("logs").path
    )
    #expect((logsAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    for relative in result.relativeFiles {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: output.appendingPathComponent(relative).path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

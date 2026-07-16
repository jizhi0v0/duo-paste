import Foundation
import Testing
@testable import DuoPasteCore

private func documentedConfig(named name: String) throws -> Config {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let guideURL = repositoryRoot.appendingPathComponent("docs/deploy-multi-mac.md")
    let guide = try String(contentsOf: guideURL, encoding: .utf8)
    let startMarker = "<!-- config-contract:\(name):start -->"
    let endMarker = "<!-- config-contract:\(name):end -->"

    guard let start = guide.range(of: startMarker),
          let end = guide.range(of: endMarker, range: start.upperBound..<guide.endIndex)
    else {
        Issue.record("missing documentation contract markers for \(name)")
        throw CocoaError(.fileReadCorruptFile)
    }

    let section = guide[start.upperBound..<end.lowerBound]
    guard let fenceStart = section.range(of: "```json"),
          let fenceEnd = section.range(
            of: "```",
            range: fenceStart.upperBound..<section.endIndex
          )
    else {
        Issue.record("missing JSON fence for documented config \(name)")
        throw CocoaError(.fileReadCorruptFile)
    }

    let json = String(section[fenceStart.upperBound..<fenceEnd.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-doc-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config.json")
    try Data(json.utf8).write(to: configURL)
    return try Config.load(from: configURL)
}

@Test func deploymentGuideConfigExamplesDecodeAndPointAtEachOther() throws {
    let macA = try documentedConfig(named: "mac-a")
    let macB = try documentedConfig(named: "mac-b")

    for config in [macA, macB] {
        #expect(config.serve)
        #expect(config.serveHost == "0.0.0.0")
        #expect(config.servePort == 8443)
        #expect(config.serveTLS == false)
        #expect(config.peers.count == 1)
        #expect(config.mesh.enabled)
        #expect(config.mesh.pullIntervalSec == 30)
        #expect(config.mesh.storageMode == .full)
        #expect(config.mesh.wsEnabled)
        #expect(config.mesh.crossDeviceDedupWindowNs == 0)
        #expect(config.mesh.deleteCascadeEnabled)
    }

    #expect(macA.peers[0].url.host == "mac-b.example-tailnet.ts.net")
    #expect(macA.peers[0].deviceID == "22222222-2222-4222-8222-222222222222")
    #expect(macB.peers[0].url.host == "mac-a.example-tailnet.ts.net")
    #expect(macB.peers[0].deviceID == "11111111-1111-4111-8111-111111111111")
}

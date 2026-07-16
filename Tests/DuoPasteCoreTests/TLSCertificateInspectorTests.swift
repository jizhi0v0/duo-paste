import Foundation
import Testing
@testable import DuoPasteCore

private let dualSANCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIDEzCCAfugAwIBAgIUMTbdZJ6WQ2vDJeN1rQt4+jt01jQwDQYJKoZIhvcNAQEL
BQAwFzEVMBMGA1UEAwwMdGVzdC1maXh0dXJlMB4XDTI2MDUyNDEyMDkyMVoXDTI3
MDUyNDEyMDkyMVowFzEVMBMGA1UEAwwMdGVzdC1maXh0dXJlMIIBIjANBgkqhkiG
9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxvGnlm0FvmJdkHg6uWbCaXZFuCkVVqBFGFp/
Lw7SokSH5cLbqdvBMOHaEDwB1zIrZrX3yV012myTv6HLF6Ggq98xBNjIwB04m/rn
wnwfSHaq49Z+W/zhn+0KzspqG6H8Fz5P2AVk0jkXg0Z5fGz8TI6j6lj7/cblwbHE
fSqi4Tpf7GokZJBWBc/MK1hixcJ/ggNgs+dXg/NMhTwiB6AwAa1JlHl6UNwGzcuZ
SofvPgaTj3p4g80TpUE0qFHQ9lQCWY+aMmaFG0feEgn0C2lvNLXnFRKaU4yRLXLj
p54uAshPVmu1IBEzaC7za2QPzqnZczMRnQF6ZLL45Dvla+Pu0QIDAQABo1cwVTA0
BgNVHREELTArght0ZXN0LWhvc3QudGFpbDY5NzMwYS50cy5uZXSCDHRlc3Quc2dw
b250ZTAdBgNVHQ4EFgQUwDT9utKXQxcnMtr7yFrKdbfSKMUwDQYJKoZIhvcNAQEL
BQADggEBAIz7OeklczlbRAJoOmVpxF6ytNZM/++ZC/ZMdqmmsu5hHPB6wdCoeT37
imSwgs+jgGkhEaNe6qO0YX+xQLOGm2XLD+tHyceqq5Ciyy/6pDcDSSulyHLnPUsz
0wqYAAGs0IGpMpgvRTnsZ0KQclYiUeTOr0/jjN/0LX+hG73Mfeby+2riWnvg9NC4
FCjZZy8im2KkwX9ZZiZsbd4eC/o5cwlhoNwOHh83fYibbPtLWL2W2OUbnyqPi9sq
f7+QTm82rBVDUtofdFQnflZmk6Ux7MnmFbyLesM6fwLYzeFTJdeFLLyKSBwAjSP2
r8xQHTQCyZTOcZgTeGLiRSSzM7Cxaf8=
-----END CERTIFICATE-----
"""

private func writeCertificateFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-tls-fixture-\(UUID().uuidString).crt")
    try dualSANCertificatePEM.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func tlsInspectorReadsLeafSANAndValidity() throws {
    let fixture = try writeCertificateFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let report = try TLSCertificateInspector.inspect(
        at: fixture,
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    #expect(report.dnsSANs == ["test-host.tail69730a.ts.net", "test.sgponte"])
    #expect(report.notBefore < report.notAfter)
    #expect(report.certificateFilename.hasSuffix(".crt"))
}

@Test func pairingLeafPinUsesTheActualDERFromPEMAndRejectsAnotherLeaf() throws {
    let pem = Data(dualSANCertificatePEM.utf8)
    let leafDER = try PairingCertificatePin.certificateDER(from: pem)
    let expected = PairingCertificatePin.sha256Hex(certificateDER: leafDER)
    var attackerLeaf = leafDER
    attackerLeaf[attackerLeaf.count / 2] ^= 0x01

    #expect(PairingCertificatePin.matches(
        expectedSHA256: expected,
        presentedCertificateDER: leafDER
    ))
    #expect(!PairingCertificatePin.matches(
        expectedSHA256: expected,
        presentedCertificateDER: attackerLeaf
    ))
}

@Test func tlsExpiryThresholdsUseInclusiveThirtySevenOneDayBoundaries() throws {
    let fixture = try writeCertificateFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let parsed = try TLSCertificateInspector.inspect(at: fixture)
    let day: TimeInterval = 86_400

    #expect(TLSCertificateInspector.classify(
        notBefore: parsed.notBefore,
        notAfter: parsed.notAfter,
        now: parsed.notAfter.addingTimeInterval(-31 * day)
    ) == .valid)
    #expect(TLSCertificateInspector.classify(
        notBefore: parsed.notBefore,
        notAfter: parsed.notAfter,
        now: parsed.notAfter.addingTimeInterval(-30 * day)
    ) == .expiresWithin30Days)
    #expect(TLSCertificateInspector.classify(
        notBefore: parsed.notBefore,
        notAfter: parsed.notAfter,
        now: parsed.notAfter.addingTimeInterval(-7 * day)
    ) == .expiresWithin7Days)
    #expect(TLSCertificateInspector.classify(
        notBefore: parsed.notBefore,
        notAfter: parsed.notAfter,
        now: parsed.notAfter.addingTimeInterval(-day)
    ) == .expiresWithin1Day)
    #expect(TLSCertificateInspector.classify(
        notBefore: parsed.notBefore,
        notAfter: parsed.notAfter,
        now: parsed.notAfter
    ) == .expired)
    #expect(TLSCertificateInspector.classify(
        notBefore: parsed.notBefore,
        notAfter: parsed.notAfter,
        now: parsed.notBefore.addingTimeInterval(-1)
    ) == .notYetValid)
}

@Test func meshDoctorJSONIncludesTLSCertificateState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-doctor-json-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(root: root)
    paths.ensureExists()
    _ = try Database(path: paths.mainDB)
    let fixture = try writeCertificateFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let cert = try TLSCertificateInspector.inspect(
        at: fixture,
        now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let report = try await Admin.meshDoctor(
        selfDeviceID: "doctor-self",
        peers: [],
        dbPath: paths.mainDB,
        blobs: BlobStore(root: paths.blobsDir),
        healthProbe: { _ in .unreachable(reason: "unused") },
        tlsCertificate: .inspected(cert)
    )
    let data = try Admin.encodeMeshDoctorJSON(report)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let tls = try #require(object["tls_certificate"] as? [String: Any])
    #expect(tls["state"] as? String == "inspected")
    let leaf = try #require(tls["leaf"] as? [String: Any])
    #expect(leaf["expiry_status"] as? String == cert.expiryStatus.rawValue)
    #expect(!Admin.meshDoctorHasIssues(report))
}

@Test func meshDoctorTreatsThirtyDayCertificateWarningAsIssue() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-doctor-cert-warning-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = Paths(root: root)
    paths.ensureExists()
    _ = try Database(path: paths.mainDB)
    let fixture = try writeCertificateFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let baseline = try TLSCertificateInspector.inspect(at: fixture)
    let warning = try TLSCertificateInspector.inspect(
        at: fixture,
        now: baseline.notAfter.addingTimeInterval(-30 * 86_400)
    )
    let report = try await Admin.meshDoctor(
        selfDeviceID: "doctor-self",
        peers: [],
        dbPath: paths.mainDB,
        blobs: BlobStore(root: paths.blobsDir),
        healthProbe: { _ in .unreachable(reason: "unused") },
        tlsCertificate: .inspected(warning)
    )
    #expect(warning.expiryStatus == .expiresWithin30Days)
    #expect(Admin.meshDoctorHasIssues(report))
}

import Foundation
import Testing
@testable import DuoPasteCore

@Test func pairingLeafPinRejectsAttackerCertificateBeforeCredentialExchange() throws {
    let legitimateLeaf = Data((0..<512).map { UInt8($0 % 251) })
    var attackerLeaf = legitimateLeaf
    attackerLeaf[127] ^= 0xFF

    let expected = PairingCertificatePin.sha256Hex(certificateDER: legitimateLeaf)
    #expect(PairingCertificatePin.matches(
        expectedSHA256: expected,
        presentedCertificateDER: legitimateLeaf
    ))
    #expect(!PairingCertificatePin.matches(
        expectedSHA256: expected,
        presentedCertificateDER: attackerLeaf
    ))
}

@Test func pairingQRV2RoundTripContainsOnlyEndpointAndLeafPin() throws {
    let leaf = Data("legitimate-leaf".utf8)
    let expected = PairingCertificatePin.sha256Hex(certificateDER: leaf)
    let payload = try PairingQRPayload.bound(
        host: "mac-a.example-tailnet.ts.net",
        port: 8443,
        certificateSHA256: expected.uppercased()
    )
    let encoded = try payload.encodedData()
    let raw = try #require(String(data: encoded, encoding: .utf8))
    let decoded = try PairingQRPayload.parse(raw)

    #expect(decoded.version == 2)
    #expect(decoded.tls)
    #expect(decoded.certificateSHA256 == expected)
    #expect(decoded.isChannelBound)
    #expect(!raw.contains("pin"))
    #expect(!raw.contains("secret"))
    #expect(!raw.contains("token"))
}

@Test func pairingQRRejectsLegacyHTTPAndMalformedPinsForChannelBinding() throws {
    let legacy = #"{"host":"old-mac.local","port":8443,"tls":true,"v":1}"#
    let decodedLegacy = try PairingQRPayload.parse(legacy)
    #expect(!decodedLegacy.isChannelBound)
    #expect(throws: PairingQRPayload.ValidationError.self) {
        _ = try decodedLegacy.requireChannelBinding()
    }
    #expect(throws: PairingQRPayload.ValidationError.self) {
        _ = try PairingQRPayload.bound(
            host: "mac.local",
            port: 8443,
            certificateSHA256: "not-a-fingerprint"
        )
    }

    let insecure = #"{"host":"mac.local","port":8443,"tls":false,"v":2,"cert_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
    let decodedInsecure = try PairingQRPayload.parse(insecure)
    #expect(!decodedInsecure.isChannelBound)
    #expect(throws: PairingQRPayload.ValidationError.self) {
        _ = try decodedInsecure.requireChannelBinding()
    }
}

@Test func pairingLeafRotationInvalidatesOldQRWithoutChangingCredentialMaterial() throws {
    let oldLeaf = Data("old-leaf".utf8)
    let newLeaf = Data("new-leaf".utf8)
    let oldPin = PairingCertificatePin.sha256Hex(certificateDER: oldLeaf)
    let newPin = PairingCertificatePin.sha256Hex(certificateDER: newLeaf)
    let existingCredentialSecret = Data(repeating: 0xA5, count: 32)

    #expect(!PairingCertificatePin.matches(
        expectedSHA256: oldPin,
        presentedCertificateDER: newLeaf
    ))
    #expect(PairingCertificatePin.matches(
        expectedSHA256: newPin,
        presentedCertificateDER: newLeaf
    ))
    #expect(existingCredentialSecret == Data(repeating: 0xA5, count: 32))
}

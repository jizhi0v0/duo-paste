import CryptoKit
import Foundation
import Security

/// iOS onboarding 的 TLS leaf SHA-256 pin。QR 中只放 hex digest；实际握手时对
/// `SecCertificateCopyData(leaf)` 返回的 DER 做同一计算并常量时间比较。
public enum PairingCertificatePin {
    public enum PinError: Error, Equatable, Sendable {
        case invalidCertificateData
    }

    public static func sha256Hex(certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
    }

    /// 读取 PEM chain 的第一张 certificate（leaf）；非 PEM 输入按 DER 原样返回。
    public static func certificateDER(from fileData: Data) throws -> Data {
        if let text = String(data: fileData, encoding: .ascii),
           let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
           let end = text.range(
               of: "-----END CERTIFICATE-----",
               range: begin.upperBound..<text.endIndex
           ) {
            let body = text[begin.upperBound..<end.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            guard let der = Data(base64Encoded: body), !der.isEmpty else {
                throw PinError.invalidCertificateData
            }
            return der
        }
        guard !fileData.isEmpty else { throw PinError.invalidCertificateData }
        return fileData
    }

    public static func normalizedSHA256(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else { return nil }
        return value
    }

    /// 不用普通 String `==`，避免 onboarding identity 比较引入早退 timing signal。
    public static func matches(
        expectedSHA256: String,
        presentedCertificateDER: Data
    ) -> Bool {
        guard let expected = normalizedSHA256(expectedSHA256),
              let expectedBytes = hexBytes(expected)
        else { return false }
        let actualBytes = Array(SHA256.hash(data: presentedCertificateDER))
        guard expectedBytes.count == actualBytes.count else { return false }
        var difference: UInt8 = 0
        for index in expectedBytes.indices {
            difference |= expectedBytes[index] ^ actualBytes[index]
        }
        return difference == 0
    }

    private static func hexBytes(_ value: String) -> [UInt8]? {
        let bytes = Array(value.utf8)
        guard bytes.count == 64 else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(32)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexNibble(bytes[index]),
                  let low = hexNibble(bytes[index + 1]) else { return nil }
            output.append((high << 4) | low)
        }
        return output
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 97 + 10
        default: nil
        }
    }
}

/// 仅用于 `/pair/<pin>` onboarding 的 URLSession TLS delegate。QR 中的 leaf SHA-256
/// 是 server identity；只有握手 leaf DER 精确匹配才放行 HTTP request。故意不做
/// hostname/CA trust，以兼容 `.local`、Ponte 与私有 CA。
public final class PinnedCertificateDelegate: NSObject, URLSessionDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let expectedSHA256: String
    private let rejectionLock = NSLock()
    private var _rejectedCertificate = false

    public init?(expectedSHA256: String) {
        guard let normalized = PairingCertificatePin.normalizedSHA256(expectedSHA256) else {
            return nil
        }
        self.expectedSHA256 = normalized
    }

    public var rejectedCertificate: Bool {
        rejectionLock.withLock { _rejectedCertificate }
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    private func evaluate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let leafDER = SecCertificateCopyData(leaf) as Data
        if PairingCertificatePin.matches(
            expectedSHA256: expectedSHA256,
            presentedCertificateDER: leafDER
        ) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            rejectionLock.withLock { _rejectedCertificate = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Mac Settings → iOS scanner 的 QR wire。v1 没有 `cert_sha256`，只为识别并给出
/// 明确升级提示而继续 decode；只有 v2 + HTTPS + 合法 pin 才能进入 pairing request。
public struct PairingQRPayload: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case malformedPayload
        case invalidHost
        case invalidPort
        case invalidCertificateFingerprint
        case channelBindingRequired
    }

    public let host: String
    public let port: Int
    public let tls: Bool
    public let version: Int
    public let certificateSHA256: String?

    enum CodingKeys: String, CodingKey {
        case host
        case port
        case tls
        case version = "v"
        case certificateSHA256 = "cert_sha256"
    }

    public static func bound(
        host: String,
        port: Int,
        certificateSHA256: String
    ) throws -> PairingQRPayload {
        guard validHost(host) else { throw ValidationError.invalidHost }
        guard (1..<65_536).contains(port) else { throw ValidationError.invalidPort }
        guard let normalized = PairingCertificatePin.normalizedSHA256(certificateSHA256) else {
            throw ValidationError.invalidCertificateFingerprint
        }
        return PairingQRPayload(
            host: host,
            port: port,
            tls: true,
            version: 2,
            certificateSHA256: normalized
        )
    }

    public static func parse(_ raw: String) throws -> PairingQRPayload {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PairingQRPayload.self, from: data)
        else { throw ValidationError.malformedPayload }
        guard validHost(decoded.host) else { throw ValidationError.invalidHost }
        guard (1..<65_536).contains(decoded.port) else { throw ValidationError.invalidPort }
        return decoded
    }

    public var normalizedCertificateSHA256: String? {
        certificateSHA256.flatMap(PairingCertificatePin.normalizedSHA256)
    }

    public var isChannelBound: Bool {
        version >= 2 && tls && normalizedCertificateSHA256 != nil
    }

    @discardableResult
    public func requireChannelBinding() throws -> PairingQRPayload {
        guard isChannelBound else { throw ValidationError.channelBindingRequired }
        return self
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private init(
        host: String,
        port: Int,
        tls: Bool,
        version: Int,
        certificateSHA256: String?
    ) {
        self.host = host
        self.port = port
        self.tls = tls
        self.version = version
        self.certificateSHA256 = certificateSHA256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 8_443
        tls = try values.decodeIfPresent(Bool.self, forKey: .tls) ?? true
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        certificateSHA256 = try values.decodeIfPresent(String.self, forKey: .certificateSHA256)
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_[]"
        )
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

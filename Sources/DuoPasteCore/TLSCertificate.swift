import Foundation
#if canImport(Security)
import Security
#endif

public struct TLSCertificateReport: Codable, Equatable, Sendable {
    public enum ExpiryStatus: String, Codable, Equatable, Sendable {
        case valid
        case expiresWithin30Days = "expires_within_30_days"
        case expiresWithin7Days = "expires_within_7_days"
        case expiresWithin1Day = "expires_within_1_day"
        case expired
        case notYetValid = "not_yet_valid"

        public var requiresAttention: Bool { self != .valid }
    }

    public let certificateFilename: String
    public let dnsSANs: [String]
    public let notBefore: Date
    public let notAfter: Date
    public let evaluatedAt: Date
    public let daysRemaining: Int
    public let expiryStatus: ExpiryStatus

    enum CodingKeys: String, CodingKey {
        case certificateFilename = "certificate_filename"
        case dnsSANs = "dns_sans"
        case notBefore = "not_before"
        case notAfter = "not_after"
        case evaluatedAt = "evaluated_at"
        case daysRemaining = "days_remaining"
        case expiryStatus = "expiry_status"
    }
}

/// mesh-doctor / Settings 共用的三态：未启 TLS、成功读取 leaf、配置了但读不出来。
public struct TLSCertificateState: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case notConfigured = "not_configured"
        case inspected
        case unreadable
    }

    public let state: State
    public let leaf: TLSCertificateReport?
    public let error: String?

    public static let notConfigured = TLSCertificateState(
        state: .notConfigured,
        leaf: nil,
        error: nil
    )

    public static func inspected(_ report: TLSCertificateReport) -> TLSCertificateState {
        TLSCertificateState(state: .inspected, leaf: report, error: nil)
    }

    public static func unreadable(_ reason: String) -> TLSCertificateState {
        TLSCertificateState(state: .unreadable, leaf: nil, error: reason)
    }

    public var requiresAttention: Bool {
        switch state {
        case .notConfigured:
            return false
        case .inspected:
            return leaf?.expiryStatus.requiresAttention ?? true
        case .unreadable:
            return true
        }
    }
}

public enum TLSCertificateInspector {
    public enum InspectionError: Error, CustomStringConvertible, Equatable, Sendable {
        case unreadableFile
        case invalidCertificate
        case validityUnavailable

        public var description: String {
            switch self {
            case .unreadableFile: "证书文件不可读"
            case .invalidCertificate: "无法解析 leaf certificate"
            case .validityUnavailable: "证书缺少有效期信息"
            }
        }
    }

    public static func inspect(at url: URL, now: Date = Date()) throws -> TLSCertificateReport {
        #if os(macOS)
        guard let raw = try? Data(contentsOf: url) else {
            throw InspectionError.unreadableFile
        }
        let der = pemToDER(raw) ?? raw
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw InspectionError.invalidCertificate
        }
        guard let before = certificateDate(
                  certificate,
                  oid: kSecOIDX509V1ValidityNotBefore
              ),
              let after = certificateDate(
                  certificate,
                  oid: kSecOIDX509V1ValidityNotAfter
              )
        else {
            throw InspectionError.validityUnavailable
        }
        let status = classify(notBefore: before, notAfter: after, now: now)
        let seconds = after.timeIntervalSince(now)
        let days = seconds >= 0
            ? Int(ceil(seconds / 86_400))
            : Int(floor(seconds / 86_400))
        return TLSCertificateReport(
            certificateFilename: url.lastPathComponent,
            dnsSANs: dnsSANs(from: certificate),
            notBefore: before,
            notAfter: after,
            evaluatedAt: now,
            daysRemaining: days,
            expiryStatus: status
        )
        #else
        throw InspectionError.invalidCertificate
        #endif
    }

    public static func classify(
        notBefore: Date,
        notAfter: Date,
        now: Date
    ) -> TLSCertificateReport.ExpiryStatus {
        if now < notBefore { return .notYetValid }
        let remaining = notAfter.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= 86_400 { return .expiresWithin1Day }
        if remaining <= 7 * 86_400 { return .expiresWithin7Days }
        if remaining <= 30 * 86_400 { return .expiresWithin30Days }
        return .valid
    }

    #if os(macOS)
    private static func certificateDate(
        _ certificate: SecCertificate,
        oid: CFString
    ) -> Date? {
        let keys = [oid] as CFArray
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(certificate, keys, &error) as? [String: Any],
              let property = values[oid as String] as? [String: Any],
              let raw = property[kSecPropertyKeyValue as String]
        else { return nil }
        if let date = raw as? Date { return date }
        if let number = raw as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return nil
    }

    private static func dnsSANs(from certificate: SecCertificate) -> [String] {
        let keys = [kSecOIDSubjectAltName] as CFArray
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(certificate, keys, &error) as? [String: Any],
              let san = values[kSecOIDSubjectAltName as String] as? [String: Any],
              let entries = san[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let label = entry[kSecPropertyKeyLabel as String] as? String,
                  label == "DNS Name",
                  let value = entry[kSecPropertyKeyValue as String] as? String,
                  !value.isEmpty
            else { return nil }
            return value.lowercased()
        }
    }
    #endif

    private static func pemToDER(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .ascii),
              let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex)
        else { return nil }
        let body = text[begin.upperBound..<end.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: body)
    }
}

import Foundation
import DuoPasteCore

public struct DeviceCredentialRevocationsPage: Codable, Equatable, Sendable {
    public let ok: Bool
    public let revocations: [DeviceCredentialRevocation]

    public init(ok: Bool = true, revocations: [DeviceCredentialRevocation]) {
        self.ok = ok
        self.revocations = revocations
    }
}

public enum DeviceCredentialRevocationsOutcome: Sendable {
    case ok([DeviceCredentialRevocation])
    /// Rolling upgrade：旧 Mac 没有此 route，404 不能拖累 item pull。
    case unsupported
    case rejected(reason: String)
    case unreachable(reason: String)
}

public protocol DeviceCredentialRevocationTransport: Sendable {
    func fetchDeviceCredentialRevocations() async throws -> DeviceCredentialRevocationsOutcome
}

extension HTTPPeerClient: DeviceCredentialRevocationTransport {
    public func fetchDeviceCredentialRevocations() async throws -> DeviceCredentialRevocationsOutcome {
        let path = "/auth/revocations"
        let timestamp = now()
        let signature = auth.sign(
            timestampMs: timestamp,
            method: "GET",
            path: path,
            bodyHashHex: HMACAuth.emptyBodyHashHex
        )
        var url = baseURL
        url.append(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(String(timestamp), forHTTPHeaderField: HMACAuth.timestampHeader)
        request.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        request.setValue(signature, forHTTPHeaderField: HMACAuth.signatureHeader)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .unreachable(reason: "non-http")
        }
        switch http.statusCode {
        case 200...299:
            do {
                return .ok(try JSONDecoder().decode(
                    DeviceCredentialRevocationsPage.self,
                    from: data
                ).revocations)
            } catch {
                return .unreachable(reason: "decode: \(error)")
            }
        case 404:
            return .unsupported
        case 400, 401, 403, 422:
            return .rejected(reason: String(data: data, encoding: .utf8) ?? "http \(http.statusCode)")
        default:
            return .unreachable(reason: "http \(http.statusCode)")
        }
    }
}

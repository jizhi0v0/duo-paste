import Foundation
import DuoPasteCore

public protocol PinOperationTransport: Sendable {
    func submitPinOperation(_ operation: PinOperation) async throws -> RemotePinOperationResult
}

public struct RemotePinOperationResult: Sendable {
    public enum Outcome: Sendable {
        case applied(ingestedAtNs: Int64)
        case pending
        case notFound
        case tombstoned
        case unreachable(reason: String)
        case rejected(reason: String)
    }
    public let outcome: Outcome
    public init(outcome: Outcome) { self.outcome = outcome }
}

private struct PinResponse: Decodable {
    let state: String
    let ingestedAtNs: Int64?

    enum CodingKeys: String, CodingKey {
        case state
        case ingestedAtNs = "ingested_at_ns"
    }
}

extension HTTPPeerClient: PinOperationTransport {
    public func submitPinOperation(_ operation: PinOperation) async throws -> RemotePinOperationResult {
        let queryItems = [
            URLQueryItem(name: "pinned", value: operation.desiredPinned ? "1" : "0"),
            URLQueryItem(name: "operation_id", value: operation.operationID),
        ]
        let routePath = "/pin/\(operation.itemID)"
        var signatureComponents = URLComponents()
        signatureComponents.path = routePath
        signatureComponents.queryItems = queryItems
        let signedPath = HMACAuth.canonicalPath(routePath, query: signatureComponents.percentEncodedQuery)

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = baseURL.path + routePath
        components.queryItems = queryItems
        guard let url = components.url else {
            return RemotePinOperationResult(outcome: .rejected(reason: "无法构造 pin URL"))
        }

        let timestamp = now()
        let signature = auth.sign(
            timestampMs: timestamp,
            method: "POST",
            path: signedPath,
            bodyHashHex: HMACAuth.emptyBodyHashHex
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()
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
            return RemotePinOperationResult(outcome: .unreachable(reason: error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return RemotePinOperationResult(outcome: .unreachable(reason: "non-http"))
        }
        switch http.statusCode {
        case 200...299:
            do {
                let payload = try JSONDecoder().decode(PinResponse.self, from: data)
                if payload.state == "applied", let ns = payload.ingestedAtNs {
                    return RemotePinOperationResult(outcome: .applied(ingestedAtNs: ns))
                }
                if payload.state == "pending" {
                    return RemotePinOperationResult(outcome: .pending)
                }
                return RemotePinOperationResult(outcome: .rejected(reason: "unexpected pin state: \(payload.state)"))
            } catch {
                return RemotePinOperationResult(outcome: .unreachable(reason: "decode: \(error)"))
            }
        case 404:
            return RemotePinOperationResult(outcome: .notFound)
        case 410:
            return RemotePinOperationResult(outcome: .tombstoned)
        case 400, 401, 403, 409, 422:
            return RemotePinOperationResult(outcome: .rejected(
                reason: String(data: data, encoding: .utf8) ?? "http \(http.statusCode)"
            ))
        default:
            return RemotePinOperationResult(outcome: .unreachable(reason: "http \(http.statusCode)"))
        }
    }
}

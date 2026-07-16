import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

typealias TestDuoDB = DuoPasteCore.Database

enum TestSyncServerFixtureError: Error, CustomStringConvertible, Sendable {
    case startTimedOut(request: String, seconds: Double)
    case stoppedBeforeListening(request: String)
    case startFailed(request: String, message: String)

    var description: String {
        switch self {
        case .startTimedOut(let request, let seconds):
            return "\(request): test server did not bind within \(seconds)s"
        case .stoppedBeforeListening(let request):
            return "\(request): test server stopped before reporting its listening port"
        case .startFailed(let request, let message):
            return "\(request): test server failed before listening: \(message)"
        }
    }
}

private enum TestSyncServerStartEvent: Sendable {
    case listening(Int)
    case failed(String)
}

/// HTTP integration-test fixture shared by every SyncServer route test.
///
/// It owns the isolated DB/blob directory, binds `port: 0`, waits for Hummingbird's actual
/// `onServerRunning` callback (never a readiness sleep), and always awaits graceful shutdown.
/// Request failures therefore name the current test and cannot leave a listener/server task behind.
final class TestSyncServerFixture: @unchecked Sendable {
    let root: URL
    let database: TestDuoDB
    let blobs: BlobStore
    let auth: HMACAuth

    init(
        prefix: String,
        items: [Item] = [],
        secretByte: UInt8 = 0xAB
    ) throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths(root: root)
        paths.ensureExists()
        self.database = try TestDuoDB(path: paths.mainDB)
        if !items.isEmpty {
            try database.pool.write { db in
                for item in items { try item.insert(db) }
            }
        }
        self.blobs = BlobStore(root: paths.blobsDir)
        try FileManager.default.createDirectory(at: blobs.root, withIntermediateDirectories: true)
        self.auth = HMACAuth(secret: Data(repeating: secretByte, count: 32))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func withServer<Value>(
        _ server: SyncServer,
        request: String = #function,
        startTimeoutSeconds: Double = 5,
        operation: (URL) async throws -> Value
    ) async throws -> Value {
        let (events, eventContinuation) = AsyncStream<TestSyncServerStartEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let serverTask = Task<Void, Never> {
            do {
                try await server.run { port in
                    eventContinuation.yield(.listening(port))
                }
                eventContinuation.finish()
            } catch is CancellationError {
                eventContinuation.finish()
            } catch {
                eventContinuation.yield(.failed(String(describing: error)))
                eventContinuation.finish()
            }
        }

        do {
            let port = try await Self.waitForPort(
                events,
                request: request,
                timeoutSeconds: startTimeoutSeconds
            )
            let scheme = server.tls == nil ? "http" : "https"
            let baseURL = URL(string: "\(scheme)://127.0.0.1:\(port)")!
            let value = try await operation(baseURL)
            serverTask.cancel()
            await serverTask.value
            return value
        } catch {
            serverTask.cancel()
            await serverTask.value
            throw error
        }
    }

    private static func waitForPort(
        _ events: AsyncStream<TestSyncServerStartEvent>,
        request: String,
        timeoutSeconds: Double
    ) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .listening(let port):
                        return port
                    case .failed(let message):
                        throw TestSyncServerFixtureError.startFailed(
                            request: request,
                            message: message
                        )
                    }
                }
                throw TestSyncServerFixtureError.stoppedBeforeListening(request: request)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw TestSyncServerFixtureError.startTimedOut(
                    request: request,
                    seconds: timeoutSeconds
                )
            }
            guard let port = try await group.next() else {
                throw TestSyncServerFixtureError.stoppedBeforeListening(request: request)
            }
            group.cancelAll()
            return port
        }
    }
}

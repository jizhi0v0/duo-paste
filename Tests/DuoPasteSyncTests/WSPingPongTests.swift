import Testing
import Foundation
import Logging
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSClient
import ServiceLifecycle
import DuoPasteCore
@testable import DuoPasteSync

/// 验证 Server.makeWebSocketRouter 对应用层 ping 帧的回 pong 行为——
/// iOS PeerWebSocket 走应用层 ping 检测 zombie 链路,server 端必须能回 pong 才能让
/// iOS lastPongAt 刷新避免误判。
///
/// 不复用 WebSocketPoCTests 里的 mock server——专门测真实 Server.swift 路径,
/// 保证未来 router 变化能被钉死。

private actor PingPongPortBox {
    private var port: Int?
    private var waiters: [CheckedContinuation<Int, Never>] = []
    func set(_ p: Int) {
        port = p
        let toResume = waiters
        waiters.removeAll()
        for c in toResume { c.resume(returning: p) }
    }
    func get() async -> Int {
        if let p = port { return p }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private typealias DuoDB = DuoPasteCore.Database

private func makeEmptyDB() throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-ws-pingpong-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    return try DuoDB(path: paths.mainDB)
}

private func makeHMACHeaders(auth: HMACAuth, path: String) -> HTTPFields {
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let bodyHash = HMACAuth.emptyBodyHashHex
    let sig = auth.sign(timestampMs: ts, method: "GET", path: path, bodyHashHex: bodyHash)
    var headers = HTTPFields()
    headers[HTTPField.Name(HMACAuth.timestampHeader)!] = String(ts)
    headers[HTTPField.Name(HMACAuth.bodyHashHeader)!] = bodyHash
    headers[HTTPField.Name(HMACAuth.signatureHeader)!] = sig
    return headers
}

private func makeRealServerApp(
    auth: HMACAuth,
    deviceID: String,
    database: DuoDB,
    broadcaster: WSBroadcaster,
    port: PingPongPortBox
) -> some ApplicationProtocol {
    let wsRouter = SyncServer.makeWebSocketRouter(
        auth: auth,
        deviceID: deviceID,
        database: database,
        broadcaster: broadcaster
    )
    var logger = Logger(label: "ws-pingpong-server")
    logger.logLevel = .critical
    return Application(
        router: Router(),
        server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
        configuration: .init(address: .hostname("127.0.0.1", port: 0)),
        onServerRunning: { ch in
            if let p = ch.localAddress?.port { await port.set(p) }
        },
        logger: logger
    )
}

@Suite(.serialized)
struct WSPingPongTests {
    @Test func serverRespondsWithPongOnAppLevelPing() async throws {
        let secret = Data(repeating: 0xEE, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PingPongPortBox()
        let db = try makeEmptyDB()
        let broadcaster = WSBroadcaster(rotationIntervalSec: 0)

        let app = makeRealServerApp(
            auth: auth,
            deviceID: "server-X",
            database: db,
            broadcaster: broadcaster,
            port: port
        )

        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [app],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: app.logger
            )
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await serviceGroup.run() }

            do {
                let p = await port.get()
                let headers = makeHMACHeaders(auth: auth, path: "/sync/ws")
                var clientLogger = Logger(label: "ws-pingpong-client")
                clientLogger.logLevel = .critical

                try await WebSocketClient.connect(
                    url: "ws://127.0.0.1:\(p)/sync/ws",
                    configuration: .init(additionalHeaders: headers),
                    logger: clientLogger
                ) { inbound, outbound, _ in
                    var iter = inbound.messages(maxSize: .max).makeAsyncIterator()
                    // 跳过 server 主动发的 hello
                    let hello = try await iter.next()
                    guard case .text(let helloS) = hello else {
                        Issue.record("expected hello text, got: \(String(describing: hello))")
                        return
                    }
                    let helloMsg = try WSMessage.decodeJSON(helloS)
                    guard case .hello = helloMsg else {
                        Issue.record("expected .hello, got: \(helloMsg)")
                        return
                    }

                    // 发应用层 ping
                    let pingPayload = try WSMessage.ping(version: WSMessage.currentVersion).encodeJSON()
                    try await outbound.write(.text(pingPayload))

                    // 期望立刻收到 pong
                    let pong = try await iter.next()
                    guard case .text(let pongS) = pong else {
                        Issue.record("expected pong text, got: \(String(describing: pong))")
                        return
                    }
                    let pongMsg = try WSMessage.decodeJSON(pongS)
                    #expect(pongMsg == .pong(version: WSMessage.currentVersion))
                }

                await serviceGroup.triggerGracefulShutdown()
            } catch {
                await serviceGroup.triggerGracefulShutdown()
                throw error
            }
        }
    }

    @Test func serverIgnoresUnknownFrameTypeWithoutClosingConnection() async throws {
        // client 发损坏 / 未知 JSON → server 应 noop 不关闭连接,这样 client 后续 ping 仍能收 pong
        let secret = Data(repeating: 0xFA, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PingPongPortBox()
        let db = try makeEmptyDB()
        let broadcaster = WSBroadcaster(rotationIntervalSec: 0)

        let app = makeRealServerApp(
            auth: auth,
            deviceID: "server-Y",
            database: db,
            broadcaster: broadcaster,
            port: port
        )

        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [app],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: app.logger
            )
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await serviceGroup.run() }

            do {
                let p = await port.get()
                let headers = makeHMACHeaders(auth: auth, path: "/sync/ws")
                var clientLogger = Logger(label: "ws-junk-client")
                clientLogger.logLevel = .critical

                try await WebSocketClient.connect(
                    url: "ws://127.0.0.1:\(p)/sync/ws",
                    configuration: .init(additionalHeaders: headers),
                    logger: clientLogger
                ) { inbound, outbound, _ in
                    var iter = inbound.messages(maxSize: .max).makeAsyncIterator()
                    // 跳 hello
                    _ = try await iter.next()

                    // 发垃圾 JSON——server 应跳过不关闭连接
                    try await outbound.write(.text("{\"type\":\"junk\",\"version\":1}"))
                    try await outbound.write(.text("not-json-at-all"))

                    // 后续 ping 仍能收 pong——证明连接没被前面的垃圾搞挂
                    let pingPayload = try WSMessage.ping(version: WSMessage.currentVersion).encodeJSON()
                    try await outbound.write(.text(pingPayload))
                    let pong = try await iter.next()
                    guard case .text(let pongS) = pong else {
                        Issue.record("expected pong text after junk frames, got: \(String(describing: pong))")
                        return
                    }
                    let pongMsg = try WSMessage.decodeJSON(pongS)
                    #expect(pongMsg == .pong(version: WSMessage.currentVersion))
                }

                await serviceGroup.triggerGracefulShutdown()
            } catch {
                await serviceGroup.triggerGracefulShutdown()
                throw error
            }
        }
    }
}

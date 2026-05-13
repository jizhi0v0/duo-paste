import Testing
import Foundation
import Logging
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSClient
import ServiceLifecycle
@testable import DuoPasteSync

// PoC：验证 hummingbird-websocket 在 duo-paste 现有环境下能跑通核心路径。
// PR 3（WebSocket 通知层）落地后这个 PoC 可以删，或留作端到端回归。
//
// 验证三件套：
// (a) ws Upgrade GET 经过 HMACAuthMiddleware 校验（合法签名通过 / 缺签名拒绝）
// (b) Upgrade 后双向消息能传递（server send → client recv 文本帧）
// (c) WebSocketClientConfiguration.additionalHeaders 能把 HMAC 头注入 Upgrade request

/// 异步拿 server 启动后的真实端口（address: port=0 是任意端口）。
private actor PortBox {
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

private func makeWSApp(
    auth: HMACAuth,
    port: PortBox,
    onUpgrade: @escaping @Sendable (WebSocketInboundStream, WebSocketOutboundWriter) async throws -> Void
) -> some ApplicationProtocol {
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    wsRouter.middlewares.add(HMACAuthMiddleware<BasicWebSocketRequestContext>(auth: auth))
    wsRouter.ws("/sync/ws") { _, _ in
        .upgrade([:])
    } onUpgrade: { inbound, outbound, _ in
        try await onUpgrade(inbound, outbound)
    }
    var logger = Logger(label: "ws-poc-server")
    logger.logLevel = .warning
    return Application(
        router: Router(),
        server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
        configuration: .init(address: .hostname("127.0.0.1", port: 0)),
        onServerRunning: { channel in
            if let p = channel.localAddress?.port { await port.set(p) }
        },
        logger: logger
    )
}

@Suite(.serialized)
struct WebSocketPoCTests {

    @Test func upgradeWithValidHMACReceivesServerMessage() async throws {
        let secret = Data(repeating: 0xAB, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PortBox()

        let app = makeWSApp(auth: auth, port: port) { inbound, outbound in
            // Upgrade 成功后 server 主动发一条 hello；等 client 关连接
            try await outbound.write(.text("hello-from-server"))
            for try await _ in inbound {}
        }

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
                var clientLogger = Logger(label: "ws-poc-client")
                clientLogger.logLevel = .warning

                try await WebSocketClient.connect(
                    url: "ws://127.0.0.1:\(p)/sync/ws",
                    configuration: .init(
                        additionalHeaders: headers,
                        autoPing: .enabled(timePeriod: .seconds(30))
                    ),
                    logger: clientLogger
                ) { inbound, _, _ in
                    var iter = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let msg = try await iter.next()
                    #expect(msg == .text("hello-from-server"))
                }

                await serviceGroup.triggerGracefulShutdown()
            } catch {
                await serviceGroup.triggerGracefulShutdown()
                throw error
            }
        }
    }

    @Test func upgradeWithoutHMACIsRejected() async throws {
        let secret = Data(repeating: 0xAB, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PortBox()

        let app = makeWSApp(auth: auth, port: port) { _, _ in
            Issue.record("server upgrade closure should not run when HMAC missing")
        }

        let serviceGroup = ServiceGroup(
            configuration: .init(
                services: [app],
                gracefulShutdownSignals: [.sigterm, .sigint],
                logger: app.logger
            )
        )

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await serviceGroup.run() }

            let p = await port.get()
            var clientLogger = Logger(label: "ws-poc-client-noauth")
            clientLogger.logLevel = .critical  // 抑制 expected failure 噪音

            await #expect(throws: (any Error).self) {
                try await WebSocketClient.connect(
                    url: "ws://127.0.0.1:\(p)/sync/ws",
                    configuration: .init(),  // 不带 HMAC headers
                    logger: clientLogger
                ) { _, _, _ in
                    Issue.record("client connect closure should not run")
                }
            }

            await serviceGroup.triggerGracefulShutdown()
        }
    }

    @Test func clientToServerMessageRoundTrip() async throws {
        let secret = Data(repeating: 0xCD, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PortBox()

        let app = makeWSApp(auth: auth, port: port) { inbound, outbound in
            // Echo 模式：把收到的文本帧 prefix "echo:" 写回
            var iter = inbound.messages(maxSize: .max).makeAsyncIterator()
            if case .text(let s) = try await iter.next() {
                try await outbound.write(.text("echo:" + s))
            }
        }

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
                var clientLogger = Logger(label: "ws-poc-client-rt")
                clientLogger.logLevel = .warning

                try await WebSocketClient.connect(
                    url: "ws://127.0.0.1:\(p)/sync/ws",
                    configuration: .init(additionalHeaders: headers),
                    logger: clientLogger
                ) { inbound, outbound, _ in
                    try await outbound.write(.text("ping"))
                    var iter = inbound.messages(maxSize: .max).makeAsyncIterator()
                    let msg = try await iter.next()
                    #expect(msg == .text("echo:ping"))
                }

                await serviceGroup.triggerGracefulShutdown()
            } catch {
                await serviceGroup.triggerGracefulShutdown()
                throw error
            }
        }
    }
}

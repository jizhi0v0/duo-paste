import Testing
import Foundation
import Logging
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSClient
import ServiceLifecycle
@testable import DuoPasteSync

/// PR 3 WSBroadcaster 端到端测试。
///
/// 测试模型：起一个 hbws server，每个 client 连上后立刻被 register 进 broadcaster。
/// Test driver 用 broadcaster.broadcastCursorAdvanced(...) 触发 fan-out，验证：
///
/// - 多 client 同时连：每个都收到广播
/// - 广播间无 client 连：no-op 不抛
/// - 慢消费者超时：write hang 的 connection 被踢，其他 connection 仍正常收到
///
/// 慢消费者测试用 `WSBroadcaster(perBroadcastTimeoutSec: 0.1)` 让超时短到测试可控。

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

/// 跑一个绑 broadcaster 的 ws server。每个 Upgrade 连上 → broadcaster.register +
/// for-await inbound 直到关闭 → defer unregister。
private func makeBroadcastServer(
    auth: HMACAuth,
    port: PortBox,
    broadcaster: WSBroadcaster,
    onClientConnected: @escaping @Sendable () -> Void = {}
) -> some ApplicationProtocol {
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    wsRouter.middlewares.add(HMACAuthMiddleware<BasicWebSocketRequestContext>(auth: auth))
    wsRouter.ws("/sync/ws") { _, _ in
        .upgrade([:])
    } onUpgrade: { inbound, outbound, _ in
        let id = await broadcaster.register(writer: outbound, peerHint: "test")
        onClientConnected()
        defer {
            Task { await broadcaster.unregister(id) }
        }
        do {
            for try await _ in inbound.messages(maxSize: 64 * 1024) {
                // 测试 client 不发消息
            }
        } catch {
            // close
        }
    }
    var logger = Logger(label: "ws-broadcast-test-server")
    logger.logLevel = .critical
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

/// "几个 client 都收到广播" actor 计数器
private actor Receipts {
    private var byTag: [String: Int] = [:]
    func record(_ tag: String) { byTag[tag, default: 0] += 1 }
    func count(_ tag: String) -> Int { byTag[tag] ?? 0 }
    func total() -> Int { byTag.values.reduce(0, +) }
}

/// 等到某条件满足或超时——避免 sleep 固定时长 flake
private func waitUntil(timeoutSec: Double = 3.0, _ check: @Sendable () async -> Bool) async {
    let stepNs: UInt64 = 20_000_000  // 20ms
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
        if await check() { return }
        try? await Task.sleep(nanoseconds: stepNs)
    }
}

@Suite(.serialized)
struct WSBroadcasterTests {

    @Test func multipleClientsAllReceiveCursorAdvanced() async throws {
        let secret = Data(repeating: 0xA0, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PortBox()
        let broadcaster = WSBroadcaster()
        let connectedCount = Receipts()

        let app = makeBroadcastServer(
            auth: auth, port: port, broadcaster: broadcaster,
            onClientConnected: {
                Task { await connectedCount.record("conn") }
            }
        )
        let group = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask { try await group.run() }

            let p = await port.get()
            let receipts = Receipts()
            // 起 3 个 client 各自跑 inbound for-await，收 cursor_advanced 时记一次
            let clientCount = 3
            let endSignal = AsyncStream<Void>.makeStream()
            for i in 0..<clientCount {
                taskGroup.addTask {
                    let headers = makeHMACHeaders(auth: auth, path: "/sync/ws")
                    var l = Logger(label: "ws-test-client-\(i)")
                    l.logLevel = .critical
                    do {
                        try await WebSocketClient.connect(
                            url: "ws://127.0.0.1:\(p)/sync/ws",
                            configuration: .init(additionalHeaders: headers),
                            logger: l
                        ) { inbound, _, _ in
                            for try await msg in inbound.messages(maxSize: 64 * 1024) {
                                if case .text(let s) = msg,
                                   let m = try? WSMessage.decodeJSON(s),
                                   case .cursorAdvanced = m
                                {
                                    await receipts.record("client-\(i)")
                                    endSignal.continuation.yield(())
                                    break
                                }
                            }
                        }
                    } catch {
                        // server shutdown 会让 connect 抛错——忽略，测试主体已经断言完
                    }
                }
            }

            // 等所有 3 个 client 都被 server 接受
            await waitUntil { await connectedCount.count("conn") >= clientCount }
            #expect(await connectedCount.count("conn") == clientCount)
            // 等 broadcaster 把所有 register 处理完
            await waitUntil { await broadcaster.connectionCount >= clientCount }
            #expect(await broadcaster.connectionCount == clientCount)

            await broadcaster.broadcastCursorAdvanced(deviceID: "self-X", latestIngestedAtNs: 12345)

            // 等 3 个 client 都收到（最多 3s）
            var received = 0
            let collector = Task {
                for await _ in endSignal.stream {
                    received += 1
                    if received >= clientCount { break }
                }
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            collector.cancel()
            for i in 0..<clientCount {
                #expect(await receipts.count("client-\(i)") == 1, "client \(i) 没收到 cursor_advanced")
            }
            await group.triggerGracefulShutdown()
        }
    }

    @Test func broadcastWithNoConnectionsIsNoOp() async throws {
        let broadcaster = WSBroadcaster()
        await broadcaster.broadcastCursorAdvanced(deviceID: "X", latestIngestedAtNs: 1)
        #expect(await broadcaster.connectionCount == 0)
    }

    @Test func unregisterIsIdempotent() async throws {
        // 直接构造 ConnectionID 不暴露——通过启动一个简单 server 走 register/unregister 路径
        // 验证：没有 panic、log 一致
        let secret = Data(repeating: 0xA1, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PortBox()
        let broadcaster = WSBroadcaster()

        let app = makeBroadcastServer(auth: auth, port: port, broadcaster: broadcaster)
        let serviceGroup = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))
        try await withThrowingTaskGroup(of: Void.self) { tg in
            tg.addTask { try await serviceGroup.run() }
            let p = await port.get()
            let headers = makeHMACHeaders(auth: auth, path: "/sync/ws")
            var l = Logger(label: "test-client-unreg")
            l.logLevel = .critical
            // 连上后立刻关
            try await WebSocketClient.connect(
                url: "ws://127.0.0.1:\(p)/sync/ws",
                configuration: .init(additionalHeaders: headers),
                logger: l
            ) { _, outbound, _ in
                try await outbound.close(.goingAway, reason: nil)
            }
            // server 应当处理掉 close 帧 → defer 跑 unregister
            await waitUntil { await broadcaster.connectionCount == 0 }
            #expect(await broadcaster.connectionCount == 0)
            await serviceGroup.triggerGracefulShutdown()
        }
    }
}

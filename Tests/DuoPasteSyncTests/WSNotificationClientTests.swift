import Testing
import Foundation
import Logging
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSClient
import ServiceLifecycle
@testable import DuoPasteSync

/// PR 3 WSNotificationClient 端到端测试。
///
/// 验证：
/// - 收到 cursor_advanced → 触发 onCursorAdvanced 闭包（PullWorker.wake() 路径）
/// - 收到 hello → 同款触发（hello 携带 baseline cursor）
/// - 严格模式下 expectedPeerDeviceID 不匹配 → 不触发 onCursorAdvanced
/// - 连接断开后能重连（用短 reconnectInitialSec 让测试可控）
/// - stop() 取消重连 task

private actor PortBox2 {
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

private actor Counter {
    private var values: [Int64] = []
    func record(_ v: Int64) { values.append(v) }
    func count() -> Int { values.count }
    func snapshot() -> [Int64] { values }
}

/// 起一个最小 WS server，每次 Upgrade 把测试预设的消息序列写出去后关闭。
private func makeScriptedServer(
    auth: HMACAuth,
    port: PortBox2,
    script: @escaping @Sendable (WebSocketOutboundWriter) async throws -> Void
) -> some ApplicationProtocol {
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    wsRouter.middlewares.add(HMACAuthMiddleware<BasicWebSocketRequestContext>(auth: auth))
    wsRouter.ws("/sync/ws") { _, _ in
        .upgrade([:])
    } onUpgrade: { _, outbound, _ in
        try await script(outbound)
    }
    var logger = Logger(label: "ws-client-test-server")
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

private func waitUntil2(timeoutSec: Double = 3.0, _ check: @Sendable () async -> Bool) async {
    let stepNs: UInt64 = 20_000_000
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
        if await check() { return }
        try? await Task.sleep(nanoseconds: stepNs)
    }
}

@Suite(.serialized)
struct WSNotificationClientTests {

    @Test func cursorAdvancedTriggersCallback() async throws {
        let secret = Data(repeating: 0xC0, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PortBox2()
        let counter = Counter()

        let app = makeScriptedServer(auth: auth, port: port) { outbound in
            let msg = WSMessage.cursorAdvanced(version: 1, deviceID: "peer", latestIngestedAtNs: 999)
            try await outbound.write(.text(msg.encodeJSON()))
            // 不主动 close —— 让 client 的 inbound for-await 阻塞，由测试 stop() 收尾
            // 给 1s 让 client 处理完上面那帧
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let group = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))

        try await withThrowingTaskGroup(of: Void.self) { tg in
            tg.addTask { try await group.run() }
            let p = await port.get()
            let url = URL(string: "http://127.0.0.1:\(p)")!
            let client = WSNotificationClient(
                peerURL: url,
                auth: auth,
                expectedPeerDeviceID: nil,
                onCursorAdvanced: { ns in Task { await counter.record(ns) } }
            )
            await client.start()
            await waitUntil2 { await counter.count() >= 1 }
            #expect(await counter.snapshot() == [999])
            await client.stop()
            await group.triggerGracefulShutdown()
        }
    }

    @Test func helloAlsoTriggersCallback() async throws {
        // hello 带 baseline cursor，让重连后 client 立即自检；测试用同一回调路径
        let secret = Data(repeating: 0xC1, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PortBox2()
        let counter = Counter()

        let app = makeScriptedServer(auth: auth, port: port) { outbound in
            let msg = WSMessage.hello(version: 1, deviceID: "peer", nowMs: 17000, latestIngestedAtNs: 42)
            try await outbound.write(.text(msg.encodeJSON()))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let group = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))
        try await withThrowingTaskGroup(of: Void.self) { tg in
            tg.addTask { try await group.run() }
            let p = await port.get()
            let url = URL(string: "http://127.0.0.1:\(p)")!
            let client = WSNotificationClient(
                peerURL: url, auth: auth, expectedPeerDeviceID: nil,
                onCursorAdvanced: { ns in Task { await counter.record(ns) } }
            )
            await client.start()
            await waitUntil2 { await counter.count() >= 1 }
            #expect(await counter.snapshot() == [42])
            await client.stop()
            await group.triggerGracefulShutdown()
        }
    }

    @Test func unexpectedPeerDeviceIDIgnoresCursorAdvanced() async throws {
        // 严格模式：expected="A" 但 server 报 deviceID="B" → 不触发
        let secret = Data(repeating: 0xC2, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PortBox2()
        let counter = Counter()

        let app = makeScriptedServer(auth: auth, port: port) { outbound in
            let msg = WSMessage.cursorAdvanced(version: 1, deviceID: "B", latestIngestedAtNs: 100)
            try await outbound.write(.text(msg.encodeJSON()))
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        let group = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))
        try await withThrowingTaskGroup(of: Void.self) { tg in
            tg.addTask { try await group.run() }
            let p = await port.get()
            let url = URL(string: "http://127.0.0.1:\(p)")!
            let client = WSNotificationClient(
                peerURL: url, auth: auth, expectedPeerDeviceID: "A",
                onCursorAdvanced: { ns in Task { await counter.record(ns) } }
            )
            await client.start()
            try await Task.sleep(nanoseconds: 700_000_000)
            #expect(await counter.count() == 0, "expected peer 不匹配不该触发")
            await client.stop()
            await group.triggerGracefulShutdown()
        }
    }

    @Test func reconnectsAfterServerCloses() async throws {
        // server 每次 Upgrade 写 1 条 cursor_advanced 后立即关闭 → client 应当 backoff 后重连，
        // 多次回调应当被触发。reconnectInitialSec=0.1s 让测试 1.5s 内能拿到 ≥2 次
        let secret = Data(repeating: 0xC3, count: 32)
        let auth = HMACAuth(secret: secret)
        let port = PortBox2()
        let counter = Counter()

        let app = makeScriptedServer(auth: auth, port: port) { outbound in
            let msg = WSMessage.cursorAdvanced(version: 1, deviceID: "peer", latestIngestedAtNs: 1)
            try await outbound.write(.text(msg.encodeJSON()))
            try await outbound.close(.normalClosure, reason: nil)
        }
        let group = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))
        try await withThrowingTaskGroup(of: Void.self) { tg in
            tg.addTask { try await group.run() }
            let p = await port.get()
            let url = URL(string: "http://127.0.0.1:\(p)")!
            let client = WSNotificationClient(
                peerURL: url, auth: auth, expectedPeerDeviceID: nil,
                onCursorAdvanced: { ns in Task { await counter.record(ns) } },
                config: .init(
                    heartbeatSec: 30,
                    reconnectInitialSec: 0.1,
                    reconnectMaxSec: 0.5
                )
            )
            await client.start()
            await waitUntil2(timeoutSec: 5.0) { await counter.count() >= 2 }
            let n = await counter.count()
            #expect(n >= 2, "重连后应至少触发 2 次 onCursorAdvanced，实际=\(n)")
            await client.stop()
            await group.triggerGracefulShutdown()
        }
    }

    @Test func stopCancelsReconnectLoop() async throws {
        // 没起 server → 直接 stop 应当快速返回（不卡 reconnect backoff）
        let secret = Data(repeating: 0xC4, count: 32)
        let auth = HMACAuth(secret: secret)
        let url = URL(string: "http://127.0.0.1:1")!  // 拒连
        let counter = Counter()
        let client = WSNotificationClient(
            peerURL: url, auth: auth, expectedPeerDeviceID: nil,
            onCursorAdvanced: { ns in Task { await counter.record(ns) } },
            config: .init(reconnectInitialSec: 60, reconnectMaxSec: 60)
        )
        await client.start()
        try? await Task.sleep(nanoseconds: 200_000_000)  // 让 runLoop 跑一轮 connect 失败
        await client.stop()
        // stop 必须能立即取消 60s sleep 不卡死。再等 100ms 验证 onCursorAdvanced 仍未触发
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await counter.count() == 0)
    }
}

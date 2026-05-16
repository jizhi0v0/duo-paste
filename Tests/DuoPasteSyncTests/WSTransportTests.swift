import Testing
import Foundation
import Logging
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import HummingbirdWSClient
import WSCore
import ServiceLifecycle
@testable import DuoPasteSync

/// PR 2 WSTransport 抽象端到端测试。
///
/// 两个 transport 实现 (NIO / URLSession) 必须语义一致：
/// - 收到 server 端 text 帧 → onText 被调用一次，内容一致
/// - server 主动 close → runOnce throw 让外层 backoff 重连
/// - 收到超过 maxInboundMessageBytes 的帧 → runOnce throw 防 DoS
///
/// URLSession transport 用 URLSession.shared（无 proxy 配置）连 127.0.0.1——验证 transport
/// 本身行为正确；ponte 路径上 connectionProxyDictionary 由生产 PonteSession 注入，不在这层测

private actor TestPortBox {
    private var port: Int?
    private var waiters: [CheckedContinuation<Int, Never>] = []
    func set(_ p: Int) {
        port = p
        for c in waiters { c.resume(returning: p) }
        waiters.removeAll()
    }
    func get() async -> Int {
        if let p = port { return p }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// 给单次 client 一次 outbound writer hook 让测试 driver 自己写帧 + 决定是否关
private func makeWSEchoServer(
    auth: HMACAuth,
    port: TestPortBox,
    onUpgraded: @escaping @Sendable (WebSocketOutboundWriter) async throws -> Void
) -> some ApplicationProtocol {
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    wsRouter.middlewares.add(HMACAuthMiddleware<BasicWebSocketRequestContext>(auth: auth))
    wsRouter.ws("/sync/ws") { _, _ in
        .upgrade([:])
    } onUpgrade: { inbound, outbound, _ in
        // 让测试 driver 写完想写的帧再返回；返回后 onUpgrade 退出 → 自然 close
        Task {
            try? await onUpgraded(outbound)
        }
        // 跑 inbound 让连接保活——client 可能在 onUpgraded 完成前还要继续 receive 心跳 ping/pong
        do {
            for try await _ in inbound.messages(maxSize: 1024 * 1024) {}
        } catch {}
    }
    var logger = Logger(label: "ws-transport-test-server")
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

private func makeHMACHeaderTuples(auth: HMACAuth, path: String) -> [(name: String, value: String)] {
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let bodyHash = HMACAuth.emptyBodyHashHex
    let sig = auth.sign(timestampMs: ts, method: "GET", path: path, bodyHashHex: bodyHash)
    return [
        (HMACAuth.timestampHeader, String(ts)),
        (HMACAuth.bodyHashHeader, bodyHash),
        (HMACAuth.signatureHeader, sig),
    ]
}

/// 收件箱 actor——测试断言用
private actor TextInbox {
    private(set) var texts: [String] = []
    func record(_ s: String) { texts.append(s) }
    func count() -> Int { texts.count }
    func first() -> String? { texts.first }
}

/// 连接状态记录——onConnected(true/false) 各调几次
private actor ConnState {
    private(set) var transitions: [Bool] = []
    func record(_ v: Bool) { transitions.append(v) }
    var isUp: Bool { transitions.last ?? false }
    var hasBeenUp: Bool { transitions.contains(true) }
}

@Suite(.serialized)
struct WSTransportTests {

    // MARK: - NIO impl

    @Test func nioTransportDeliversTextFrame() async throws {
        let auth = HMACAuth(secret: Data(repeating: 0xB0, count: 32))
        let port = TestPortBox()
        let payload = #"{"type":"cursor_advanced","version":1,"device_id":"test","latest_ingested_at_ns":42}"#

        let app = makeWSEchoServer(auth: auth, port: port) { outbound in
            try await outbound.write(.text(payload))
            // 写完一帧立即返回 → onUpgrade 退出 → server 端 close 让 client 端 receive 收尾
        }
        let group = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask { try await group.run() }
            let p = await port.get()
            let inbox = TextInbox()
            let state = ConnState()
            let headers = makeHMACHeaderTuples(auth: auth, path: "/sync/ws")

            // server close 会让 runOnce 自然 return（NIO inbound for-await 退出）。deadline
            // 兜底：如果 NIO close 传播也卡了，8s 后让 task 抛 timeout 让测试至少能完成
            try? await runWithDeadline {
                try await NIOWebSocketTransport().runOnce(
                    wsURL: "ws://127.0.0.1:\(p)/sync/ws",
                    headers: headers,
                    maxInboundMessageBytes: 64 * 1024,
                    heartbeatSec: 30,
                    onConnected: { v in Task { await state.record(v) } },
                    onText: { s in await inbox.record(s) }
                )
            }

            #expect(await inbox.count() == 1)
            #expect(await inbox.first() == payload)
            #expect(await state.hasBeenUp)
            await group.triggerGracefulShutdown()
        }
    }

    // MARK: - URLSession impl

    @Test func urlSessionTransportDeliversTextFrame() async throws {
        let auth = HMACAuth(secret: Data(repeating: 0xB1, count: 32))
        let port = TestPortBox()
        let payload = #"{"type":"cursor_advanced","version":1,"device_id":"test","latest_ingested_at_ns":99}"#

        let app = makeWSEchoServer(auth: auth, port: port) { outbound in
            try await outbound.write(.text(payload))
        }
        let group = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask { try await group.run() }
            let p = await port.get()
            let inbox = TextInbox()
            let state = ConnState()
            let headers = makeHMACHeaderTuples(auth: auth, path: "/sync/ws")
            let transport = URLSessionWebSocketTransport(session: .shared, readinessTimeoutSec: 5)

            // 启动 runOnce 在后台 + 8s deadline 兜底；等收到一帧再断言
            let runTask = Task {
                try? await runWithDeadline {
                    try await transport.runOnce(
                        wsURL: "ws://127.0.0.1:\(p)/sync/ws",
                        headers: headers,
                        maxInboundMessageBytes: 64 * 1024,
                        heartbeatSec: 30,
                        onConnected: { v in Task { await state.record(v) } },
                        onText: { s in await inbox.record(s) }
                    )
                }
            }

            // 等收到帧 + 上线 transition——onText 来自 server.write 触发
            await waitFor(timeoutSec: 5) { await inbox.count() >= 1 }
            #expect(await inbox.count() == 1)
            #expect(await inbox.first() == payload)
            #expect(await state.hasBeenUp)

            runTask.cancel()
            await group.triggerGracefulShutdown()
        }
    }

    @Test func urlSessionTransportSurfacesCloseAsThrow() async throws {
        // server 主动 close (没回 close frame 也算)——URLSession receive 应该 throw，
        // 而不是 silent return（外层 runLoop 靠 throw 触发 backoff）
        let auth = HMACAuth(secret: Data(repeating: 0xB2, count: 32))
        let port = TestPortBox()

        let app = makeWSEchoServer(auth: auth, port: port) { outbound in
            // server 端写一帧后立即 return → onUpgrade 退出 → channel 关
            try await outbound.write(.text("hello"))
            try? await outbound.close(.normalClosure, reason: nil)
        }
        let group = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask { try await group.run() }
            let p = await port.get()
            let inbox = TextInbox()
            let headers = makeHMACHeaderTuples(auth: auth, path: "/sync/ws")
            let transport = URLSessionWebSocketTransport(session: .shared, readinessTimeoutSec: 5)

            var threw = false
            do {
                try await runWithDeadline {
                    try await transport.runOnce(
                        wsURL: "ws://127.0.0.1:\(p)/sync/ws",
                        headers: headers,
                        maxInboundMessageBytes: 64 * 1024,
                        heartbeatSec: 30,
                        onConnected: { _ in },
                        onText: { s in await inbox.record(s) }
                    )
                }
            } catch {
                threw = true
            }
            #expect(threw, "server close 必须让 runOnce 抛错（外层 backoff 重连依赖这个）")
            #expect(await inbox.count() >= 1, "close 前发的那一帧应该已经收到")
            await group.triggerGracefulShutdown()
        }
    }

    @Test func urlSessionTransportRespectsMaxInboundBytes() async throws {
        let auth = HMACAuth(secret: Data(repeating: 0xB3, count: 32))
        let port = TestPortBox()
        let big = String(repeating: "x", count: 200_000) // 200 KB

        let app = makeWSEchoServer(auth: auth, port: port) { outbound in
            try await outbound.write(.text(big))
        }
        let group = ServiceGroup(configuration: .init(
            services: [app], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        ))

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask { try await group.run() }
            let p = await port.get()
            let inbox = TextInbox()
            let headers = makeHMACHeaderTuples(auth: auth, path: "/sync/ws")
            let transport = URLSessionWebSocketTransport(session: .shared, readinessTimeoutSec: 5)

            var threw = false
            do {
                try await runWithDeadline {
                    try await transport.runOnce(
                        wsURL: "ws://127.0.0.1:\(p)/sync/ws",
                        headers: headers,
                        maxInboundMessageBytes: 64 * 1024,  // 远小于 200 KB
                        heartbeatSec: 30,
                        onConnected: { _ in },
                        onText: { s in await inbox.record(s) }
                    )
                }
            } catch {
                threw = true
            }
            #expect(threw, "超过 maxInboundMessageBytes 必须 throw 防 DoS")
            #expect(await inbox.count() == 0, "超长帧不该被 deliver 给 onText")
            await group.triggerGracefulShutdown()
        }
    }

    @Test func urlSessionTransportBadURLThrows() async throws {
        let transport = URLSessionWebSocketTransport(session: .shared, readinessTimeoutSec: 1)
        var caught: Error?
        do {
            try await transport.runOnce(
                wsURL: "",  // URL(string: "") = nil → WSTransportError.badURL
                headers: [],
                maxInboundMessageBytes: 1024,
                heartbeatSec: 1,
                onConnected: { _ in },
                onText: { _ in }
            )
        } catch {
            caught = error
        }
        guard let e = caught else {
            Issue.record("空 URL 必须 throw badURL")
            return
        }
        guard case WSTransportError.badURL = e else {
            Issue.record("期望 WSTransportError.badURL，得到 \(e)")
            return
        }
    }
}

/// 简化版 polling helper——避免依赖 WSBroadcasterTests 的 file-private waitUntil
private func waitFor(timeoutSec: Double, _ check: @Sendable () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
        if await check() { return }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
}

/// runOnce 卡住时强制 deadline——URLSession 在 server close 不一定立即让 receive() throw，
/// 测试用这个 bound 避免无限挂。超时跟正常 throw 都被外部 catch 同样处理
private struct WSTestTimeout: Error {}
private func runWithDeadline(
    _ body: @escaping @Sendable () async throws -> Void,
    seconds: Double = 8
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { g in
        g.addTask { try await body() }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw WSTestTimeout()
        }
        _ = try await g.next()
        g.cancelAll()
    }
}

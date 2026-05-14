import Foundation
import Logging
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import HummingbirdWebSocket
import NIOSSL
import HTTPTypes
import DuoPasteCore

/// 包装 Hummingbird Application 的启动入口。M2 当前暴露 `/health` + `/ingest`，
/// 后续 `/search /since /blob` 在同一个 Router 上追加。
///
/// 用法：
///
///     let server = SyncServer(deviceID: ..., database: ..., auth: ..., host: ..., port: ...)
///     try await server.run()    // 阻塞直到 SIGTERM/SIGINT
///
/// AppDelegate 把它丢到 Task 里跑；进程退出时 ServiceLifecycle 会 graceful shutdown。
public struct SyncServer: Sendable {
    public let deviceID: String
    public let database: DuoPasteCore.Database
    public let host: String
    public let port: Int
    public let blobs: BlobStore
    public let auth: HMACAuth
    /// 为空 → HTTP（依赖 Tailscale WG 加密）；非空 → HTTPS（PEM cert+key 路径）。
    public let tls: TLSPaths?
    /// PR 3 WebSocket 通知层。`/sync/ws` 接到 Upgrade 后把 outbound writer 注册进去，
    /// CaptureService 完成 writer tx 调 `broadcaster.broadcastCursorAdvanced(...)` fan-out。
    /// nil → server 不支持 WS（standalone primary / 测试），仍能正常 serve HTTP。
    public let broadcaster: WSBroadcaster?

    public struct TLSPaths: Sendable {
        public let certPath: String
        public let keyPath: String
        public init(certPath: String, keyPath: String) {
            self.certPath = certPath
            self.keyPath = keyPath
        }
    }

    public init(
        deviceID: String,
        database: DuoPasteCore.Database,
        blobs: BlobStore,
        host: String,
        port: Int,
        auth: HMACAuth,
        tls: TLSPaths? = nil,
        broadcaster: WSBroadcaster? = nil
    ) {
        self.deviceID = deviceID
        self.database = database
        self.blobs = blobs
        self.host = host
        self.port = port
        self.auth = auth
        self.tls = tls
        self.broadcaster = broadcaster
    }

    public func run() async throws {
        let router = Router()
        router.add(middleware: HMACAuthMiddleware(auth: auth))
        Self.registerRoutes(
            on: router,
            deviceID: deviceID,
            blobs: blobs,
            sinceAPI: SinceAPI(database: database)
        )

        let serverConfig = ApplicationConfiguration(
            address: .hostname(host, port: port),
            serverName: "duo-paste"
        )

        // PR 3：broadcaster 非 nil → 启用 WebSocket upgrade 路径。WS 路由独立 Router
        // (BasicWebSocketRequestContext)，通过 `http1WebSocketUpgrade(webSocketRouter:)`
        // 让 server 同时接 HTTP /since /blob /health + WS /sync/ws
        if let broadcaster {
            let wsRouter = Self.makeWebSocketRouter(
                auth: auth,
                deviceID: deviceID,
                database: database,
                broadcaster: broadcaster
            )
            let serverBuilder: HTTPServerBuilder
            if let tls {
                let tlsConfig = try Self.makeTLSConfiguration(certPath: tls.certPath, keyPath: tls.keyPath)
                serverBuilder = try .tls(
                    .http1WebSocketUpgrade(webSocketRouter: wsRouter),
                    tlsConfiguration: tlsConfig
                )
            } else {
                serverBuilder = .http1WebSocketUpgrade(webSocketRouter: wsRouter)
            }
            let app = Application(
                router: router,
                server: serverBuilder,
                configuration: serverConfig
            )
            try await app.runService()
            return
        }

        if let tls {
            let tlsConfig = try Self.makeTLSConfiguration(certPath: tls.certPath, keyPath: tls.keyPath)
            let app = Application(
                router: router,
                server: try .tls(.http1(), tlsConfiguration: tlsConfig),
                configuration: serverConfig
            )
            try await app.runService()
        } else {
            let app = Application(router: router, configuration: serverConfig)
            try await app.runService()
        }
    }

    /// 构造 WebSocket 路由。`/sync/ws` Upgrade 走 HMACAuthMiddleware 认证（沿用 HTTP 同款，
    /// `<ts>\nGET\n/sync/ws\n<emptyHash>` 签名）；Upgrade 后注册到 broadcaster + 立刻
    /// 发一条 hello 让 client 拿 baseline cursor。
    ///
    /// **server 配置 autoPing 30s**：跟 client 端 heartbeat 配对——客户端 30s 没收到任何帧
    /// (含 server 主动 PING) 会自动断开，降级为周期 pull。
    ///
    /// inbound 当前不消费 client → server 帧（client 不发业务消息），但要 for-await 跑完
    /// inbound 才能让 close 信号传播；defer unregister 保证连接关闭时 broadcaster 清理。
    static func makeWebSocketRouter(
        auth: HMACAuth,
        deviceID: String,
        database: DuoPasteCore.Database,
        broadcaster: WSBroadcaster
    ) -> Router<BasicWebSocketRequestContext> {
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.middlewares.add(HMACAuthMiddleware<BasicWebSocketRequestContext>(auth: auth))
        wsRouter.ws("/sync/ws") { _, _ in
            .upgrade([:])
        } onUpgrade: { inbound, outbound, _ in
            // Hello：发出 baseline cursor。失败（连接已关）即 return，let onUpgrade 自然退出
            let helloLatest = (try? await database.currentMaxIngestedNs()) ?? 0
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let hello = WSMessage.hello(
                version: WSMessage.currentVersion,
                deviceID: deviceID,
                nowMs: nowMs,
                latestIngestedAtNs: helloLatest
            )
            do {
                try await outbound.write(.text(hello.encodeJSON()))
            } catch {
                FileHandle.standardError.write(Data("ws server hello write failed: \(error)\n".utf8))
                return
            }

            // 注册到 broadcaster；onSlowKick 触发 outbound close 让 inbound 尽快收尾
            let connID = await broadcaster.register(
                writer: outbound,
                peerHint: nil,
                onSlowKick: { /* hbws 没有 channel-level cancel；2s 超时实际靠 write 抛错触发 inbound 退出 */ }
            )
            defer {
                Task { await broadcaster.unregister(connID) }
            }

            // inbound for-await：消耗 client 端发的任何帧（当前协议 client 不主动发，
            // 但跑完 stream 让 close 帧能传播 + autoPing pong 自动处理）
            do {
                for try await _ in inbound.messages(maxSize: 64 * 1024) {
                    // 当前协议 client → server 无业务消息；忽略
                }
            } catch {
                // inbound 抛错（连接异常 / autoPing 超时 / decode 失败）→ 让 onUpgrade 返回，
                // hbws 自动关闭底层 channel。defer 清理 broadcaster
            }
        }
        return wsRouter
    }

    /// 从 PEM 文件加载 cert chain + private key，构造 NIOSSL ServerConfiguration。
    /// `tailscale cert <hostname>` 产出的 .crt 和 .key 直接喂进来即可——
    /// crt 是 hostname + 中间 + 根的拼接 chain，key 是对应私钥。
    static func makeTLSConfiguration(certPath: String, keyPath: String) throws -> TLSConfiguration {
        let certs = try NIOSSLCertificate.fromPEMFile(certPath)
        let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
        return TLSConfiguration.makeServerConfiguration(
            certificateChain: certs.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
    }

    /// 内部抽出来便于将来加路由 + 单测。
    /// PR 6 之后只剩 mesh peer 间的 GET 路由：health / blob / since。
    /// `/ingest` + PUT/HEAD `/blob` 已删（PR 4，mesh 拓扑下不再有 "client → primary push"），
    /// `/search` 也删（PR 6，每台 mac 自家 SearchAPI 走 fold-aware 算就够，对端永远口径一致）
    static func registerRoutes<Ctx: RequestContext>(
        on router: Router<Ctx>,
        deviceID: String,
        blobs: BlobStore,
        sinceAPI: SinceAPI
    ) {
        router.get("/health") { _, _ -> Response in
            let payload: [String: String] = [
                "ok": "true",
                "device_id": deviceID,
                "now_ms": String(Int64(Date().timeIntervalSince1970 * 1000)),
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
            resp.headers[.contentType] = "application/json"
            return resp
        }

        // GET /blob/{sha256}：取 blob bytes。
        router.get("/blob/:sha256") { _, context -> Response in
            guard let sha = context.parameters.get("sha256"), Self.isValidSha256(sha) else {
                return errorJSON(.badRequest, "sha256 格式非法")
            }
            do {
                guard let data = try blobs.read(sha256: sha) else {
                    return Response(status: .notFound)
                }
                var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                resp.headers[.contentType] = "application/octet-stream"
                return resp
            } catch {
                return errorJSON(.internalServerError, "blob read failed: \(error)")
            }
        }

        // GET /since?cursor_ns=<int>&cursor_id=<str>&limit=<int>
        // 按 (ingested_at_ns, id) ASC 增量返回 item 表。空 cursor → 从头全量拉。
        // 包含软删行（mirror 需要 replay deletion）；过滤 ingested_at_ns IS NULL。
        // 响应：{ ok, items:[...], next_cursor:{ingested_at_ns,id}, has_more }
        router.get("/since") { request, _ -> Response in
            let q = parseSinceQuery(request.uri.queryParameters)
            do {
                let page = try sinceAPI.fetch(q)
                let payload: [String: Any] = [
                    "ok": true,
                    "count": page.items.count,
                    "items": page.items.map(itemToJSON),
                    "next_cursor": [
                        "ingested_at_ns": page.nextCursor.ingestedAtNs,
                        "id": page.nextCursor.id,
                    ],
                    "has_more": page.hasMore,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                resp.headers[.contentType] = "application/json"
                return resp
            } catch {
                return errorJSON(.internalServerError, "since failed: \(error)")
            }
        }

    }

    /// 把 URL query 参数转成 SinceQuery。空 cursor_ns / 非法值 → 视作从头拉。
    /// limit 在 parse 层 clamp 到 [1, SinceAPI.maxLimit]，避免 wire 接受 0 / 巨大值
    /// （SinceAPI 内还有 clamp 兜底，是纵深防御）。
    static func parseSinceQuery(_ params: FlatDictionary<Substring, Substring>) -> SinceQuery {
        let cursorNs = params["cursor_ns"].flatMap { Int64($0) } ?? 0
        let cursorID = params["cursor_id"].map(String.init) ?? ""
        let rawLimit = params["limit"].flatMap { Int($0) } ?? SinceAPI.defaultLimit
        let limit = max(1, min(rawLimit, SinceAPI.maxLimit))
        return SinceQuery(
            cursor: SinceCursor(ingestedAtNs: cursorNs, id: cursorID),
            limit: limit
        )
    }

    /// 把 Item 转成 JSON-serializable dict。直接 Item.Codable 也行，但走 dict
    /// 让 [String: Any] 嵌套结构均匀，避免混编 Data 跟 dict。
    private static func itemToJSON(_ item: Item) -> [String: Any] {
        var d: [String: Any] = [
            "id": item.id,
            "origin_device": item.originDevice,
            "captured_at_ns": item.capturedAtNs,
            "kind": item.kind.rawValue,
            // Item.Codable 期望 Bool；不能给 0/1 否则客户端解码报 typeMismatch
            "pinned": item.pinned,
        ]
        if let v = item.ingestedAtNs   { d["ingested_at_ns"] = v }
        if let v = item.sourceApp      { d["source_app"] = v }
        if let v = item.sourceAppName  { d["source_app_name"] = v }
        if let v = item.preview        { d["preview"] = v }
        if let v = item.textFull       { d["text_full"] = v }
        if let v = item.blobSha256     { d["blob_sha256"] = v }
        if let v = item.blobSize       { d["blob_size"] = v }
        if let v = item.blobMime       { d["blob_mime"] = v }
        if let v = item.deletedAtNs    { d["deleted_at_ns"] = v }
        if let v = item.ocrState       { d["ocr_state"] = v.rawValue }
        return d
    }

    private static func isValidSha256(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { c in
            c.isASCII && (c.isNumber || ("a"..."f").contains(c) || ("A"..."F").contains(c))
        }
    }

    private static func errorJSON(_ status: HTTPResponse.Status, _ msg: String) -> Response {
        let payload: [String: Any] = ["ok": false, "error": msg]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        var resp = Response(status: status, body: .init(byteBuffer: .init(bytes: data)))
        resp.headers[.contentType] = "application/json"
        return resp
    }
}

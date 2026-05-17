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

    /// `/health` 响应里 `ponte_host` 字段的来源。生产路径 = SurgePonte 自动发现；
    /// 测试可注入固定值（避免依赖 dev mac 是否装了 Surge / 配了 Ponte）
    public let ponteHostProvider: @Sendable () -> String?

    /// `/app_icon/<bundleID>` 路由背后的 store。nil → 路由 503(daemon 没启用 icon 服务,
    /// 比如测试环境)。daemon 启动时构造好注入,内部 resolver 闭包从 AppKit 拿 NSWorkspace.icon
    public let appIconStore: AppIconStore?

    public init(
        deviceID: String,
        database: DuoPasteCore.Database,
        blobs: BlobStore,
        host: String,
        port: Int,
        auth: HMACAuth,
        tls: TLSPaths? = nil,
        broadcaster: WSBroadcaster? = nil,
        ponteHostProvider: @escaping @Sendable () -> String? = { SurgePonte.discoverSelfHostname() },
        appIconStore: AppIconStore? = nil
    ) {
        self.deviceID = deviceID
        self.database = database
        self.blobs = blobs
        self.host = host
        self.port = port
        self.auth = auth
        self.tls = tls
        self.broadcaster = broadcaster
        self.ponteHostProvider = ponteHostProvider
        self.appIconStore = appIconStore
    }

    public func run() async throws {
        let router = Router()
        router.add(middleware: HMACAuthMiddleware(auth: auth))
        // 启动时一次性发现本机 Surge Ponte 主机名（没装 Surge → nil）。结果常驻 server 生命周期，
        // 不每个 /health 重读 plist。SGCore.plist 真改了要重启 daemon 才会刷新，可接受——
        // Surge 配置变更本来就属于运维事件
        let pontePeerHost = ponteHostProvider()
        Self.registerRoutes(
            on: router,
            deviceID: deviceID,
            database: database,
            blobs: blobs,
            sinceAPI: SinceAPI(database: database),
            ponteHost: pontePeerHost,
            appIconStore: appIconStore,
            broadcaster: broadcaster
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

            // inbound for-await：消耗 client 端发的应用层帧。
            // - **应用层 ping → pong**：iOS URLSessionWebSocketTask 不暴露协议层 PING（hbws
            //   `autoPing` 在 WebSocket 协议层透明跑），iOS client 走 `WSMessage.ping` 文本帧
            //   做 zombie 检测；这里解码 + 回 `WSMessage.pong` 让 client 看到对端活着。
            // - 其他类型（client 不应该发，但收到 noop 兼容）
            // - 跑完 stream 让 close 帧能传播 + autoPing pong 自动处理
            do {
                for try await message in inbound.messages(maxSize: 64 * 1024) {
                    guard case .text(let s) = message else { continue }
                    let wsmsg: WSMessage
                    do { wsmsg = try WSMessage.decodeJSON(s) }
                    catch { continue }  // 未知 / 损坏帧 → noop（防止 client bug 拖垮 server）
                    if case .ping = wsmsg {
                        let pong = WSMessage.pong(version: WSMessage.currentVersion)
                        do {
                            try await outbound.write(.text(try pong.encodeJSON()))
                        } catch {
                            FileHandle.standardError.write(Data("ws server pong write failed: \(error)\n".utf8))
                            return
                        }
                    }
                    // .pong / .hello / .cursorAdvanced from client → 当前协议无业务用途
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
        database: DuoPasteCore.Database,
        blobs: BlobStore,
        sinceAPI: SinceAPI,
        ponteHost: String? = nil,
        appIconStore: AppIconStore? = nil,
        broadcaster: WSBroadcaster? = nil
    ) {
        router.get("/health") { _, _ -> Response in
            var payload: [String: String] = [
                "ok": "true",
                "device_id": deviceID,
                "now_ms": String(Int64(Date().timeIntervalSince1970 * 1000)),
            ]
            // 本机 Surge Ponte 主机名——告诉对端"用这个名字找我"。没装 Surge 就不写这个键，
            // 对端 decode 时把它当 optional 处理
            if let ponteHost {
                payload["ponte_host"] = ponteHost
            }
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

        // GET /app_icon/{bundleID}：返回 macOS app icon PNG 字节。
        // bundleID 含点(com.apple.Safari),: 不含,不需要 URL 编码。
        // 未配 appIconStore → 503;app 没装 → 404;命中 → image/png 字节
        if let store = appIconStore {
            router.get("/app_icon/:bundle_id") { _, context -> Response in
                guard let bid = context.parameters.get("bundle_id"), !bid.isEmpty else {
                    return errorJSON(.badRequest, "missing bundle_id")
                }
                do {
                    guard let bytes = try await store.iconPNG(forBundleID: bid) else {
                        return Response(status: .notFound)
                    }
                    var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: bytes)))
                    resp.headers[.contentType] = "image/png"
                    // icon 字节不常变(app 升级后才换),客户端 cache 1 天降无效请求量。
                    // bundleID 不在 cache key 里(URL 已含),浏览器 / URLSession 自动区分
                    resp.headers[.cacheControl] = "public, max-age=86400"
                    return resp
                } catch {
                    return errorJSON(.internalServerError, "app_icon lookup failed: \(error)")
                }
            }
        }

        // GET /since?cursor_ns=<int>&cursor_id=<str>&limit=<int>
        // 按 (ingested_at_ns, id) ASC 增量返回 item 表。空 cursor → 从头全量拉。
        // 包含软删行（mirror 需要 replay deletion）；过滤 ingested_at_ns IS NULL。
        // 响应：{ ok, items:[...], next_cursor:{ingested_at_ns,id}, has_more }
        // POST /bump/{id}:把单行 captured_at_ns + ingested_at_ns 顶到当前最大。
        // 让"复制即顶"跨设备一致——iOS tap 自己历史里某条 → POST /bump → Mac DB 改 →
        // broadcaster 推 cursor_advanced → 其他 peer < 1s 看到这条在最前。
        //
        // 不接受 body(空 body hash),id 在 path 里被 HMAC 签名所覆盖。HMAC ts 窗口
        // (默认 30s)兜底防 replay——精确的"幂等单次 bump" 由 sender 自己决定(剪贴板
        // 心智:同 id 多次 bump 等价单次,因为每次都把 captured_at_ns 顶到 now)
        router.post("/bump/:id") { request, context -> Response in
            guard let id = context.parameters.get("id"), !id.isEmpty else {
                return errorJSON(.badRequest, "missing id")
            }
            // 二次校验 body 跟 header 一致——middleware 不读 body,handler 自己再 sha 比对
            // 防"合法签名 + 任意 body"绕过(虽然这个路由不读 body,但保持跟 /blob 同款防御)
            let bodyBuf = try await request.body.collect(upTo: 16 * 1024)
            let bodyHash = HMACAuth.sha256Hex(Data(buffer: bodyBuf))
            let headerHash = request.headers[HTTPField.Name(HMACAuth.bodyHashHeader)!]?.lowercased() ?? ""
            guard headerHash == bodyHash else {
                return errorJSON(.unauthorized, "body sha mismatch")
            }
            let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            do {
                let newIngest = try await database.bumpCapturedAt(id: id, now: now)
                // 通知 peer:本机 cursor 推进了。fan-out 失败 swallow——bump 本身已落库
                if let broadcaster {
                    Task {
                        await broadcaster.broadcastCursorAdvanced(
                            deviceID: deviceID,
                            latestIngestedAtNs: newIngest
                        )
                    }
                }
                let payload: [String: Any] = ["ok": true, "ingested_at_ns": newIngest]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                resp.headers[.contentType] = "application/json"
                return resp
            } catch BumpError.notFound {
                return errorJSON(.notFound, "item not found")
            } catch BumpError.deleted {
                return errorJSON(.gone, "item is tombstoned")
            } catch {
                return errorJSON(.internalServerError, "bump failed: \(error)")
            }
        }

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
        if let v = item.extractedText  { d["extracted_text"] = v }
        if let v = item.extractedTextSource { d["extracted_text_source"] = v.rawValue }
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

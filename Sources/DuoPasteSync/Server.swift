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

    /// `GET /endpoints` 路由的候选 list 来源。AppDelegate 启动时注入(读 config + SurgePonte +
    /// hostname),变化时调 `setEndpointsProvider` 更新让下次请求返新值。nil → 路由 503
    public let endpointsProvider: @Sendable () -> [PeerEndpoint]

    /// Mesh-wide endpoints 聚合 snapshot 提供者。daemon 启动时 AppDelegate 注入这个
    /// 闭包,内部 forward 到 `MeshEndpointsCache.snapshot()`。闭包模式让 SyncServer 可以
    /// 在 supervisor 还没起来时就启动,后续 MeshEndpointsCache 创建后 closure 才返实际值
    public let meshEndpointsProvider: @Sendable () async -> [MeshPeerEntry]?

    /// `POST /pair/<pin>` 路由背后的 PIN 验证 + secret 返回服务。nil → 路由 503(daemon
    /// 没启用 pairing)
    public let pairingService: PairingService?

    /// 本机 HTTP `/bump` / `DELETE /item` / `POST /pin` 落库后的回调——签名 (id, newIngestedAtNs)。
    /// Mac daemon 用它刷新本机 UI(让 SearchView 即时反映"复制即顶"/"刚删"/"刚切 pin")。
    /// **noop 路径不调**:setPinnedAny 已是目标状态时返 nil,handler 不调 onItemMutated
    /// 测试/headless server 默认 no-op。WS broadcaster 只通知 peer,不会自动刷新本进程 SwiftUI state。
    public let onItemMutated: @Sendable (String, Int64) -> Void

    /// `/pair/<pin>` 路由是否要求本机起 TLS。默 true。
    ///
    /// **为什么硬护栏**：/pair response body 含 `secret: hex` 明文（iOS 拿来当 HMAC 主密钥）。
    /// 当 daemon 跑 plain HTTP（`tls == nil`），即便 PIN 单次有效 + 5 次封锁，secret 仍会
    /// 落到任意 LAN 中间人手里（咖啡馆 AP / 公司透明代理 / 路由器被攻陷场景）。Tailscale
    /// 网络下走 WG 加密所以 plain HTTP 也安全，但 iOS 配对路径常走 .local 或直连 IP——
    /// 不走 tailnet，必须 TLS 兜底
    ///
    /// 测试场景可显式传 false opt-out（同进程 in-loop 没攻击面）
    public let requirePairingTLS: Bool

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
        appIconStore: AppIconStore? = nil,
        endpointsProvider: @escaping @Sendable () -> [PeerEndpoint] = { [] },
        meshEndpointsProvider: @escaping @Sendable () async -> [MeshPeerEntry]? = { nil },
        pairingService: PairingService? = nil,
        onItemMutated: @escaping @Sendable (String, Int64) -> Void = { _, _ in },
        requirePairingTLS: Bool = true
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
        self.endpointsProvider = endpointsProvider
        self.meshEndpointsProvider = meshEndpointsProvider
        self.pairingService = pairingService
        self.onItemMutated = onItemMutated
        self.requirePairingTLS = requirePairingTLS
        // 显式配 pairingService 但跑 plain HTTP 且未 opt-out → 启动时即拉响警报，
        // 不要等 /pair 真被打了才拒。运维侧能立刻看到 stderr 修配置
        if requirePairingTLS, tls == nil, pairingService != nil {
            FileHandle.standardError.write(Data(
                "WARN: /pair enabled on plain HTTP — secret would leak in plaintext; route will return 503 until TLS is configured\n".utf8
            ))
        }
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
            searchAPI: SearchAPI(database: database),
            ponteHost: pontePeerHost,
            appIconStore: appIconStore,
            broadcaster: broadcaster,
            endpointsProvider: endpointsProvider,
            meshEndpointsProvider: meshEndpointsProvider,
            pairingService: pairingService,
            // requirePairingTLS=true 且本机没起 TLS → handler 直接 503 不消耗 PIN
            pairingDisabled: (requirePairingTLS && tls == nil),
            onItemMutated: onItemMutated
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
        /// PR P0-2 重新加上的 fold-aware 搜索路径,给 iOS client 用——本机 SearchAPI 走
        /// fold-aware 算,跨 origin 同 text 折一条,口径跟本机搜索一致。
        /// PR 6 删的是"primary 拓扑 client 走远端搜索"的语义,mesh 下这条路重新有意义:
        /// iOS 没有自己的 GRDB/FTS5,委托给已连的 Mac peer 跑全文搜索
        searchAPI: SearchAPI,
        ponteHost: String? = nil,
        appIconStore: AppIconStore? = nil,
        broadcaster: WSBroadcaster? = nil,
        endpointsProvider: @escaping @Sendable () -> [PeerEndpoint] = { [] },
        meshEndpointsProvider: @escaping @Sendable () async -> [MeshPeerEntry]? = { nil },
        pairingService: PairingService? = nil,
        /// /pair 路由禁用（不消耗 PIN，直接 503）。生产路径在 SyncServer.init 内根据
        /// `requirePairingTLS && tls == nil` 推导——plain HTTP daemon 不该暴露 secret 明文。
        /// 测试场景默 false 不动行为
        pairingDisabled: Bool = false,
        onItemMutated: @escaping @Sendable (String, Int64) -> Void = { _, _ in }
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
            // 防"合法签名 + 任意 body"绕过(虽然这个路由不读 body,但保持纵深防御)
            let bodyBuf = try await request.body.collect(upTo: 16 * 1024)
            let bodyHash = HMACAuth.sha256Hex(Data(buffer: bodyBuf))
            // HTTPField.Name 失败仅当 header name 含非法字符——`X-DP-Body-SHA256` 是
            // 编译时常量串, init 不该 fail。但用 guard let 替 force unwrap 让 future-self
            // 改常量名时不至于 daemon 启动 crash
            guard let bodyHashHeaderName = HTTPField.Name(HMACAuth.bodyHashHeader) else {
                return errorJSON(.internalServerError, "invalid body-hash header name constant")
            }
            let headerHash = request.headers[bodyHashHeaderName]?.lowercased() ?? ""
            guard headerHash == bodyHash else {
                return errorJSON(.unauthorized, "body sha mismatch")
            }
            let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            do {
                let newIngest = try await database.bumpCapturedAt(id: id, now: now)
                onItemMutated(id, newIngest)
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

        // DELETE /item/{id}:软删单行(设 deleted_at_ns + bump ingested_at_ns 让 /since
        // 推 tombstone 给 peer)。iOS 长按"删除"路径专用——Mac 端 capture 路径不走这里,
        // retention sweeper 跟用户主动删除分开。
        //
        // 不接受 body(空 body hash),id 在 path 里被 HMAC 签名所覆盖。已 tombstoned 行
        // 返 410(iOS 当幂等成功处理),未知 id 返 404。
        router.delete("/item/:id") { request, context -> Response in
            guard let id = context.parameters.get("id"), !id.isEmpty else {
                return errorJSON(.badRequest, "missing id")
            }
            // 二次校验 body 跟 header 一致——middleware 不读 body,handler 自己再 sha 比对
            // (镜像 /bump 路径,纵深防御。DELETE 通常无 body 但仍要 drain + 校验)
            let bodyBuf = try await request.body.collect(upTo: 16 * 1024)
            let bodyHash = HMACAuth.sha256Hex(Data(buffer: bodyBuf))
            guard let bodyHashHeaderName = HTTPField.Name(HMACAuth.bodyHashHeader) else {
                return errorJSON(.internalServerError, "invalid body-hash header name constant")
            }
            let headerHash = request.headers[bodyHashHeaderName]?.lowercased() ?? ""
            guard headerHash == bodyHash else {
                return errorJSON(.unauthorized, "body sha mismatch")
            }
            let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            do {
                let newIngest = try await database.softDelete(id: id, now: now)
                onItemMutated(id, newIngest)
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
            } catch BumpError.alreadyDeleted {
                return errorJSON(.gone, "item already tombstoned")
            } catch {
                return errorJSON(.internalServerError, "delete failed: \(error)")
            }
        }

        // POST /pin/{id}?pinned=1|0:切换 item.pinned。跨 origin 生效(走
        // database.setPinnedAny,不带 own-origin guard,跟 /bump /item DELETE 心智一致)。
        // iOS 长按"置顶/取消置顶"路径专用。**Mac UI 路径**(AppState.togglePin / SearchView
        // contextMenu / ⌘P)走进程内 database.setPinnedAny + broadcaster fan-out 同款语义,
        // 不走 HTTP 自环;严格 own-origin 变体 database.setPinned 现状无生产调用。
        //
        // query 里读 pinned:`pinned=1` → 置顶,`pinned=0` → 取消。空 / 其它值返 400。
        // 不接受 body(空 body hash),id 跟 query 都被 HMAC 签名所覆盖。已是目标状态返 200
        // (handler 当幂等成功),已 tombstoned 返 410,未知 id 返 404。
        //
        // **已知 limitation**(完整列表写在 setPinnedAny doc):跨 origin pin 不回传 origin
        // 设备 + origin 后续任何 ingested_at_ns bump 会通过 /since INSERT OR REPLACE 把
        // 其他 mirror peer 上跨 origin 打的 pin 静默抹掉。本机 fold 路径"pinned OR 聚合"
        // 让搜索语义本机 + 其他 mirror peer 一致(但不能 hold 住 origin 后续 mutation 的覆盖)
        router.post("/pin/:id") { request, context -> Response in
            guard let id = context.parameters.get("id"), !id.isEmpty else {
                return errorJSON(.badRequest, "missing id")
            }
            // query 解析放 body 校验之前——能在签名校验前快速 reject 明显畸形请求
            // (签名是中间件已校验过的,handler 这里只做内容/参数校验)
            let pinnedQ = request.uri.queryParameters.get("pinned").map { String($0) } ?? ""
            let pinned: Bool
            switch pinnedQ {
            case "1": pinned = true
            case "0": pinned = false
            default:
                return errorJSON(.badRequest, "pinned must be 0 or 1")
            }
            let bodyBuf = try await request.body.collect(upTo: 16 * 1024)
            let bodyHash = HMACAuth.sha256Hex(Data(buffer: bodyBuf))
            guard let bodyHashHeaderName = HTTPField.Name(HMACAuth.bodyHashHeader) else {
                return errorJSON(.internalServerError, "invalid body-hash header name constant")
            }
            let headerHash = request.headers[bodyHashHeaderName]?.lowercased() ?? ""
            guard headerHash == bodyHash else {
                return errorJSON(.unauthorized, "body sha mismatch")
            }
            let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            do {
                // setPinnedAny 已是目标状态 → 返回 nil。当幂等成功处理：不 fan-out 也不
                // 推 cursor_advanced(因为本机 ingested_at_ns 没动)。response 仍 200 让
                // iOS 端把 UI 跟 server 状态对齐
                let newIngest = try await database.setPinnedAny(id: id, pinned: pinned, now: now)
                if let newIngest {
                    onItemMutated(id, newIngest)
                    if let broadcaster {
                        Task {
                            await broadcaster.broadcastCursorAdvanced(
                                deviceID: deviceID,
                                latestIngestedAtNs: newIngest
                            )
                        }
                    }
                    let payload: [String: Any] = ["ok": true, "ingested_at_ns": newIngest, "pinned": pinned]
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                    var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                    resp.headers[.contentType] = "application/json"
                    return resp
                } else {
                    // noop:已是目标状态。**不** onItemMutated / broadcaster fan-out ——
                    // ingested_at_ns 没动,对端 /since 看不到新东西,推 cursor_advanced 等于
                    // 浪费 RTT 让 peer pull 空页。响应仍带 pinned 让 client 对齐 UI
                    let payload: [String: Any] = ["ok": true, "pinned": pinned, "noop": true]
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                    var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                    resp.headers[.contentType] = "application/json"
                    return resp
                }
            } catch BumpError.notFound {
                return errorJSON(.notFound, "item not found")
            } catch BumpError.deleted {
                return errorJSON(.gone, "item is tombstoned")
            } catch {
                return errorJSON(.internalServerError, "pin failed: \(error)")
            }
        }

        // POST /pair/{pin}:iOS PIN 配对入口。**无 HMAC**(AuthMiddleware 白名单跳过)。
        // 校验 PIN → 原子返回 shared-secret hex + 当前 endpoints page。
        //
        // 安全:
        // - PIN 单次有效 + 60s expiry + 5 次错误封锁(都在 PairingService 里)
        // - 路径里 pin 是 6 位数字,长度上限校验后才比对
        // - secret 以 hex 文本明文返回—— TLS 信任完整性 + 用户主动展示 PIN 才有 session
        //
        // 关键语义:
        // - endpoints 必须跟 secret 同一个响应返回。不要让 iOS 在 PIN 被消费后再二次
        //   GET /endpoints；那一步失败会造成 Mac 显示成功、iOS 显示失败，且 PIN 已不可重试。
        router.post("/pair/:pin") { request, context -> Response in
            // TLS 护栏：plain HTTP daemon 不该暴露 secret 明文。`pairingDisabled` 由调用方
            // 推导（生产 = SyncServer 检测 `requirePairingTLS && tls == nil`）。在 PIN 校验
            // **之前**就返 503——拒消耗 PIN，避免攻击者通过观察"是否 503"探测部署 TLS 状态
            // 后再针对性发包。response 也要诚实告诉用户为什么（运维侧排错友好）
            if pairingDisabled {
                return errorJSON(.serviceUnavailable, "pairing requires HTTPS")
            }
            guard let service = pairingService else {
                return errorJSON(.serviceUnavailable, "pairing disabled")
            }
            guard let pin = context.parameters.get("pin"),
                  pin.count == 6,
                  pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return errorJSON(.badRequest, "pin must be 6 digits")
            }
            // body 必须空(或忽略)——drain 避免 hbws 投诉
            _ = try? await request.body.collect(upTo: 1024)
            do {
                let secret = try await service.validateAndConsumePIN(pin)
                let hex = secret.map { String(format: "%02x", $0) }.joined()
                let page = PeerEndpointsPage(
                    deviceID: deviceID,
                    endpoints: endpointsProvider(),
                    updatedAtUnix: Int64(Date().timeIntervalSince1970),
                    meshPeers: await meshEndpointsProvider()
                )
                let payload = PairResponseWire(
                    ok: true,
                    secret: hex,
                    deviceID: deviceID,
                    endpointsPage: page
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(payload)
                var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                resp.headers[.contentType] = "application/json"
                return resp
            } catch PairingService.Error.pinMismatch {
                return errorJSON(.unauthorized, "pin mismatch")
            } catch PairingService.Error.pinExpired {
                return errorJSON(.gone, "pin expired")
            } catch PairingService.Error.rateLimited {
                return errorJSON(.tooManyRequests, "too many attempts")
            } catch PairingService.Error.noActiveSession {
                return errorJSON(.notFound, "no active pairing session")
            } catch {
                return errorJSON(.internalServerError, "pair failed: \(error)")
            }
        }

        // GET /endpoints:返回本机当前所有可达 URL 候选 + 整个 mesh 其他 peer 的候选。
        // 给 iOS 端 EndpointPicker 并发探活确认可达,再按 Mac hint / route 策略选连接。
        //
        // - `endpoints`:本机 self 候选(Tailscale / Ponte / .local)由 endpointsProvider 算
        // - `mesh_peers`:hub Mac 周期从其他 mesh peer 拉的 endpoints 聚合(Phase B);
        //   nil = 单机部署 / 测试场景
        //
        // **HMAC 认证**——iOS 必须先有 secret(PIN 配对走 /pair 拿)才能查 endpoints。
        // 防止网络上的扫描者列举本机服务边界。
        router.get("/endpoints") { _, _ -> Response in
            let list = endpointsProvider()
            let mesh = await meshEndpointsProvider()
            let page = PeerEndpointsPage(
                deviceID: deviceID,
                endpoints: list,
                updatedAtUnix: Int64(Date().timeIntervalSince1970),
                meshPeers: mesh
            )
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(page)
                var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                resp.headers[.contentType] = "application/json"
                return resp
            } catch {
                return errorJSON(.internalServerError, "endpoints encode failed: \(error)")
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

        // GET /search?q=<text>&limit=<n>&offset=<n>
        // iOS client 用——本机没有 GRDB/FTS5,委托给配对的 Mac peer 跑 fold-aware 搜索。
        // 走 SearchAPI.searchHits + count,跟 Mac UI 用同一份逻辑,跨设备 chip 总数对齐
        //
        // 响应:{ ok, count, items:[{...item fields..., snippet?}] }
        // - count:fold 后 limit/offset 之前的真实总数(UI 显"共 N 条")
        // - items.snippet:含 STX/ETX(0x02/0x03) 控制字符的高亮片段,iOS 端切片渲染加粗。
        //   query 为空(纯列表)时 snippet 不附,客户端按缺省处理
        router.get("/search") { request, _ -> Response in
            let q = parseSearchQuery(request.uri.queryParameters)
            do {
                // 单次 fold-aware pass 拿 hits + total——别走 `searchHits + count` 双跑
                // 路径(fetchHitsFolded 跑两遍,大 DB 时浪费)。等价性靠 SearchAPI 内部保证
                let (hits, total) = try searchAPI.searchHitsAndCount(q)
                let items = hits.map { (item, snippet) -> [String: Any] in
                    var d = itemToJSON(item)
                    if let s = snippet { d["snippet"] = s }
                    return d
                }
                let payload: [String: Any] = [
                    "ok": true,
                    "count": total,
                    "items": items,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                resp.headers[.contentType] = "application/json"
                return resp
            } catch {
                return errorJSON(.internalServerError, "search failed: \(error)")
            }
        }

    }

    /// 把 URL query 参数转成 SearchQuery。`q` 为空 → 纯列表(按时间倒序+pinned-first);
    /// 非空 → FTS5 全文搜索 + fold。limit clamp [1, 500] 防巨页拖垮 iOS 端解码。
    /// **不支持** kinds / pinnedOnly / 时间范围参数(iOS 一期就只要全文搜索 + 列表);
    /// 后续要 chip 时再加 query 参数,不破坏现有路径
    static func parseSearchQuery(_ params: FlatDictionary<Substring, Substring>) -> SearchQuery {
        let q = params["q"].map(String.init) ?? ""
        let rawLimit = params["limit"].flatMap { Int($0) } ?? 200
        let limit = max(1, min(rawLimit, 500))
        let rawOffset = params["offset"].flatMap { Int($0) } ?? 0
        let offset = max(0, rawOffset)
        return SearchQuery(
            text: q.isEmpty ? nil : q,
            limit: limit,
            offset: offset
        )
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

private struct PairResponseWire: Encodable {
    let ok: Bool
    let secret: String
    let deviceID: String
    let endpointsPage: PeerEndpointsPage

    enum CodingKeys: String, CodingKey {
        case ok
        case secret
        case deviceID = "device_id"
        case endpointsPage = "endpoints_page"
    }
}

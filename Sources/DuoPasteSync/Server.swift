import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
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
    /// `POST /ingest` body 上限。单条 item 含 text_full + 元数据，
    /// 1 MB 已经远超任何剪贴文本场景；blob 走单独路由。
    public static let ingestBodyLimit = 1 * 1024 * 1024
    /// `PUT /blob/{sha256}` body 上限。64 MB 给图片留充裕余地，挡住 OOM 攻击面。
    public static let blobBodyLimit = 64 * 1024 * 1024

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
        tls: TLSPaths? = nil
    ) {
        self.deviceID = deviceID
        self.database = database
        self.blobs = blobs
        self.host = host
        self.port = port
        self.auth = auth
        self.tls = tls
    }

    public func run() async throws {
        let router = Router()
        router.add(middleware: HMACAuthMiddleware(auth: auth))
        Self.registerRoutes(
            on: router,
            deviceID: deviceID,
            ingester: RemoteIngester(database: database),
            blobs: blobs,
            searchAPI: SearchAPI(database: database)
        )

        let serverConfig = ApplicationConfiguration(
            address: .hostname(host, port: port),
            serverName: "duo-paste"
        )

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
    static func registerRoutes<Ctx: RequestContext>(
        on router: Router<Ctx>,
        deviceID: String,
        ingester: RemoteIngester,
        blobs: BlobStore,
        searchAPI: SearchAPI
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

        router.post("/ingest") { request, _ -> Response in
            // Middleware 只验了 header 上的 hash。Handler 读完真 body 必须再算一次，
            // 否则攻击者能配一个合法签名但发任意 body（攻击模型见 Auth.swift 注释）。
            let bodyBuffer = try await request.body.collect(upTo: ingestBodyLimit)
            let bodyData = Data(buffer: bodyBuffer)
            let actualHash = HMACAuth.sha256Hex(bodyData)
            let headerHashName = HTTPField.Name(HMACAuth.bodyHashHeader)!
            let claimedHash = request.headers[headerHashName]?.lowercased() ?? ""
            guard actualHash == claimedHash else {
                return errorJSON(.badRequest, "body sha256 不匹配 X-DP-Body-SHA256")
            }

            let req: IngestRequest
            do {
                req = try JSONDecoder().decode(IngestRequest.self, from: bodyData)
            } catch {
                return errorJSON(.badRequest, "JSON 解码失败: \(error)")
            }
            let result: RemoteIngester.Result
            do {
                result = try await ingester.ingest(req)
            } catch let e as IngestError {
                return errorJSON(.badRequest, e.description)
            } catch {
                return errorJSON(.internalServerError, "ingest 内部错误: \(error)")
            }
            let payload: [String: Any] = [
                "ok": true,
                "id": result.id,
                "ingested_at_ns": result.ingestedAtNs,
                "was_new": result.wasNew,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
            resp.headers[.contentType] = "application/json"
            return resp
        }

        // HEAD /blob/{sha256}：探测是否已存在。client 在上传前先 HEAD，避免重传大文件。
        router.head("/blob/:sha256") { _, context -> Response in
            guard let sha = context.parameters.get("sha256"), Self.isValidSha256(sha) else {
                return Response(status: .badRequest)
            }
            return Response(status: blobs.exists(sha256: sha) ? .ok : .notFound)
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

        // PUT /blob/{sha256}：上传 blob。
        // 关键校验：path 的 sha256 == body sha256 == X-DP-Body-SHA256 三方一致
        // path 是公开寻址，header 是签名锚定，actual 是真 body——攻防上是不同维度。
        router.put("/blob/:sha256") { request, context -> Response in
            guard let pathSha = context.parameters.get("sha256"), Self.isValidSha256(pathSha) else {
                return errorJSON(.badRequest, "sha256 格式非法")
            }
            // 已存在 → 短路，省读 body
            if blobs.exists(sha256: pathSha) {
                let payload: [String: Any] = ["ok": true, "sha256": pathSha, "was_existing": true]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                var resp = Response(status: .ok, body: .init(byteBuffer: .init(bytes: data)))
                resp.headers[.contentType] = "application/json"
                return resp
            }
            let bodyBuffer = try await request.body.collect(upTo: blobBodyLimit)
            let bodyData = Data(buffer: bodyBuffer)
            let actualHash = HMACAuth.sha256Hex(bodyData)
            let headerHashName = HTTPField.Name(HMACAuth.bodyHashHeader)!
            let claimedHash = request.headers[headerHashName]?.lowercased() ?? ""
            guard actualHash == pathSha else {
                return errorJSON(.badRequest, "body sha256 与 URL path 不匹配")
            }
            guard actualHash == claimedHash else {
                return errorJSON(.badRequest, "body sha256 与 X-DP-Body-SHA256 不匹配")
            }
            do {
                let info = try blobs.put(bodyData)
                let payload: [String: Any] = [
                    "ok": true,
                    "sha256": info.sha256,
                    "size": info.size,
                    "was_existing": info.wasExisting,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                var resp = Response(status: info.wasExisting ? .ok : .created,
                                    body: .init(byteBuffer: .init(bytes: data)))
                resp.headers[.contentType] = "application/json"
                return resp
            } catch {
                return errorJSON(.internalServerError, "blob put failed: \(error)")
            }
        }

        // GET /search?q=foo&limit=200&offset=0&kinds=text,url&from_ns=...&to_ns=...&pinned=1
        // 复用 SearchAPI.fetch；q 非空时附 FTS snippet 给每个 item。
        // 返回 { ok, items: [Item + 可选 snippet], count }
        router.get("/search") { request, _ -> Response in
            let q = parseSearchQuery(request.uri.queryParameters)
            do {
                let items = try searchAPI.search(q)
                let snippets = (try? searchAPI.snippets(forItemIDs: items.map(\.id), query: q)) ?? [:]
                let itemsJSON = items.map { item -> [String: Any] in
                    var d = itemToJSON(item)
                    if let s = snippets[item.id] { d["snippet"] = s }
                    return d
                }
                let payload: [String: Any] = [
                    "ok": true,
                    "count": items.count,
                    "items": itemsJSON,
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

    /// 把 URL query 参数转成 SearchQuery。容错原则：不合法值忽略，不报错——
    /// 用户在 UI 打字时 query 参数随时变，不该因为半成品输入返回 400。
    static func parseSearchQuery(_ params: FlatDictionary<Substring, Substring>) -> SearchQuery {
        let text = params["q"].map(String.init)
        let fromNs = params["from_ns"].flatMap { Int64($0) }
        let toNs = params["to_ns"].flatMap { Int64($0) }
        let limit = params["limit"].flatMap { Int($0) } ?? 200
        let offset = params["offset"].flatMap { Int($0) } ?? 0
        let kinds: [ItemKind] = params["kinds"].map { raw in
            raw.split(separator: ",").compactMap { ItemKind(rawValue: String($0)) }
        } ?? []
        let pinnedOnly = params["pinned"] == "1" || params["pinned"] == "true"
        return SearchQuery(
            text: text, fromNs: fromNs, toNs: toNs,
            kinds: kinds, pinnedOnly: pinnedOnly,
            limit: max(1, min(limit, 1000)),  // 强制 1-1000 防止 DOS
            offset: max(0, offset)
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
            // push_state / push_attempts 是客户端内部字段，但 Item.Codable 把它们标为必填——
            // 把 primary 自己的 acked 状态原样下发，client 端忽略即可
            "push_state": item.pushState.rawValue,
            "push_attempts": item.pushAttempts,
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

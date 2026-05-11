import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

private func makeDBWithItems(_ items: [Item]) throws -> DuoDB {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-search-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try DuoDB(path: paths.mainDB, role: .primary)
    try db.pool.write { conn in
        for it in items { try it.insert(conn) }
    }
    return db
}

private func sampleItem(
    id: String = UUID().uuidString,
    origin: String = "test-device",
    text: String,
    kind: ItemKind = .text,
    capturedAtNs: Int64 = 1_700_000_000_000_000_000,
    pinned: Bool = false
) -> Item {
    Item(
        id: id,
        originDevice: origin,
        capturedAtNs: capturedAtNs,
        kind: kind,
        sourceAppName: "Example",
        preview: text,
        textFull: text,
        pinned: pinned,
        pushState: .acked
    )
}

@Test func searchProviderFallsBackOnRemoteUnreachable() async throws {
    // 远端 transport 永远 unreachable → provider 应回退本地并标 .remoteFallback
    let db = try makeDBWithItems([sampleItem(text: "hello local")])
    let local = SearchAPI(database: db)
    struct DownTransport: SearchTransport {
        func searchRemote(_ query: SearchQuery) async throws -> RemoteSearchResult {
            RemoteSearchResult(outcome: .unreachable(reason: "connection refused"))
        }
    }
    let provider = SearchProvider(local: local, remote: DownTransport())
    let outcome = try await provider.search(SearchQuery(text: "hello"))
    #expect(outcome.items.count == 1)
    #expect(outcome.items.first?.textFull == "hello local")
    if case .remoteFallback(let reason) = outcome.mode {
        #expect(reason.contains("connection refused"))
    } else {
        Issue.record("expected .remoteFallback, got \(outcome.mode)")
    }
}

@Test func searchProviderUsesRemoteWhenAvailable() async throws {
    // 远端 transport 正常 → 应返回 remote items + .remoteOK，不打本地
    let localDB = try makeDBWithItems([sampleItem(text: "this is local, should not appear")])
    let remoteItem = sampleItem(text: "from remote")
    struct OKTransport: SearchTransport {
        let remoteItem: Item
        func searchRemote(_ query: SearchQuery) async throws -> RemoteSearchResult {
            RemoteSearchResult(outcome: .ok([remoteItem]))
        }
    }
    let provider = SearchProvider(
        local: SearchAPI(database: localDB),
        remote: OKTransport(remoteItem: remoteItem)
    )
    let outcome = try await provider.search(SearchQuery())
    #expect(outcome.mode == .remoteOK)
    #expect(outcome.items.count == 1)
    #expect(outcome.items.first?.textFull == "from remote")
}

@Test func searchProviderLocalOnlyWhenNoRemote() async throws {
    let db = try makeDBWithItems([sampleItem(text: "alpha"), sampleItem(text: "beta")])
    let provider = SearchProvider(local: SearchAPI(database: db), remote: nil)
    let outcome = try await provider.search(SearchQuery())
    #expect(outcome.mode == .local)
    #expect(outcome.items.count == 2)
}

@Test func searchProviderRejectedFallsBackToo() async throws {
    // 401/4xx 也应该回退本地（保活），但 banner 显示具体原因
    let db = try makeDBWithItems([sampleItem(text: "local only")])
    struct RejectedTransport: SearchTransport {
        func searchRemote(_ query: SearchQuery) async throws -> RemoteSearchResult {
            RemoteSearchResult(outcome: .rejected(reason: "unauthorized"))
        }
    }
    let provider = SearchProvider(local: SearchAPI(database: db), remote: RejectedTransport())
    let outcome = try await provider.search(SearchQuery())
    if case .remoteFallback(let reason) = outcome.mode {
        #expect(reason.contains("unauthorized"))
    } else {
        Issue.record("expected fallback for rejected")
    }
    #expect(outcome.items.count == 1)
}

/// 端到端：起 in-process server + 真打远端搜索，验证 client 能拿到 server 库里的 items。
@Test func searchHTTPEndToEnd() async throws {
    let serverDB = try makeDBWithItems([
        sampleItem(id: "server-1", text: "hello world from primary"),
        sampleItem(id: "server-2", text: "another text"),
        sampleItem(id: "server-3", text: "URL: https://example.com", kind: .url),
    ])
    let primaryBlobs = BlobStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-search-blobs-\(UUID().uuidString)", isDirectory: true))
    try FileManager.default.createDirectory(at: primaryBlobs.root, withIntermediateDirectories: true)

    let secret = Data(repeating: 0xCD, count: 32)
    let auth = HMACAuth(secret: secret)
    let port = Int.random(in: 19000..<20000)
    let server = SyncServer(
        deviceID: "primary",
        database: serverDB,
        blobs: primaryBlobs,
        host: "127.0.0.1", port: port, auth: auth
    )
    let serverTask = Task { try? await server.run() }
    let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    let client = HTTPIngestClient(baseURL: baseURL, auth: auth)

    // 等 server 启动
    var ready = false
    for _ in 0..<50 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        let r = (try? await client.searchRemote(SearchQuery(limit: 1)))?.outcome
        if case .ok = r { ready = true; break }
    }
    #expect(ready)

    // 文本 "hello" 应该命中 server-1
    let textHit = try await client.searchRemote(SearchQuery(text: "hello"))
    if case .ok(let items) = textHit.outcome {
        #expect(items.count == 1)
        #expect(items.first?.id == "server-1")
    } else {
        Issue.record("expected .ok for text query")
    }

    // kind 过滤
    let urlOnly = try await client.searchRemote(SearchQuery(kinds: [.url]))
    if case .ok(let items) = urlOnly.outcome {
        #expect(items.count == 1)
        #expect(items.first?.id == "server-3")
    } else {
        Issue.record("expected .ok for kind filter")
    }

    // 空查询取全部
    let all = try await client.searchRemote(SearchQuery())
    if case .ok(let items) = all.outcome {
        #expect(items.count == 3)
    }

    serverTask.cancel()
}

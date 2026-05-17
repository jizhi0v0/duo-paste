import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private typealias DuoDB = DuoPasteCore.Database

private func makeFixture() throws -> (DuoDB, BlobStore, HMACAuth, Int) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-icon-http-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(root: root)
    paths.ensureExists()
    let db = try DuoDB(path: paths.mainDB)
    let blobs = BlobStore(root: paths.blobsDir)
    try FileManager.default.createDirectory(at: blobs.root, withIntermediateDirectories: true)
    let auth = HMACAuth(secret: Data(repeating: 0xAB, count: 32))
    let port = Int.random(in: 19000..<20000)
    return (db, blobs, auth, port)
}

private func waitReady(baseURL: URL, auth: HMACAuth) async -> Bool {
    for _ in 0..<50 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let sig = auth.sign(timestampMs: ts, method: "GET", path: "/health",
                            bodyHashHex: HMACAuth.emptyBodyHashHex)
        req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
        req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
        req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            return true
        }
    }
    return false
}

private func getAppIcon(
    baseURL: URL, auth: HMACAuth, bundleID: String
) async throws -> (Int, Data, String?) {
    let path = "/app_icon/\(bundleID)"
    let url = baseURL.appendingPathComponent(path)
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    let ts = Int64(Date().timeIntervalSince1970 * 1000)
    let sig = auth.sign(timestampMs: ts, method: "GET", path: path,
                        bodyHashHex: HMACAuth.emptyBodyHashHex)
    req.setValue(String(ts), forHTTPHeaderField: HMACAuth.timestampHeader)
    req.setValue(HMACAuth.emptyBodyHashHex, forHTTPHeaderField: HMACAuth.bodyHashHeader)
    req.setValue(sig, forHTTPHeaderField: HMACAuth.signatureHeader)

    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as! HTTPURLResponse
    let contentType = http.value(forHTTPHeaderField: "Content-Type")
    return (http.statusCode, data, contentType)
}

@Test func appIconHTTPReturnsPNGForKnownBundle() async throws {
    let (db, blobs, auth, port) = try makeFixture()
    let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
    let store = AppIconStore(database: db) { bid in
        bid == "com.apple.Safari" ? pngBytes : nil
    }
    let server = SyncServer(
        deviceID: "p", database: db, blobs: blobs,
        host: "127.0.0.1", port: port, auth: auth, appIconStore: store
    )
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    #expect(await waitReady(baseURL: base, auth: auth))

    let (status, body, ctype) = try await getAppIcon(
        baseURL: base, auth: auth, bundleID: "com.apple.Safari"
    )
    #expect(status == 200)
    #expect(body == pngBytes)
    #expect(ctype == "image/png")
}

@Test func appIconHTTPReturns404ForUnknownBundle() async throws {
    let (db, blobs, auth, port) = try makeFixture()
    let store = AppIconStore(database: db) { _ in nil }
    let server = SyncServer(
        deviceID: "p", database: db, blobs: blobs,
        host: "127.0.0.1", port: port, auth: auth, appIconStore: store
    )
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    #expect(await waitReady(baseURL: base, auth: auth))

    let (status, _, _) = try await getAppIcon(
        baseURL: base, auth: auth, bundleID: "com.nonexistent"
    )
    #expect(status == 404)
}

@Test func appIconHTTPRejectsBadSignature() async throws {
    let (db, blobs, auth, port) = try makeFixture()
    let store = AppIconStore(database: db) { _ in Data([0x89, 0x50]) }
    let server = SyncServer(
        deviceID: "p", database: db, blobs: blobs,
        host: "127.0.0.1", port: port, auth: auth, appIconStore: store
    )
    let serverTask = Task { try? await server.run() }
    defer { serverTask.cancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    #expect(await waitReady(baseURL: base, auth: auth))

    let badAuth = HMACAuth(secret: Data(repeating: 0xFF, count: 32))
    let (status, _, _) = try await getAppIcon(
        baseURL: base, auth: badAuth, bundleID: "com.apple.Safari"
    )
    #expect(status == 401)
}

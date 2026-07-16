import Testing
import Foundation
import GRDB
import DuoPasteCore
@testable import DuoPasteSync

private func makeFixture() throws -> TestSyncServerFixture {
    try TestSyncServerFixture(prefix: "duo-icon-http")
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
    let fixture = try makeFixture()
    let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
    let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
    let store = AppIconStore(database: db) { bid in
        bid == "com.apple.Safari" ? pngBytes : nil
    }
    let server = SyncServer(
        deviceID: "p", database: db, blobs: blobs,
        host: "127.0.0.1", port: 0, auth: auth, appIconStore: store
    )
    let (status, body, ctype) = try await fixture.withServer(server) { base in
        try await getAppIcon(baseURL: base, auth: auth, bundleID: "com.apple.Safari")
    }
    #expect(status == 200)
    #expect(body == pngBytes)
    #expect(ctype == "image/png")
}

@Test func appIconHTTPReturns404ForUnknownBundle() async throws {
    let fixture = try makeFixture()
    let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
    let store = AppIconStore(database: db) { _ in nil }
    let server = SyncServer(
        deviceID: "p", database: db, blobs: blobs,
        host: "127.0.0.1", port: 0, auth: auth, appIconStore: store
    )
    let (status, _, _) = try await fixture.withServer(server) { base in
        try await getAppIcon(baseURL: base, auth: auth, bundleID: "com.nonexistent")
    }
    #expect(status == 404)
}

@Test func appIconHTTPRejectsBadSignature() async throws {
    let fixture = try makeFixture()
    let (db, blobs, auth) = (fixture.database, fixture.blobs, fixture.auth)
    let store = AppIconStore(database: db) { _ in Data([0x89, 0x50]) }
    let server = SyncServer(
        deviceID: "p", database: db, blobs: blobs,
        host: "127.0.0.1", port: 0, auth: auth, appIconStore: store
    )
    let badAuth = HMACAuth(secret: Data(repeating: 0xFF, count: 32))
    let (status, _, _) = try await fixture.withServer(server) { base in
        try await getAppIcon(baseURL: base, auth: badAuth, bundleID: "com.apple.Safari")
    }
    #expect(status == 401)
}

import Testing
import Foundation
import DuoPasteCore
@testable import DuoPasteSync

private let testSecret = Data(repeating: 0x42, count: 32)

@Test func signAndVerifyRoundTrip() {
    let auth = HMACAuth(secret: testSecret)
    let ts: Int64 = 1_700_000_000_000
    let bodyHash = HMACAuth.sha256Hex(Data("payload".utf8))
    let sig = auth.sign(timestampMs: ts, method: "POST", path: "/ingest", bodyHashHex: bodyHash)
    #expect(sig.count == 64)
    let ok = auth.verify(
        timestampMs: ts, method: "POST", path: "/ingest",
        bodyHashHex: bodyHash, signatureHex: sig, nowMs: ts + 100
    )
    #expect(ok)
}

@Test func verifyRejectsTamperedBodyHash() {
    let auth = HMACAuth(secret: testSecret)
    let ts: Int64 = 1_700_000_000_000
    let sig = auth.sign(timestampMs: ts, method: "POST", path: "/ingest",
                        bodyHashHex: HMACAuth.sha256Hex(Data("a".utf8)))
    // 签的是 a 的 hash，但 verify 时换成 b 的 hash → 拒绝
    let ok = auth.verify(
        timestampMs: ts, method: "POST", path: "/ingest",
        bodyHashHex: HMACAuth.sha256Hex(Data("b".utf8)),
        signatureHex: sig, nowMs: ts
    )
    #expect(!ok)
}

@Test func verifyRejectsTamperedPath() {
    let auth = HMACAuth(secret: testSecret)
    let ts: Int64 = 1_700_000_000_000
    let bodyHash = HMACAuth.emptyBodyHashHex
    let sig = auth.sign(timestampMs: ts, method: "GET", path: "/health", bodyHashHex: bodyHash)
    let ok = auth.verify(
        timestampMs: ts, method: "GET", path: "/admin",
        bodyHashHex: bodyHash, signatureHex: sig, nowMs: ts
    )
    #expect(!ok)
}

@Test func verifyRejectsTamperedMethod() {
    let auth = HMACAuth(secret: testSecret)
    let ts: Int64 = 1_700_000_000_000
    let bodyHash = HMACAuth.emptyBodyHashHex
    let sig = auth.sign(timestampMs: ts, method: "GET", path: "/health", bodyHashHex: bodyHash)
    let ok = auth.verify(
        timestampMs: ts, method: "DELETE", path: "/health",
        bodyHashHex: bodyHash, signatureHex: sig, nowMs: ts
    )
    #expect(!ok)
}

@Test func verifyRejectsExpiredTimestamp() {
    let auth = HMACAuth(secret: testSecret, clockSkew: 60)  // 60s 窗口
    let ts: Int64 = 1_700_000_000_000
    let bodyHash = HMACAuth.emptyBodyHashHex
    let sig = auth.sign(timestampMs: ts, method: "GET", path: "/health", bodyHashHex: bodyHash)
    // 61 秒后才发，超窗
    let ok = auth.verify(
        timestampMs: ts, method: "GET", path: "/health",
        bodyHashHex: bodyHash, signatureHex: sig,
        nowMs: ts + 61_000
    )
    #expect(!ok)
}

@Test func verifyAcceptsClientClockBehind() {
    // 客户端时钟比服务端慢 50 秒，仍在 60s 窗口内
    let auth = HMACAuth(secret: testSecret, clockSkew: 60)
    let ts: Int64 = 1_700_000_000_000
    let bodyHash = HMACAuth.emptyBodyHashHex
    let sig = auth.sign(timestampMs: ts, method: "GET", path: "/health", bodyHashHex: bodyHash)
    let ok = auth.verify(
        timestampMs: ts, method: "GET", path: "/health",
        bodyHashHex: bodyHash, signatureHex: sig,
        nowMs: ts + 50_000
    )
    #expect(ok)
}

@Test func verifyRejectsWrongSecret() {
    let signing = HMACAuth(secret: Data(repeating: 0x42, count: 32))
    let verifying = HMACAuth(secret: Data(repeating: 0x99, count: 32))
    let ts: Int64 = 1_700_000_000_000
    let bodyHash = HMACAuth.emptyBodyHashHex
    let sig = signing.sign(timestampMs: ts, method: "GET", path: "/health", bodyHashHex: bodyHash)
    let ok = verifying.verify(
        timestampMs: ts, method: "GET", path: "/health",
        bodyHashHex: bodyHash, signatureHex: sig, nowMs: ts
    )
    #expect(!ok)
}

@Test func emptyBodyHashIsCanonical() {
    // 这个常量被 client 代码硬编码，验一下它真的是空 Data 的 sha256
    let computed = HMACAuth.sha256Hex(Data())
    #expect(computed == HMACAuth.emptyBodyHashHex)
}

@Test func sharedSecretLoadsValidHex() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-secret-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("shared-secret")
    let hex = String(repeating: "ab", count: 32)  // 64 chars = 32 bytes
    try hex.data(using: .utf8)!.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    let data = try SharedSecret.load(from: path)
    #expect(data.count == 32)
    #expect(data.allSatisfy { $0 == 0xAB })
}

@Test func sharedSecretRejectsLoosePermissions() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-secret-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("shared-secret")
    try String(repeating: "ab", count: 32).data(using: .utf8)!.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
    #expect(throws: SharedSecretError.self) {
        _ = try SharedSecret.load(from: path)
    }
}

@Test func sharedSecretRejectsInvalidFormat() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-secret-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("shared-secret")
    try "not hex".data(using: .utf8)!.write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    #expect(throws: SharedSecretError.self) {
        _ = try SharedSecret.load(from: path)
    }
}

@Test func sharedSecretMissing() {
    let nonexistent = FileManager.default.temporaryDirectory
        .appendingPathComponent("duo-no-secret-\(UUID().uuidString)")
    #expect(throws: SharedSecretError.self) {
        _ = try SharedSecret.load(from: nonexistent)
    }
}

// MARK: canonicalPath helper

@Test func canonicalPathHandlesEmptyAndNilQuery() {
    #expect(HMACAuth.canonicalPath("/health") == "/health")
    #expect(HMACAuth.canonicalPath("/health", query: nil) == "/health")
    #expect(HMACAuth.canonicalPath("/health", query: "") == "/health")
}

@Test func canonicalPathAppendsQueryVerbatim() {
    let p = HMACAuth.canonicalPath("/since", query: "cursor_ns=12&cursor_id=01H")
    #expect(p == "/since?cursor_ns=12&cursor_id=01H")
}

/// 关键回归：客户端走 `URLComponents.percentEncodedQuery` 构造 sign path，
/// 服务端 middleware 走 `request.uri.query`。两侧用同一份 `canonicalPath` helper，
/// 在含 percent-encoded 字符的 query 上签名/校验**必须**对上。
@Test func canonicalPathRoundTripsPercentEncodedQuery() {
    // 模拟 cursor_id 含非 ASCII / `+` / `/` / 空格 等边界字符——client 端 URLComponents
    // 会把它们 percent-encode 后塞进 percentEncodedQuery；server 端 Hummingbird URI 收到
    // 也是同一份 raw bytes
    let qi: [URLQueryItem] = [
        .init(name: "cursor_ns", value: "12345"),
        .init(name: "cursor_id", value: "01H+ABC/中文 末尾"),
        .init(name: "limit", value: "100"),
    ]
    var sigComp = URLComponents()
    sigComp.path = "/since"
    sigComp.queryItems = qi
    let clientPath = HMACAuth.canonicalPath("/since", query: sigComp.percentEncodedQuery)

    // server 端收到的 raw bytes —— 模拟 Hummingbird URI 不 percent-decode 行为：
    // raw query 就是 client 拼出来的那份 percentEncodedQuery
    let serverPath = HMACAuth.canonicalPath("/since", query: sigComp.percentEncodedQuery)

    #expect(clientPath == serverPath, "encoding 漂移：client=\(clientPath) server=\(serverPath)")

    // 客户端用这条 path 签名，服务端用同条 path 校验 → 必通过
    let auth = HMACAuth(secret: testSecret)
    let ts: Int64 = 1_700_000_000_000
    let sig = auth.sign(timestampMs: ts, method: "GET", path: clientPath,
                        bodyHashHex: HMACAuth.emptyBodyHashHex)
    let ok = auth.verify(
        timestampMs: ts, method: "GET", path: serverPath,
        bodyHashHex: HMACAuth.emptyBodyHashHex, signatureHex: sig, nowMs: ts
    )
    #expect(ok)
}

import Testing
import Foundation
import DuoPasteCore

/// `HMACAuth.verify` 的时间窗口检查跑在签名验证**之前**，且 `timestampMs` 直接来自
/// 攻击者可控的 `X-DP-Timestamp` header（`AuthMiddleware` 用裸 `Int64(tsStr)` 解析，
/// 不做范围限制）。历史实现 `abs(nowMs - timestampMs)` 是陷阱算术，越界输入让 daemon
/// SIGTRAP —— 无凭据即可远程打挂进程，launchd 拉起后下一个请求再杀一次。
///
/// 这组测试钉死的契约是：**verify 对任意 Int64 输入都只返回 true/false，永不 trap**。
/// 任何一条 fail 都意味着回退到陷阱算术。
private let secret = Data(repeating: 0xAB, count: 32)
private let nowMs: Int64 = 1_774_000_000_000

@Test func verifyRejectsInt64MinTimestampWithoutTrapping() {
    let auth = HMACAuth(secret: secret)
    // 真实攻击载荷：curl -H 'X-DP-Timestamp: -9223372036854775808'
    #expect(auth.verify(
        timestampMs: .min,
        method: "GET",
        path: "/since",
        bodyHashHex: HMACAuth.emptyBodyHashHex,
        signatureHex: "00",
        nowMs: nowMs
    ) == false)
}

@Test func verifyRejectsInt64MaxTimestampWithoutTrapping() {
    let auth = HMACAuth(secret: secret)
    #expect(auth.verify(
        timestampMs: .max,
        method: "GET",
        path: "/since",
        bodyHashHex: HMACAuth.emptyBodyHashHex,
        signatureHex: "00",
        nowMs: nowMs
    ) == false)
}

/// delta 恰好等于 `Int64.min` 时减法本身不溢出，但旧代码的 `abs()` 会溢出——
/// 单独钉一条，防止只修了减法忘了 abs。
@Test func verifyRejectsDeltaExactlyInt64MinWithoutTrapping() {
    let auth = HMACAuth(secret: secret)
    #expect(auth.verify(
        timestampMs: .max,
        method: "GET",
        path: "/since",
        bodyHashHex: HMACAuth.emptyBodyHashHex,
        signatureHex: "00",
        nowMs: -1
    ) == false)
}

/// `nowMs` 也可能是极值（测试注入 / 时钟异常），两个方向都不能 trap。
@Test func verifyRejectsExtremeNowWithoutTrapping() {
    let auth = HMACAuth(secret: secret)
    for (now, ts) in [(Int64.min, Int64.max), (Int64.max, Int64.min), (Int64.min, Int64.min)] {
        #expect(auth.verify(
            timestampMs: ts,
            method: "GET",
            path: "/since",
            bodyHashHex: HMACAuth.emptyBodyHashHex,
            signatureHex: "00",
            nowMs: now
        ) == false)
    }
}

/// 非法 `clockSkew`（NaN / 越界）必须退化成"全拒"，不能让 `Int64(clockSkew * 1000)` trap。
@Test func verifyRejectsWhenClockSkewIsNotRepresentable() {
    let path = "/since"
    for skew in [Double.nan, .infinity, -.infinity, 1e30, -1] {
        let auth = HMACAuth(secret: secret, clockSkew: skew)
        let sig = auth.sign(
            timestampMs: nowMs, method: "GET", path: path,
            bodyHashHex: HMACAuth.emptyBodyHashHex
        )
        // 即使签名完全正确，窗口不可解释时也必须拒绝（fail closed）
        #expect(auth.verify(
            timestampMs: nowMs,
            method: "GET",
            path: path,
            bodyHashHex: HMACAuth.emptyBodyHashHex,
            signatureHex: sig,
            nowMs: nowMs
        ) == false)
    }
}

/// 修复不能把正常路径改坏：窗口内 + 签名正确仍然通过，窗口外仍然拒绝。
@Test func verifyStillAcceptsValidSignatureInsideWindow() {
    let auth = HMACAuth(secret: secret, clockSkew: 300)
    let path = "/since?cursor_ns=12"
    let sig = auth.sign(
        timestampMs: nowMs, method: "GET", path: path,
        bodyHashHex: HMACAuth.emptyBodyHashHex
    )
    #expect(auth.verify(
        timestampMs: nowMs, method: "GET", path: path,
        bodyHashHex: HMACAuth.emptyBodyHashHex,
        signatureHex: sig, nowMs: nowMs + 299_000
    ))
    #expect(auth.verify(
        timestampMs: nowMs, method: "GET", path: path,
        bodyHashHex: HMACAuth.emptyBodyHashHex,
        signatureHex: sig, nowMs: nowMs - 299_000
    ))
    // 边界外（301s）两个方向都拒
    #expect(auth.verify(
        timestampMs: nowMs, method: "GET", path: path,
        bodyHashHex: HMACAuth.emptyBodyHashHex,
        signatureHex: sig, nowMs: nowMs + 301_000
    ) == false)
    #expect(auth.verify(
        timestampMs: nowMs, method: "GET", path: path,
        bodyHashHex: HMACAuth.emptyBodyHashHex,
        signatureHex: sig, nowMs: nowMs - 301_000
    ) == false)
}

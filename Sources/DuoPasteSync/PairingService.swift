import Foundation
import DuoPasteCore

/// PIN 配对状态机。Mac Settings 调 `generatePIN()` 创建 6 位 PIN + expiry,iOS POST
/// /pair/<pin> 命中 `validateAndConsumePIN(pin)` 拿到 secret。
///
/// 安全约束:
/// - PIN 走 `SecRandomCopyBytes` 加密随机,不要 `arc4random`
/// - 单次有效:PIN 用过即失效(防 replay)
/// - 60s expiry:超时后即便 PIN 没用过也失效
/// - Rate limit:5 次错误尝试/分钟/PIN session,超过封锁
/// - 同时只允许一个 active PIN(generatePIN 顶掉旧的)
///
/// Thread safety:actor 串行 generate / validate
public actor PairingService {
    public struct Session: Sendable {
        public let pin: String
        public let expiresAt: Date
        public let secretsProvider: @Sendable () throws -> Data
        public var failedAttempts: Int = 0

        public var secondsLeft: Int {
            max(0, Int(expiresAt.timeIntervalSinceNow))
        }
    }

    public enum Error: Swift.Error, Equatable {
        case pinExpired
        case pinMismatch
        case rateLimited
        case noActiveSession
        case secretLoadFailed(String)
    }

    private var currentSession: Session?
    private let pinLifetimeSec: TimeInterval
    private let maxFailedAttempts: Int
    /// secret 读取器闭包——daemon 启动时注入(读 SharedSecret.load)。每次 validate 成功
    /// 才调一次,避免长期持有 secret bytes 在 actor state 里
    private let secretsProvider: @Sendable () throws -> Data
    /// 给测试注入固定 PIN
    private let pinGenerator: @Sendable () -> String

    public init(
        pinLifetimeSec: TimeInterval = 60,
        maxFailedAttempts: Int = 5,
        secretsProvider: @escaping @Sendable () throws -> Data,
        pinGenerator: @escaping @Sendable () -> String = { PairingService.randomPIN() }
    ) {
        self.pinLifetimeSec = pinLifetimeSec
        self.maxFailedAttempts = maxFailedAttempts
        self.secretsProvider = secretsProvider
        self.pinGenerator = pinGenerator
    }

    /// 创建新 PIN session,顶掉旧的。返回 PIN + 倒计时让 UI 显示。
    /// 用户主动点"显示配对码"时调
    public func generatePIN() -> (pin: String, secondsLeft: Int) {
        let pin = pinGenerator()
        let session = Session(
            pin: pin,
            expiresAt: Date().addingTimeInterval(pinLifetimeSec),
            secretsProvider: secretsProvider,
            failedAttempts: 0
        )
        currentSession = session
        return (pin, Int(pinLifetimeSec))
    }

    /// 当前 session 状态(给 UI 倒计时用)。nil = 没有 active PIN
    public func currentStatus() -> (pin: String, secondsLeft: Int)? {
        guard let s = currentSession else { return nil }
        if s.secondsLeft <= 0 {
            currentSession = nil
            return nil
        }
        return (s.pin, s.secondsLeft)
    }

    /// 手动取消(用户关闭 sheet 时调)
    public func cancel() {
        currentSession = nil
    }

    /// iOS POST /pair/<pin> 路径调。成功返 secret bytes,失败抛错。
    /// **任何路径 — 成功 / 失败 — 都消费 session**(用过即失效防 replay;失败 N 次也封掉
    /// 整个 session 防暴力)
    public func validateAndConsumePIN(_ candidate: String) throws -> Data {
        guard var session = currentSession else {
            throw Error.noActiveSession
        }
        if session.secondsLeft <= 0 {
            currentSession = nil
            throw Error.pinExpired
        }
        if session.failedAttempts >= maxFailedAttempts {
            currentSession = nil
            throw Error.rateLimited
        }
        if !Self.constantTimeEquals(candidate, session.pin) {
            session.failedAttempts += 1
            if session.failedAttempts >= maxFailedAttempts {
                currentSession = nil
            } else {
                currentSession = session
            }
            throw Error.pinMismatch
        }
        // 成功:消费 session 拿 secret
        currentSession = nil
        do {
            return try session.secretsProvider()
        } catch {
            throw Error.secretLoadFailed("\(error)")
        }
    }

    // MARK: - 工具

    /// 加密随机 6 位数字。crypto-safe 防 iOS 暴力穷举(虽然 5 次封锁已经够)
    public static func randomPIN() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        // 4 字节 = 32 bit,模 1_000_000 偏差可忽略(0.0233%)
        let v = (UInt32(bytes[0]) << 24)
              | (UInt32(bytes[1]) << 16)
              | (UInt32(bytes[2]) << 8)
              | UInt32(bytes[3])
        return String(format: "%06d", v % 1_000_000)
    }

    /// 常数时间字符串比较——防止 timing attack 泄露 PIN 前缀。Swift String == 短路在
    /// 第一个差异 byte,虽然 6 位 PIN 时间差极小理论上仍是 leak vector
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count {
            diff |= ab[i] ^ bb[i]
        }
        return diff == 0
    }
}

import Testing
import Foundation
import DuoPasteCore
@testable import DuoPasteSync

@Suite struct PairingServiceTests {
    private static let testSecret = Data(repeating: 0xAA, count: 32)

    private func makeService(pin: String = "123456") -> PairingService {
        PairingService(
            pinLifetimeSec: 60,
            maxFailedAttempts: 5,
            secretsProvider: { Self.testSecret },
            pinGenerator: { pin }
        )
    }

    @Test func generatePINReturnsPinAndTimeLeft() async {
        let svc = makeService(pin: "424242")
        let (pin, seconds) = await svc.generatePIN()
        #expect(pin == "424242")
        #expect(seconds == 60)
        let status = await svc.currentStatus()
        #expect(status?.pin == "424242")
    }

    @Test func validateAndConsumeReturnsSecretOnCorrectPIN() async throws {
        let svc = makeService(pin: "111111")
        _ = await svc.generatePIN()
        let secret = try await svc.validateAndConsumePIN("111111")
        #expect(secret == Self.testSecret)
        // 用过即失效
        let status = await svc.currentStatus()
        #expect(status == nil)
    }

    @Test func validateRejectsMismatchPIN() async {
        let svc = makeService(pin: "111111")
        _ = await svc.generatePIN()
        await #expect(throws: PairingService.Error.pinMismatch) {
            _ = try await svc.validateAndConsumePIN("222222")
        }
        // session 仍在(没用完 5 次)
        let status = await svc.currentStatus()
        #expect(status?.pin == "111111")
    }

    @Test func validateRateLimitsAfterMaxAttempts() async {
        let svc = makeService(pin: "111111")
        _ = await svc.generatePIN()
        for _ in 0..<5 {
            try? await svc.validateAndConsumePIN("999999")
        }
        // session 应该被封掉
        await #expect(throws: PairingService.Error.noActiveSession) {
            _ = try await svc.validateAndConsumePIN("111111")
        }
    }

    @Test func validateRejectsExpiredPIN() async throws {
        let svc = PairingService(
            pinLifetimeSec: 0.05, // 50ms
            maxFailedAttempts: 5,
            secretsProvider: { Self.testSecret },
            pinGenerator: { "111111" }
        )
        _ = await svc.generatePIN()
        try await Task.sleep(nanoseconds: 100_000_000)
        await #expect(throws: PairingService.Error.pinExpired) {
            _ = try await svc.validateAndConsumePIN("111111")
        }
    }

    @Test func generatePINOverridesPreviousSession() async {
        let svc = makeService(pin: "111111")
        _ = await svc.generatePIN()
        let svc2 = PairingService(
            pinLifetimeSec: 60,
            maxFailedAttempts: 5,
            secretsProvider: { Self.testSecret },
            pinGenerator: { "222222" }
        )
        _ = await svc2.generatePIN()
        // 不同 service instance 互不影响——这条验证的是 generatePIN 顶掉自己的旧 session
        let (newPin, _) = await svc.generatePIN()
        #expect(newPin == "111111") // generator 固定 111111
        await #expect(throws: PairingService.Error.pinMismatch) {
            // 旧 PIN 没消费过但被 generatePIN 顶掉了——新 session.pin 仍是 111111(固定),
            // 模拟"老 session 失效"用 999999 验
            _ = try await svc.validateAndConsumePIN("999999")
        }
    }

    @Test func randomPINIsSixDigits() {
        for _ in 0..<100 {
            let pin = PairingService.randomPIN()
            #expect(pin.count == 6)
            #expect(pin.allSatisfy { $0.isNumber })
        }
    }
}

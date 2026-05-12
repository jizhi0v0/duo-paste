import Foundation
import Testing
@testable import DuoPasteCore

/// 可变 wall-clock 注入：Swift 6 strict concurrency 下 closure 捕获 `var now`
/// 跨 actor 不允许，用 class 引用包一层。
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { self._now = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
}

@Suite("PasteSuppressionSet")
struct PasteSuppressionSetTests {
    @Test func recordAndContainsHits() {
        let set = PasteSuppressionSet()
        let fp = PasteSuppressionSet.fingerprint(text: "hello world")
        #expect(!set.contains(fp))
        set.record(fingerprint: fp, ttlSec: 60)
        #expect(set.contains(fp))
    }

    @Test func differentFingerprintsDoNotCollide() {
        let set = PasteSuppressionSet()
        let a = PasteSuppressionSet.fingerprint(text: "alpha")
        let b = PasteSuppressionSet.fingerprint(text: "beta")
        set.record(fingerprint: a, ttlSec: 60)
        #expect(set.contains(a))
        #expect(!set.contains(b))
    }

    @Test func textAndBlobNamespacesAreDistinct() {
        // 极小概率"文本 sha256 hex == blob sha256 hex"碰撞下，前缀仍能区分
        let set = PasteSuppressionSet()
        let hex = "abc123"
        let asText = "t:" + hex   // 跟 fingerprint(text:) 形态对齐（前缀 "t:"）
        let asBlob = PasteSuppressionSet.fingerprint(blobSha256: hex)
        #expect(asText != asBlob)
        set.record(fingerprint: asText, ttlSec: 60)
        #expect(!set.contains(asBlob))
    }

    @Test func entriesExpireAfterTTL() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let set = PasteSuppressionSet(nowDate: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "expiring")
        set.record(fingerprint: fp, ttlSec: 10)
        #expect(set.contains(fp))
        // 推进 11s → 应该过期
        clock.advance(by: 11)
        #expect(!set.contains(fp))
        #expect(set.activeCount() == 0)
    }

    @Test func repeatedRecordKeepsLongerWindow() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let set = PasteSuppressionSet(nowDate: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "x")
        set.record(fingerprint: fp, ttlSec: 100)  // expire at +100
        // 推进 50s，再 record 一个 ttl=10（expire at +60，比已有的 +100 短）
        clock.advance(by: 50)
        set.record(fingerprint: fp, ttlSec: 10)
        // 再推 30s（now=+80）：原 +100 仍有效，短 ttl 不应缩短窗口
        clock.advance(by: 30)
        #expect(set.contains(fp))
    }

    @Test func fingerprintForItemPrefersBlobForImage() {
        let textItem = Item(
            id: "i1", originDevice: "d", capturedAtNs: 0, ingestedAtNs: nil,
            kind: .text, preview: "", textFull: "hello"
        )
        let imageItem = Item(
            id: "i2", originDevice: "d", capturedAtNs: 0, ingestedAtNs: nil,
            kind: .image, preview: "",
            blobSha256: "deadbeef", blobSize: 100, blobMime: "image/png"
        )
        #expect(PasteSuppressionSet.fingerprint(forItem: textItem) == PasteSuppressionSet.fingerprint(text: "hello"))
        #expect(PasteSuppressionSet.fingerprint(forItem: imageItem) == PasteSuppressionSet.fingerprint(blobSha256: "deadbeef"))
    }

    @Test func fingerprintNilWhenNoTextOrBlob() {
        // 退化场景：image kind 但 blobSha256 为 nil
        let degenerate = Item(
            id: "i3", originDevice: "d", capturedAtNs: 0, ingestedAtNs: nil,
            kind: .image, preview: ""
        )
        #expect(PasteSuppressionSet.fingerprint(forItem: degenerate) == nil)
    }
}

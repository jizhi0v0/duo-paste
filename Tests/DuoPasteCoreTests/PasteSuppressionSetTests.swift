import Foundation
import Testing
@testable import DuoPasteCore

/// 可变 ns clock 注入：Swift 6 strict concurrency 下 closure 捕获 `var now`
/// 跨 actor 不允许，用 class 引用包一层。
private final class MutableNsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _ns: Int64
    init(_ start: Int64) { self._ns = start }
    func now() -> Int64 { lock.lock(); defer { lock.unlock() }; return _ns }
    func advance(seconds: Int64) {
        lock.lock(); defer { lock.unlock() }
        _ns += seconds * 1_000_000_000
    }
}

@Suite("PasteSuppressionSet")
struct PasteSuppressionSetTests {
    /// 候选行的 capturedAtNs 略晚于 record（typical Continuity echo 路径）。
    /// 调用方写不出来 echo 的具体 ns 时给个 baseline + 1s。
    private func echoCapturedAt(_ recordNs: Int64) -> Int64 { recordNs + 1_000_000_000 }

    @Test func recordAndShouldSuppressForFreshEcho() {
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "hello world")
        #expect(!set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: clock.now()))
        let recordedAt = clock.now()
        set.record(fingerprint: fp, ttlSec: 60)
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: echoCapturedAt(recordedAt)))
    }

    @Test func differentFingerprintsDoNotCollide() {
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let a = PasteSuppressionSet.fingerprint(text: "alpha")
        let b = PasteSuppressionSet.fingerprint(text: "beta")
        set.record(fingerprint: a, ttlSec: 60)
        let echoTime = echoCapturedAt(clock.now())
        #expect(set.shouldSuppress(fingerprint: a, candidateCapturedAtNs: echoTime))
        #expect(!set.shouldSuppress(fingerprint: b, candidateCapturedAtNs: echoTime))
    }

    @Test func textAndBlobNamespacesAreDistinct() {
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let hex = "abc123"
        let asText = "t:" + hex
        let asBlob = PasteSuppressionSet.fingerprint(blobSha256: hex)
        #expect(asText != asBlob)
        set.record(fingerprint: asText, ttlSec: 60)
        let echoTime = echoCapturedAt(clock.now())
        #expect(!set.shouldSuppress(fingerprint: asBlob, candidateCapturedAtNs: echoTime))
    }

    @Test func entriesExpireAfterTTL() {
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "expiring")
        set.record(fingerprint: fp, ttlSec: 10)
        let recordedAt = clock.now()
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: echoCapturedAt(recordedAt)))
        // 推进 11s → 应该过期
        clock.advance(seconds: 11)
        #expect(!set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: clock.now()))
        #expect(set.activeCount() == 0)
    }

    @Test func repeatedRecordKeepsLongerWindowAndRefreshesAnchor() {
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "x")
        set.record(fingerprint: fp, ttlSec: 100)  // expire at +100s
        // 推进 50s，再 record 一个 ttl=10（expire +60s < 已有 +100s）
        clock.advance(seconds: 50)
        let secondRecordedAt = clock.now()
        set.record(fingerprint: fp, ttlSec: 10)
        // 再推 30s（now=+80s）：原 +100s 仍有效，短 ttl 不应缩窗口
        clock.advance(seconds: 30)
        // 锚点已被刷新到 +50s 那次，所以 candidate 在 +50s 后任意时间都算 fresh echo
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: secondRecordedAt + 100))
    }

    // MARK: - P2 review 回归：catch-up 时同内容历史行不应被误杀

    @Test func historicalCandidateBeforeRecordIsNotSuppressed() {
        // 场景：client 离线一周，pull_cursor 卡在旧位置。重新上线时用户碰巧 paste 了
        // 一个常见短串 "ok"，suppression set 收下 fp(ok)。catch-up 拉到 mini 一周前
        // 的一条 "ok" 历史行 —— captured_at 远早于 record。**不**应被 suppression
        // 误杀，否则 cursor 推进后那条行永远拉不回来。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "ok")
        let recordTime = clock.now()
        set.record(fingerprint: fp, ttlSec: 300)
        // 一周前的历史行（captured_at = record - 7 days）
        let historicalCaptured = recordTime - 7 * 24 * 3600 * 1_000_000_000
        #expect(!set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: historicalCaptured))
    }

    @Test func candidateWithinSkewIsStillSuppressed() {
        // 时钟漂移：对端 mini 比本机 MBP 慢 3s。echo capturedAt = record - 3s，
        // 仍在 5s skew 内 → 应抑制。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "y")
        let recordTime = clock.now()
        set.record(fingerprint: fp, ttlSec: 60)
        let echoUnderSkew = recordTime - 3 * 1_000_000_000   // -3s
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: echoUnderSkew))
    }

    @Test func candidateBeyondSkewIsNotSuppressed() {
        // -10s 的"早于 record"已超出默认 5s skew → 视作历史行，放行。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "z")
        let recordTime = clock.now()
        set.record(fingerprint: fp, ttlSec: 60)
        let echoBeyondSkew = recordTime - 10 * 1_000_000_000
        #expect(!set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: echoBeyondSkew))
    }

    // MARK: - P2 review #2 回归：未来合法同内容 capture 不应被误杀

    @Test func candidateAfterEchoWindowIsNotSuppressed() {
        // 场景：用户在 MBP paste "ok"（record 在 T0），TTL 300s 内 entry 还活着。
        // 过了 120s（远超 60s 默认 echo window），用户切到 mini 在某个上下文里独立
        // 复制了一个"ok"——这是新的合法 capture，**不**是 paste echo。应放行入 mirror。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "ok")
        let recordTime = clock.now()
        set.record(fingerprint: fp, ttlSec: 300)
        // 候选 captured = record + 120s，超过 60s 默认 echo window
        let candidate = recordTime + 120 * 1_000_000_000
        #expect(!set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: candidate))
    }

    @Test func candidateWithinEchoWindowIsSuppressed() {
        // 正向：echo 窗口内（默认 60s）的候选应被抑制。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "ok")
        let recordTime = clock.now()
        set.record(fingerprint: fp, ttlSec: 300)
        let candidate = recordTime + 30 * 1_000_000_000   // +30s，典型 PullWorker tick
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: candidate))
    }

    // MARK: - Fingerprint helpers

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
        let degenerate = Item(
            id: "i3", originDevice: "d", capturedAtNs: 0, ingestedAtNs: nil,
            kind: .image, preview: ""
        )
        #expect(PasteSuppressionSet.fingerprint(forItem: degenerate) == nil)
    }
}

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

    @Test func multipleAnchorsEachKeepOwnTTL() {
        // 多锚点：每个 paste 独立 TTL，互不传染。
        // - T0 record ttl=100 → 锚点 a0 活到 T+100s
        // - T+50s record ttl=10 → 锚点 a1 活到 T+60s
        // - T+65s：a1 过期，a0 仍活；a1 附近的 candidate 不再 suppress，a0 附近仍 suppress
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "x")
        let a0 = clock.now()
        set.record(fingerprint: fp, ttlSec: 100)
        clock.advance(seconds: 50)
        let a1 = clock.now()
        set.record(fingerprint: fp, ttlSec: 10)
        // T+55s（两锚点都活）：两锚点附近 echo 都命中
        clock.advance(seconds: 5)
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: a0 + 1_000_000_000))
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: a1 + 1_000_000_000))
        // T+65s：a1 已过期（自 ttl=10s），a0 仍活
        clock.advance(seconds: 10)
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: a0 + 1_000_000_000))
        #expect(!set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: a1 + 1_000_000_000))
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
        // 过了 30s（远超 10s 默认 echo window），用户切到 mini 在某个上下文里独立
        // 复制了一个"ok"——这是新的合法 capture，**不**是 paste echo。应放行入 mirror。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "ok")
        let recordTime = clock.now()
        set.record(fingerprint: fp, ttlSec: 300)
        // 候选 captured = record + 30s，超过 10s 默认 echo window
        let candidate = recordTime + 30 * 1_000_000_000
        #expect(!set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: candidate))
    }

    // MARK: - P2 回归：同 fp 多次 paste 之间夹着延迟 echo 不应漏过

    @Test func earlyEchoStillSuppressedAfterSecondPasteRefreshesAnchor() {
        // 场景：T0 paste "A" → 对端 captured ≈ T0+1s，但本机 PullWorker 还没拉到。
        // T20s 用户又 paste 同内容 "A"。若 record 只保留最新锚点 T20，那么 T0+1s
        // 的 candidate < T20 - 5s skew → 不再 suppression → echo 漏进 mirror。
        // 现在保留 earliest=T0，下界用 earliest-skew → T0+1s 仍命中。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "A")
        let firstPasteAt = clock.now()
        set.record(fingerprint: fp, ttlSec: 300)
        // 第一次 paste 的对端 echo (captured ≈ T0+1s)
        let earlyEchoCaptured = firstPasteAt + 1 * 1_000_000_000
        // 用户在 +20s 又 paste 同内容
        clock.advance(seconds: 20)
        set.record(fingerprint: fp, ttlSec: 300)
        // 这时 PullWorker 终于拉到第一次 paste 那条 echo，应仍被 suppression 命中
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: earlyEchoCaptured))
    }

    @Test func candidateWithinEchoWindowIsSuppressed() {
        // 正向：echo 窗口内（默认 10s）的候选应被抑制。
        // Continuity 反弹典型 < 1s + 对端 watcher tick 200ms + push 节奏，3s 是典型值。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "ok")
        let recordTime = clock.now()
        set.record(fingerprint: fp, ttlSec: 300)
        let candidate = recordTime + 3 * 1_000_000_000   // +3s，典型 echo 时延
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: candidate))
    }

    // MARK: - P2 回归：两次 paste 之间的真空区合法 capture 必须放行

    @Test func independentCaptureBetweenTwoPasteWindowsIsNotSuppressed() {
        // 场景：T0 paste "A"。T+30s 用户在对端独立 Cmd+C 了字符串 "A"（短串碰撞），
        // 这条 captured_at_ns=T+30s 的 mirror 行是合法的、跟本机两次 paste 都不是
        // echo 关系。T+60s 用户又 paste "A"。
        //
        // hull 方案 (`[earliest-skew, latest+echo]`) 会把 T+30s 误杀。
        // 多锚点 OR 方案：两段窗口中间真空，T+30s 放行。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "A")
        let t0 = clock.now()
        set.record(fingerprint: fp, ttlSec: 300)
        clock.advance(seconds: 60)
        set.record(fingerprint: fp, ttlSec: 300)
        // 候选 captured = T0 + 30s，落在两个锚点 (T0, T+60s) 之间真空区
        // 锚点 a0 = T0：窗口 [T0-5s, T0+10s] → 不覆盖 T0+30s
        // 锚点 a1 = T+60s：窗口 [T+55s, T+70s] → 不覆盖 T0+30s
        let independentCapture = t0 + 30 * 1_000_000_000
        #expect(!set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: independentCapture))
    }

    @Test func anchorListIsBoundedByMaxAnchors() {
        // 病态：同串短时间内连续 paste 远超上限。entry 不应无界增长。
        let clock = MutableNsClock(1_700_000_000_000_000_000)
        let set = PasteSuppressionSet(nowNs: { clock.now() })
        let fp = PasteSuppressionSet.fingerprint(text: "spam")
        let n = PasteSuppressionSet.maxAnchorsPerFingerprint + 5
        for _ in 0..<n {
            set.record(fingerprint: fp, ttlSec: 300)
            clock.advance(seconds: 1)  // 间隔够远不会自然过期
        }
        // entry 仍只有 1 个 fp，最新若干锚点应仍命中本次 echo
        #expect(set.activeCount() == 1)
        #expect(set.shouldSuppress(fingerprint: fp, candidateCapturedAtNs: clock.now()))
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

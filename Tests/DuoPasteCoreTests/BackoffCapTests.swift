import Testing
import Foundation
@testable import DuoPasteCore

/// 覆盖 `Backoff.failuresCap` 的契约——iOS `PeerWebSocket.failuresCapDuringGrace`
/// 调用方:从 `backoffLadder + graceMaxBackoffSec` 派生 failures 增量上限,
/// **ladder 改动自动跟随**。
///
/// PR #40 review #7 提出:之前这个值住在 iOS only 的 `PeerWebSocket`,
/// `@MainActor @Observable` + `import Network` 让 SwiftPM 测不到。后人改回
/// 手写常量 / firstIndex 谓词写错,CI 不会拦。算法抽到 `DuoPasteCore`
/// 后这五条 case 钉契约。
@Suite("Backoff failuresCap (ladder-derived)")
struct BackoffCapTests {

    /// 经典 ladder + 8s grace cap——idx 3 = 16s 是第一个 > 8 的档位,
    /// 返回 4 表示 failures 可以涨到 4(对应 `ladder[3] = 8s`)还在窗口内,
    /// 5 才会超。
    @Test("[1,2,4,8,16,32] + maxBackoff=8 → 4")
    func classicLadderEightSec() {
        let cap = Backoff.failuresCap(
            ladder: [1, 2, 4, 8, 16, 32],
            maxBackoffSec: 8
        )
        #expect(cap == 4)
    }

    /// 同 ladder 不同 cap——idx 2 = 8s 是第一个 > 4,返回 3。验证 cap
    /// 真的跟 maxBackoffSec 联动,不是硬编码常量。
    @Test("[1,2,4,8,16,32] + maxBackoff=4 → 3")
    func classicLadderFourSec() {
        let cap = Backoff.failuresCap(
            ladder: [1, 2, 4, 8, 16, 32],
            maxBackoffSec: 4
        )
        #expect(cap == 3)
    }

    /// **核心 ladder-driven 契约**:在 [1,2,4,8] 中间插一档 6s 让 ladder 变
    /// [1,2,4,6,8,16],cap 从 4 自动调到 5——idx 4 = 16s 是第一个 > 8 的档位。
    /// 这条挂的目的就是"插档不需要手动重算 cap";改回手写常量 4 这里就 fail。
    @Test("插档 6s + maxBackoff=8 → 5（自动跟随）")
    func extraLadderRungAdjustsCap() {
        let cap = Backoff.failuresCap(
            ladder: [1, 2, 4, 6, 8, 16],
            maxBackoffSec: 8
        )
        #expect(cap == 5)
    }

    /// fallback 路径:`maxBackoffSec` 大于 ladder 最大值,所有档位都 ≤ cap
    /// → `firstIndex(where:)` 返 nil → 落到 `ladder.count`。语义"整张 ladder
    /// 都在窗口内,failures 想涨多少涨多少"——bumpFailures 那边 cap = count
    /// 等于不 cap(因为 failures 最多用到 ladder.count - 1 索引)。
    @Test("maxBackoff 大于 ladder 最大值 → ladder.count")
    func capLargerThanLadderMaxReturnsCount() {
        let ladder: [TimeInterval] = [1, 2, 4, 8, 16, 32]
        let cap = Backoff.failuresCap(ladder: ladder, maxBackoffSec: 1000)
        #expect(cap == ladder.count)
        #expect(cap == 6)
    }

    /// 空 ladder 边界——`firstIndex(where:)` 在空数组上返 nil,fallback 到
    /// `ladder.count = 0`。调用方传空 ladder 是配置错误,但函数不该崩;
    /// 返 0 让 bumpFailures 直接把 failures cap 在 0(等于"永远在 grace 内
    /// 也只能用第一次")——足够 safe-by-default。
    @Test("空 ladder → 0")
    func emptyLadderReturnsZero() {
        let cap = Backoff.failuresCap(ladder: [], maxBackoffSec: 8)
        #expect(cap == 0)
    }
}

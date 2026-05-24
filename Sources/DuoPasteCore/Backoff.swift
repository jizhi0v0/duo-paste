import Foundation

/// 退避相关纯算法工具集——从 iOS `PeerWebSocket` 抽出来,让算法可被 SwiftPM
/// 测试覆盖。
///
/// **为什么不直接在 iOS 测**:`PeerWebSocket` 是 `@MainActor @Observable final
/// class`,依赖 `Network` / UIKit-adjacent API,SwiftPM 测试跑不到 iOS 类型。
/// 把"从 ladder 派生 failures cap"这条契约抽到 pure Swift 函数后,
/// `Tests/DuoPasteCoreTests/BackoffCapTests.swift` 可以钉它,后人改回手写常量
/// 或写错 firstIndex 谓词 CI 就 fail。
///
/// 见 PR #40 review #7。
public enum Backoff {
    /// 从 `ladder` 找出第一个 **严格大于** `maxBackoffSec` 的档位的索引 ——
    /// 这个索引等价于 "retry 次数 cap":只要 `failures <= cap`,
    /// `ladder[failures - 1]` 不会超过 `maxBackoffSec`。
    ///
    /// 全部档位都 ≤ `maxBackoffSec` 时返回 `ladder.count`(fallback),意味着
    /// "整张 ladder 都在 grace 窗口允许范围内,不用 cap"。
    /// 空 ladder 返回 0。
    ///
    /// **契约**:`backoffLadder` 插档(比如加 6s 进 `[1,2,4,8,...]` 变
    /// `[1,2,4,6,8,...]`)cap 自动跟随。
    /// 不要回退到手写常量——会让 ladder 改动不再驱动 cap。
    ///
    /// - Parameters:
    ///   - ladder: 退避秒数阶梯,典型 `[1, 2, 4, 8, 16, 32, 60, 120, 300]`
    ///   - maxBackoffSec: 单次重试间隔上限。failures 增量被 cap 让
    ///     `backoffSeconds(failures)` 不超这个秒数
    /// - Returns: failures 增量硬上限,见上
    public static func failuresCap(ladder: [TimeInterval], maxBackoffSec: TimeInterval) -> Int {
        ladder.firstIndex(where: { $0 > maxBackoffSec }) ?? ladder.count
    }
}

import Foundation
import CryptoKit

/// 跨设备 paste-echo 抑制器：本机 pasteBack 写 NSPasteboard 后，把这次 paste 的内容指纹
/// + 记录时刻 暂存在内存里；PullWorker 收到对端通过 Universal Clipboard "反弹"回来的同内容
/// mirror 行时查这个集合，命中则 skip 不写 mirror，避免历史里出现一条"我刚 paste 的副本"。
///
/// 为什么 RemoteIngester / PullWorker 现有的 `crossDeviceDedupWindowNs` 防不住这个：
/// 那层 dedup 找的是「本机 origin=self 同内容 own item 在 ±窗口内是否已存」。但 paste
/// 路径**不会**写本机 own item（pasteBack 只动 NSPasteboard，watcher 被 suppressUpToCurrent
/// 跳过），所以 dedup 找不到锚点 → 反弹的 mirror 行被照样写入。
///
/// **关键约束（P2 回归保护）**：命中需要同时满足 `fp 匹配` + `候选行 captured_at_ns >=
/// 记录时刻 - 5s skew`。原因：纯按 fp 匹配会在「client 离线一段时间后 catch-up」时把
/// **历史**的、内容碰巧相同的合法 mirror 行也 skip，且 cursor 仍然前进 → 那条行永远
/// 进不了 mirror（除非 promote-primary 触发清空）。加上"captured 必须在 record 之后"的
/// 约束后：echo 路径（对端 Continuity capture 发生在本机 paste 之后 ≤1s）满足；历史路径
/// 不满足，安全放行。
///
/// 时间窗口：典型路径是 paste → Continuity 同步 ≤1s → 对端 watcher capture → 对端 push 到
/// primary（若对端是 client）→ 本机 PullWorker 下一次 tick 拉到。最坏情况受 PullWorker
/// `intervalSec`（默认 30s）+ 对端 push 节奏支配。300s 默认给足 buffer，内存代价是每次
/// paste 一个 ~96B 条目。
///
/// 线程安全：NSLock。读写都低频（每次 paste 一次写，每次 PullWorker tick 几次读），
/// 完全没竞争。`@unchecked Sendable` 跟 [[mirror-status]] 一样的模式。
public final class PasteSuppressionSet: @unchecked Sendable {
    /// 内容指纹格式：
    /// - text/rtf/html/url/file → `"t:" + sha256hex(textFull utf8 bytes)`
    /// - image → `"b:" + blob_sha256`（已经是 sha256 hex）
    ///
    /// 前缀区分两个命名空间，避免 image blob_sha256 跟某个文本的 sha256 数值碰撞——
    /// 概率近 0 但廉价就避免。
    public typealias Fingerprint = String

    /// 单个 paste 锚点：一次 pasteBack 一份。`recordedAtNs` 是 paste 发生的时刻，
    /// `expireAtNs` = recordedAtNs + ttlNs（每个 anchor 独立 TTL，互不传染）。
    private struct Anchor {
        var recordedAtNs: Int64
        var expireAtNs: Int64
    }

    /// 单条 entry：同 fp 的活跃锚点列表，升序排列。
    ///
    /// **为什么不是单一 hull（earliest..latest）**：hull 会把两次相距较远的 paste
    /// 之间的"真空地带"也一并 suppress 掉。例如 T0 paste "A" → T30 用户在对端独立
    /// Cmd+C "A"（短串碰撞很常见）→ T60 又 paste "A"。hull = [T0-skew, T60+echo]，
    /// T30 那条合法 capture 被误杀且 cursor 推进后永远拉不回来。
    ///
    /// 多锚点 + OR 语义解决：每个 paste 是独立 `[a - skew, a + echoWindow]`，命中
    /// 任意一个即 suppress。锚点之间的"真空地带"自然不覆盖，独立 capture 放行。
    ///
    /// **延迟 echo 保护（P2 review）**：T0 paste 的 echo 在本机 pull 之前 T20 又
    /// paste 同内容——T0 锚点仍在列表里，延迟 echo 拉回来时仍命中。
    private struct Entry {
        var anchors: [Anchor]
    }

    /// 单 fp 锚点上限。同串短时间内反复 paste 不会让 entry 无界增长。16 远超日常
    /// 使用；达上限时 FIFO 淘汰最旧锚点（最旧 echo 大概率早已到达或永远不会来了）。
    public static let maxAnchorsPerFingerprint: Int = 16

    private let lock = NSLock()
    private var entries: [Fingerprint: Entry] = [:]
    private let nowNs: @Sendable () -> Int64

    /// 候选行 captured 时间相对 paste record 时间的容忍 skew（纳秒）。
    /// 默认 5s：覆盖典型 NTP 同步下两台 Mac 的时钟漂移。Continuity 同步本身 < 1s，
    /// 真 echo 几乎总是 candidate > record（mini watcher tick 之后才 stamp）。
    public static let defaultSkewNs: Int64 = 5_000_000_000

    /// "echo 窗口"上界（纳秒）。候选 captured 在 `[record - skew, record + echoWindow]`
    /// 之内才视为 echo 抑制。默认 10s——覆盖 Continuity sync (< 1s) + 对端 watcher tick
    /// (200ms) + 对端 push 节奏 + 余量。
    ///
    /// **不要把 PullWorker tick 算进来**：shouldSuppress 比对的是候选行 `captured_at_ns`
    /// （对端 watcher 在抓到 Continuity 反弹那一刻 stamp 的时间戳），跟本机 PullWorker
    /// 什么时候把它拉回来无关。pull 延迟只是延后我们"看见"这条 mirror 行，entry TTL
    /// (默认 300s) 已覆盖 entry 在内存里活够长。把 pull 间隔算进 capture 窗口 → 1 分钟
    /// 内用户在对端独立 Cmd+C 同内容 → 被误判成 echo 永久 skip。
    ///
    /// **跟内存 TTL 解耦的关键**：内存 TTL（pasteBack 传给 record 的 ttlSec）只决定
    /// "entry 在内存里存多久"；echo window 是单独的"什么 capture 时刻才算 echo"。
    /// 这是 P2 review #2 的回归保护。
    public static let defaultEchoWindowNs: Int64 = 10_000_000_000

    public init(nowNs: @escaping @Sendable () -> Int64 = { Clock.nowNs() }) {
        self.nowNs = nowNs
    }

    /// 记下一次 paste 的指纹，TTL 秒后自动过期。重复 record 同一指纹 → 刷新到本次的
    /// recordedAtNs（更新锚点）+ 取较晚的 expireAt（不缩窗口）。
    public func record(fingerprint: Fingerprint, ttlSec: TimeInterval) {
        let now = nowNs()
        let newAnchor = Anchor(
            recordedAtNs: now,
            expireAtNs: now + Int64(ttlSec * 1_000_000_000)
        )
        lock.lock(); defer { lock.unlock() }
        var entry = entries[fingerprint] ?? Entry(anchors: [])
        // 先剔除本 entry 已过期的锚点，再 append 新的
        entry.anchors.removeAll { $0.expireAtNs <= now }
        entry.anchors.append(newAnchor)
        // 上界保护：FIFO 淘汰最旧锚点
        let overflow = entry.anchors.count - Self.maxAnchorsPerFingerprint
        if overflow > 0 {
            entry.anchors.removeFirst(overflow)
        }
        entries[fingerprint] = entry
        pruneExpiredLocked(now: now)
    }

    /// 是否应当抑制候选行。候选 captured_at_ns 命中 **任意一个** 活跃锚点的窗口
    /// `[a.recordedAtNs - skewNs, a.recordedAtNs + echoWindowNs]` 即返回 true。
    ///
    /// 多锚点 OR 语义而非 hull：
    /// - 锚点 a1=T0, a2=T60 → 窗口是两段 `[T0-5s, T0+10s] ∪ [T60-5s, T60+10s]`，
    ///   中间 T30 的合法独立 capture 不被覆盖（hull 方案会误杀）
    /// - 仍能挡延迟 echo：T0 paste 的 echo 在 T20 之后才被本机 pull 拉到时，a1 仍在
    public func shouldSuppress(
        fingerprint: Fingerprint,
        candidateCapturedAtNs: Int64,
        skewNs: Int64 = PasteSuppressionSet.defaultSkewNs,
        echoWindowNs: Int64 = PasteSuppressionSet.defaultEchoWindowNs
    ) -> Bool {
        let now = nowNs()
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        guard let entry = entries[fingerprint] else { return false }
        for a in entry.anchors {
            let lo = a.recordedAtNs - skewNs
            let hi = a.recordedAtNs + echoWindowNs
            if candidateCapturedAtNs >= lo && candidateCapturedAtNs <= hi {
                return true
            }
        }
        return false
    }

    /// 测试用：当前活跃 entry 数（已清过期后）。
    public func activeCount() -> Int {
        let now = nowNs()
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        return entries.count
    }

    private func pruneExpiredLocked(now: Int64) {
        for (k, var entry) in entries {
            entry.anchors.removeAll { $0.expireAtNs <= now }
            if entry.anchors.isEmpty {
                entries.removeValue(forKey: k)
            } else {
                entries[k] = entry
            }
        }
    }

    // MARK: - Fingerprint helpers

    /// 文本类（text/rtf/html/url/file）指纹：sha256 of utf8 bytes，加 "t:" 前缀。
    public static func fingerprint(text: String) -> Fingerprint {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "t:" + hex
    }

    /// 图片指纹：直接复用 blob_sha256（已经是 sha256 hex），加 "b:" 前缀。
    public static func fingerprint(blobSha256: String) -> Fingerprint {
        return "b:" + blobSha256
    }

    /// 从 Item 推指纹。kind=image 时优先用 blobSha256；其他 kind 用 textFull。
    /// 两者都 nil 时返 nil（理论上不应发生——pasteBack 不会写空 item）。
    public static func fingerprint(forItem item: Item) -> Fingerprint? {
        if item.kind == .image, let sha = item.blobSha256 {
            return fingerprint(blobSha256: sha)
        }
        if let s = item.textFull {
            return fingerprint(text: s)
        }
        return nil
    }
}

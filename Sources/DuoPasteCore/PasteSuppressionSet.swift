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

    /// 单条 entry：除了过期时间，还要记下"是什么时刻 record 的"——查询时跟候选行
    /// `captured_at_ns` 比对，挡 catch-up 误杀历史行。
    private struct Entry {
        var expireAtNs: Int64
        var recordedAtNs: Int64
    }

    private let lock = NSLock()
    private var entries: [Fingerprint: Entry] = [:]
    private let nowNs: @Sendable () -> Int64

    /// 候选行 captured 时间相对 paste record 时间的容忍 skew（纳秒）。
    /// 默认 5s：覆盖典型 NTP 同步下两台 Mac 的时钟漂移。Continuity 同步本身 < 1s，
    /// 真 echo 几乎总是 candidate > record（mini watcher tick 之后才 stamp）。
    public static let defaultSkewNs: Int64 = 5_000_000_000

    /// "echo 窗口"上界（纳秒）。候选 captured 在 `[record - skew, record + echoWindow]`
    /// 之内才视为 echo 抑制。默认 60s——覆盖 Continuity sync (< 1s) + PullWorker 30s 默认
    /// tick + 若干余量。
    ///
    /// **跟内存 TTL 解耦的关键**：内存 TTL（pasteBack 传给 record 的 ttlSec）只决定
    /// "entry 在内存里存多久"；echo window 是单独的"什么 capture 时刻才算 echo"。
    /// 否则会把"paste 之后几分钟用户在对端独立 Cmd+C 同内容"也当 echo 永久 skip——
    /// 这是 P2 review #2 的回归保护。
    public static let defaultEchoWindowNs: Int64 = 60_000_000_000

    public init(nowNs: @escaping @Sendable () -> Int64 = { Clock.nowNs() }) {
        self.nowNs = nowNs
    }

    /// 记下一次 paste 的指纹，TTL 秒后自动过期。重复 record 同一指纹 → 刷新到本次的
    /// recordedAtNs（更新锚点）+ 取较晚的 expireAt（不缩窗口）。
    public func record(fingerprint: Fingerprint, ttlSec: TimeInterval) {
        let now = nowNs()
        let newExpire = now + Int64(ttlSec * 1_000_000_000)
        lock.lock(); defer { lock.unlock() }
        let expireAt: Int64
        if let existing = entries[fingerprint], existing.expireAtNs > newExpire {
            expireAt = existing.expireAtNs
        } else {
            expireAt = newExpire
        }
        // 锚点（recordedAtNs）总是刷新到最新一次 paste 时刻——下次再 paste 同串就把
        // 锚点往后挪，旧的对端 echo 不再误"早于锚点"
        entries[fingerprint] = Entry(expireAtNs: expireAt, recordedAtNs: now)
        pruneExpiredLocked(now: now)
    }

    /// 是否应当抑制候选行。要求 fp 在窗口内 **且** 候选 captured_at_ns 落在
    /// `[recordedAtNs - skewNs, recordedAtNs + echoWindowNs]` 区间内。
    ///
    /// - 下界（`record - skew`）：挡 catch-up 误杀历史行（同内容碰撞但 captured 远早于本次 paste）
    /// - 上界（`record + echoWindow`）：挡未来的合法独立同内容捕获（用户分钟后在对端 Cmd+C
    ///   同样的串，跟本次 paste 不是 echo 关系，必须放行）
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
        let lo = entry.recordedAtNs - skewNs
        let hi = entry.recordedAtNs + echoWindowNs
        return candidateCapturedAtNs >= lo && candidateCapturedAtNs <= hi
    }

    /// 测试用：当前活跃 entry 数（已清过期后）。
    public func activeCount() -> Int {
        let now = nowNs()
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        return entries.count
    }

    private func pruneExpiredLocked(now: Int64) {
        entries = entries.filter { $0.value.expireAtNs > now }
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

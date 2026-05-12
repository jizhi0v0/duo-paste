import Foundation
import CryptoKit

/// 跨设备 paste-echo 抑制器：本机 pasteBack 写 NSPasteboard 后，把这次 paste 的内容指纹
/// 暂存在内存里；PullWorker 收到对端通过 Universal Clipboard "反弹"回来的同内容 mirror
/// 行时查这个集合，命中则 skip 不写 mirror，避免历史里出现一条"我刚 paste 的副本"。
///
/// 为什么 RemoteIngester / PullWorker 现有的 `crossDeviceDedupWindowNs` 防不住这个：
/// 那层 dedup 找的是「本机 origin=self 同内容 own item 在 ±窗口内是否已存」。但 paste
/// 路径**不会**写本机 own item（pasteBack 只动 NSPasteboard，watcher 被 suppressUpToCurrent
/// 跳过），所以 dedup 找不到锚点 → 反弹的 mirror 行被照样写入。
///
/// 时间窗口：典型路径是 paste → Continuity 同步 ≤1s → 对端 watcher capture → 对端 push 到
/// primary（若对端是 client）→ 本机 PullWorker 下一次 tick 拉到。最坏情况受 PullWorker
/// `intervalSec`（默认 30s）+ 对端 push 节奏支配。300s 默认给足 buffer，内存代价是每次
/// paste 一个 ~80B 条目。
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

    private let lock = NSLock()
    private var entries: [Fingerprint: Date] = [:]   // fp → expireAt
    private let nowDate: @Sendable () -> Date

    public init(nowDate: @escaping @Sendable () -> Date = { Date() }) {
        self.nowDate = nowDate
    }

    /// 记下一次 paste 的指纹，TTL 秒后自动过期。重复 record 同一指纹 → 取较晚的 expireAt。
    public func record(fingerprint: Fingerprint, ttlSec: TimeInterval) {
        let expireAt = nowDate().addingTimeInterval(ttlSec)
        lock.lock(); defer { lock.unlock() }
        if let existing = entries[fingerprint], existing > expireAt {
            return  // 已有的窗口更长，不缩
        }
        entries[fingerprint] = expireAt
        pruneExpiredLocked()
    }

    /// 命中即返 true。同时机会主义清理过期 entry。
    public func contains(_ fingerprint: Fingerprint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()
        return entries[fingerprint] != nil
    }

    /// 测试用：当前活跃 entry 数（已清过期后）。
    public func activeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()
        return entries.count
    }

    private func pruneExpiredLocked() {
        let now = nowDate()
        entries = entries.filter { $0.value > now }
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

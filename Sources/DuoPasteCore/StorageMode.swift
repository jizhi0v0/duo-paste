import Foundation

/// 节点 blob 存储模式。对齐 iCloud「优化存储」心智的二态抽象。
///
/// - `.full`（默认）：完整 mirror。PullWorker 每 tick 顺路把对端新行的 blob 字节拉到本机。
///   mesh 拓扑的字面语义——每个节点保留完整副本。daily-driver 双 Mac 场景下存储不是约束。
/// - `.optimized`：按需拉取。PullWorker 不拉字节；UI 渲染缩略图 / Space 预览 / Enter
///   粘贴时按需 GET /blob/<sha> 拉。给未来 iOS peer / 小盘备机 / 临时节点用。
///
/// 替代之前的 `mesh.eager_blobs: Bool`——布尔语义不清（eager=true 是「完整」还是「积极」？
/// 用户读 config 困惑）。`storage_mode: full|optimized` 跟 iCloud 一致用户立刻懂。
public enum StorageMode: String, Codable, Sendable, CaseIterable {
    case full
    case optimized

    /// 默认 `.full`——mesh 字面语义。老 `eager_blobs=false`（PR cloudy-mirroring-walnut 之前
    /// 的默认）映射到 `.full` 而非 `.optimized`，让升级用户自动得到「修复后的正确语义」
    /// （详 plan §设计决策 老 config 兼容）
    public static let `default`: StorageMode = .full

    public var description: String {
        switch self {
        case .full: return "full (完整 mirror)"
        case .optimized: return "optimized (按需拉取)"
        }
    }
}

import SwiftUI
import AppKit
import DuoPasteCore
import DuoPasteSync

/// iCloud 风格 ☁️ 角标 —— 给 `storage_mode=.optimized` 模式下「blob 在 peer 上但本机没下载」
/// 的 ItemCard 显示。让用户能区分「本地有」vs「peer 上有但还没下载」vs「正在下载」vs「下载失败」。
///
/// 设计：跟 iCloud Photos 的「☁️」+「⬇️ 下载中」对齐。`.full` 模式永远 `.local`（PullWorker 顺路
/// 拉好了），不显示；`.optimized` 模式才有可能进入 `.cloud / .downloading / .failed` 状态。
///
/// **不阻塞 UI 渲染**：badge 只是「附加可点 hint」，缩略图本身的缺图占位已经够告知用户。
/// 用户点 ☁️ 主动触发 fetch；或自然走 ImageThumbnailCache.thumbnail 的 lazy 路径，
/// 二者都把字节落进 BlobStore，下一帧重渲缩略图。
enum CloudBadgeState: Equatable, Sendable {
    /// 本机已有 blob（或非 optimized 模式）→ 不显示 badge
    case local
    /// optimized 模式 + 本机缺 blob → 显示 ☁️ 提示「peer 上有，点这里下载」
    case cloud
    /// 用户点了或自动 prefetch 中 → 显示 ProgressView
    case downloading
    /// 上次 fetch 失败 → 显示红色 ! 让用户能再次点重试
    case failed(reason: String)
}

@MainActor
struct CloudBadgeView: View {
    let state: CloudBadgeState
    /// 点击触发主动下载（state==.cloud / .failed 时有效）。caller 负责实际 fetch 逻辑
    var onTap: () -> Void = {}

    var body: some View {
        switch state {
        case .local:
            EmptyView()
        case .cloud:
            Button(action: onTap) {
                badgeBody(systemName: "icloud.and.arrow.down", tint: .secondary)
            }
            .buttonStyle(.plain)
            .help("点击下载到本机")
        case .downloading:
            badgeBody(progress: true)
        case .failed(let reason):
            Button(action: onTap) {
                badgeBody(systemName: "exclamationmark.icloud", tint: .red)
            }
            .buttonStyle(.plain)
            .help("下载失败：\(reason)。点击重试")
        }
    }

    /// 圆形玻璃底 + 中心 SF Symbol / spinner，跟卡片右上 source app icon 同款尺寸（22pt）
    @ViewBuilder
    private func badgeBody(systemName: String? = nil, tint: Color = .primary, progress: Bool = false) -> some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Circle().fill(.ultraThinMaterial)
            } else {
                Circle().fill(.ultraThinMaterial)
            }
            if progress {
                ProgressView()
                    .controlSize(.mini)
            } else if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// 计算 ItemCard 应该用哪个 CloudBadgeState。纯函数方便单测——
/// (storageMode, hasBlobLocally, isDownloading, lastError) → state
@MainActor
enum CloudBadgeStateCalculator {
    static func state(
        storageMode: StorageMode,
        item: Item,
        blobs: BlobStore,
        isDownloading: Bool,
        lastError: String?
    ) -> CloudBadgeState {
        // .full 模式或不带 blob 的 item（text/url 等）→ 永远 .local 不显示
        guard storageMode == .optimized,
              let sha = item.blobSha256,
              item.kind == .image || item.kind == .file else {
            return .local
        }
        if blobs.exists(sha256: sha) { return .local }
        if isDownloading { return .downloading }
        if let err = lastError { return .failed(reason: err) }
        return .cloud
    }
}

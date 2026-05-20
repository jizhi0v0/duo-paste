import SwiftUI
import UIKit
import QuartzCore
import DuoPasteCore

/// 单条剪贴项卡片。`.onTapGesture` 单击复制 + `.contextMenu` 长按菜单。
///
/// 不用 Button —— Button(.plain) 在 iOS 上跟 contextMenu 协同时按下/松手有
/// scale 回弹动画(用户视感"重新触发了一次"),换 onTapGesture 干净。
///
/// share 走 ShareCoordinator(根 view 持有的 sheet 状态)而不是 ShareLink,
/// 因为 ShareLink Transferable resolution 会在 contextMenu 展开时被反复 evaluate,
/// 是首次卡顿主要来源。
struct HistoryCellView: View {
    let item: Item

    @Environment(BlobCache.self) private var blobs
    @Environment(AppIconCache.self) private var appIcons
    @Environment(HistoryStore.self) private var store
    @Environment(ShareCoordinator.self) private var shareCoord
    @Environment(PeerSyncCoordinator.self) private var coordinator
    @State private var copyPulse: Int = 0
    @State private var copyState: CopyState = .idle
    @State private var copyBadgeTask: Task<Void, Never>?

    /// 复制反馈四态:闲 / 正在拉(image 未命中 cache)/ 成功 / 拉取失败
    enum CopyState: Equatable {
        case idle
        case copying     // image 未命中 blob cache,起 fetch 中,先给 immediate badge 反馈
        case copied      // 已写 pasteboard
        case failed      // fetch / decode 失败
    }

    var body: some View {
        cardSurface
            .contentShape(.rect(cornerRadius: 18))
            .onTapGesture { triggerCopy() }
            .contextMenu {
                contextMenuItems()
            } preview: {
                // 显式 preview 锁定尺寸跟卡片一致,避免 iOS 把含 overlay 溢出
                // 的渲染包围盒整体拍下来导致 preview 位置偏移
                cardSurface
                    .frame(width: 280)
                    .padding(2)
            }
            .sensoryFeedback(.success, trigger: copyPulse)
    }

    /// 卡片视觉本体——含 padding / glassEffect / 右上 app icon(或 kind 兜底) / 复制 badge
    private var cardSurface: some View {
        cardBody
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .overlay(alignment: .topTrailing) { topRightIcon.padding(10) }
            .overlay(alignment: .topLeading) { copiedBadge }
            .task(id: item.sourceApp ?? "") {
                // sourceApp 非空 + cache 没命中 → 起拉取 task。AppIconCache 内部
                // 去重(并发同 bundleID 共享 inflight),notFound 黑名单挡住反复 404
                if let bid = item.sourceApp,
                   !bid.isEmpty,
                   appIcons.cached(bid) == nil {
                    _ = await appIcons.fetch(bid).value
                }
            }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayPreview)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(5, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 右上 kind icon 占 ~28pt,首行末尾留位避免压住
                .padding(.trailing, 24)

            Spacer(minLength: 0)
            metaRow
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                Text(Self.relativeLabel(item.capturedAt, now: context.date))
            }
            if let name = item.sourceAppName, !name.isEmpty {
                Text("·")
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let sha = item.blobSha256, blobs.isLoading(sha) {
                Text("·")
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// 卡片右上 icon。优先级:
    /// 1. AppIconCache 命中 sourceApp → 显示 macOS app icon UIImage
    /// 2. 命中 fetch 失败 / sourceApp 为空 → kind SF Symbol 兜底
    @ViewBuilder
    private var topRightIcon: some View {
        if let bid = item.sourceApp, let img = appIcons.cached(bid) {
            Image(uiImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: item.kindIconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    @ViewBuilder
    private var copiedBadge: some View {
        switch copyState {
        case .idle:
            EmptyView()
        case .copying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("复制中")
            }
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.85), in: .capsule)
            .foregroundStyle(.white)
            .padding(8)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        case .copied:
            Text("已复制")
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.green.opacity(0.85), in: .capsule)
                .foregroundStyle(.white)
                .padding(8)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        case .failed:
            Text("拉取失败")
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.red.opacity(0.85), in: .capsule)
                .foregroundStyle(.white)
                .padding(8)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    @ViewBuilder
    private func contextMenuItems() -> some View {
        Button {
            triggerCopy()
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Button {
            triggerShare()
        } label: {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        if let sha = item.blobSha256, blobs.isLoading(sha) {
            Button(role: .destructive) {
                blobs.cancel(sha)
            } label: {
                Label("取消下载", systemImage: "xmark.circle")
            }
        }
        // 删除走"乐观立即消失 + 后台 DELETE"——失败时下一次 /since 拉自然 re-insert,
        // 用户可重试。剪贴板条目不珍贵,不做二次确认,体验跟"复制"对称
        Button(role: .destructive) {
            triggerDelete()
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    /// 长按预览。固定 300x300,内嵌 ScrollView 让长文本可滚不撑高度。
    /// task 自动 kick image fetch — 用户松手点"分享"时多半 cache 命中。
    @ViewBuilder
    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewBody
                .frame(width: 300, height: 240)
                .clipped()

            Divider()

            HStack(spacing: 6) {
                Image(systemName: item.kindIconName)
                Text(item.kind.rawValue)
                Text("·")
                Text(Self.relativeLabel(item.capturedAt))
                Spacer()
                if let sha = item.blobSha256, blobs.isLoading(sha) {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .onAppear {
            UILatencyLog.mark("context menu preview appear", itemLogDetail())
        }
        .onDisappear {
            UILatencyLog.mark("context menu preview disappear", itemLogDetail())
        }
        .task {
            if item.kind == .image,
               let sha = item.blobSha256,
               blobs.cached(sha) == nil,
               !blobs.isCancelled(sha) {
                let start = CACurrentMediaTime()
                UILatencyLog.mark("preview image fetch begin", itemLogDetail("sha=\(shortSHA(sha))"))
                do {
                    let data = try await blobs.fetch(sha).value
                    UILatencyLog.mark(
                        "preview image fetch end",
                        itemLogDetail("bytes=\(data.count) elapsed_ms=\(UILatencyLog.elapsedMS(since: start))")
                    )
                } catch {
                    UILatencyLog.mark(
                        "preview image fetch failed",
                        itemLogDetail("error=\(error.localizedDescription) elapsed_ms=\(UILatencyLog.elapsedMS(since: start))")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var previewBody: some View {
        if item.kind == .image,
           let sha = item.blobSha256,
           let data = blobs.cached(sha),
           let img = decodeImage(data, reason: "preview", sha: sha) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.kind == .image {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                if let sha = item.blobSha256, blobs.isLoading(sha) {
                    ProgressView().controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(previewText)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    private var previewText: String {
        let full = item.displayFull
        let limit = 4_000
        guard full.count > limit else { return full }
        return String(full.prefix(limit)) + "\n\n..."
    }

    // MARK: - Actions

    private func triggerCopy() {
        UILatencyLog.mark("copy action begin", itemLogDetail())
        // 乐观顶 — 立即本机重排,不等 Mac UCB → /since 链路。详见 HistoryStore.bumpToFront
        store.bumpToFront(id: item.id)
        // 跨设备一致:POST /bump 让 Mac DB 也顶 → 其他 peer 通过 cursor_advanced 看到。
        // best-effort,swallow 错误(网络抖 / 404 都不影响本机已完成的复制)
        coordinator.bumpItemOnServer(id: item.id)

        if item.kind == .image, let sha = item.blobSha256 {
            if let cached = blobs.cached(sha) {
                UILatencyLog.mark("copy image cache hit", itemLogDetail("bytes=\(cached.count)"))
                copyImageBytes(cached, sha: sha, reason: "copy cached")
                return
            }
            // 未命中 — 立即出 "复制中" badge 给 immediate 反馈,async fetch 完再切到
            // .copied / .failed。原先无任何反馈用户体感"卡了"
            showBadge(.copying, autoHideMs: nil)
            Task {
                do {
                    let start = CACurrentMediaTime()
                    UILatencyLog.mark("copy image fetch begin", itemLogDetail("sha=\(shortSHA(sha))"))
                    let data = try await blobs.fetch(sha).value
                    UILatencyLog.mark(
                        "copy image fetch end",
                        itemLogDetail("bytes=\(data.count) elapsed_ms=\(UILatencyLog.elapsedMS(since: start))")
                    )
                    copyImageBytes(data, sha: sha, reason: "copy fetched")
                } catch {
                    UILatencyLog.mark("copy image failed", itemLogDetail("error=\(error.localizedDescription)"))
                    showBadge(.failed, autoHideMs: 1800)
                }
            }
        } else if item.kind == .file {
            // .file kind text_full 是 Mac 上的文件路径——写到 iOS UIPasteboard 没有用
            // (文件不在 iOS 上,paste 到别处只是个无意义路径字符串),而且 UCB 会把这字符串
            // 送回 Mac 让 watcher 当 kind=text 重新 capture——跟原 kind=file 行 dedup
            // miss (kind 不同就不 merge) → 出现重复 entry。
            // 只 bump 不写 UIPasteboard,跨设备语义靠 POST /bump
            UILatencyLog.mark("copy file: skip pasteboard write (bump only)", itemLogDetail())
            flashCopied()
        } else {
            UILatencyLog.mark("copy text pasteboard set begin", itemLogDetail("chars=\(item.displayFull.count)"))
            UIPasteboard.general.string = item.displayFull
            UILatencyLog.mark("copy text pasteboard set end", itemLogDetail())
            flashCopied()
        }
    }

    /// 删除路径——本机立即移除 + 后台调 DELETE /item/<id> 让 Mac DB 软删
     /// + broadcaster 推 cursor_advanced 让其他 peer 看到 tombstone。
     /// 失败 swallow(coordinator 内 fanout 路径已记日志);下次 /since 自然 reconcile
    private func triggerDelete() {
        UILatencyLog.mark("delete action begin", itemLogDetail())
        store.removeOptimistic(id: item.id)
        coordinator.deleteItemOnServer(id: item.id)
    }

    private func triggerShare() {
        UILatencyLog.mark("share action begin", itemLogDetail())
        if item.kind == .image, let sha = item.blobSha256 {
            if let cached = blobs.cached(sha) {
                UILatencyLog.mark("share image cache hit", itemLogDetail("bytes=\(cached.count)"))
                shareImageBytes(cached, sha: sha, reason: "share cached")
                return
            }
            Task {
                do {
                    let start = CACurrentMediaTime()
                    UILatencyLog.mark("share image fetch begin", itemLogDetail("sha=\(shortSHA(sha))"))
                    let data = try await blobs.fetch(sha).value
                    UILatencyLog.mark(
                        "share image fetch end",
                        itemLogDetail("bytes=\(data.count) elapsed_ms=\(UILatencyLog.elapsedMS(since: start))")
                    )
                    shareImageBytes(data, sha: sha, reason: "share fetched")
                } catch {
                    UILatencyLog.mark("share image failed", itemLogDetail("error=\(error.localizedDescription)"))
                }
            }
        } else {
            UILatencyLog.mark("share text ready", itemLogDetail("chars=\(item.displayFull.count)"))
            shareCoord.share([item.displayFull])
        }
    }

    /// 字节透传到 pasteboard — 不走 UIImage 重编,保原始 sha 完整性.
    /// 未识别 magic 走 UIImage fallback(覆盖 TIFF/BMP/老格式,代价是重编).
    private func copyImageBytes(_ data: Data, sha: String, reason: String) {
        let sniffed = Self.sniffImageUTI(data)
        if let uti = sniffed.uti {
            UIPasteboard.general.setData(data, forPasteboardType: uti)
            UILatencyLog.mark(
                "copy image pasteboard set",
                itemLogDetail("reason=\(reason) bytes=\(data.count) uti=\(uti)")
            )
            flashCopied()
            return
        }
        UILatencyLog.mark("copy image sniff miss, fallback to UIImage", itemLogDetail("bytes=\(data.count)"))
        guard let img = decodeImage(data, reason: reason, sha: sha) else {
            UILatencyLog.mark("copy image fallback decode failed", itemLogDetail())
            return
        }
        UIPasteboard.general.image = img
        UILatencyLog.mark("copy image pasteboard set fallback", itemLogDetail())
        flashCopied()
    }

    /// 写 tmp 文件后 share file URL —— "保存到相册/文件" 拿到的是原始字节,不重编.
    /// 写文件失败再降级 UIImage(避免完全无法分享).
    private func shareImageBytes(_ data: Data, sha: String, reason: String) {
        let sniffed = Self.sniffImageUTI(data)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sha.prefix(16)).\(sniffed.ext)")
        do {
            try data.write(to: url, options: .atomic)
            UILatencyLog.mark(
                "share image temp file ready",
                itemLogDetail("reason=\(reason) bytes=\(data.count) ext=\(sniffed.ext)")
            )
            shareCoord.share([url])
        } catch {
            UILatencyLog.mark("share image temp file failed", itemLogDetail("error=\(error.localizedDescription)"))
            if let img = decodeImage(data, reason: reason, sha: sha) {
                shareCoord.share([img])
            }
        }
    }

    /// magic-byte 嗅探 — 不进 UIImage 解码,只看 header 前 12B 判 UTI.
    /// 返回 nil → 未识别,调用方走 UIImage fallback.
    private static func sniffImageUTI(_ data: Data) -> (uti: String?, ext: String) {
        guard data.count >= 12 else { return (nil, "bin") }
        let b = [UInt8](data.prefix(12))
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            return ("public.png", "png")
        }
        // JPEG: FF D8 FF
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            return ("public.jpeg", "jpg")
        }
        // GIF: "GIF8"
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 {
            return ("com.compuserve.gif", "gif")
        }
        // WebP: "RIFF"...."WEBP"
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            return ("org.webmproject.webp", "webp")
        }
        // HEIC/HEIF: bytes 4..8 = "ftyp", bytes 8..12 = heic/heix/mif1/hevc/heim/heis
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = (b[8], b[9], b[10], b[11])
            switch brand {
            case (0x68, 0x65, 0x69, 0x63),  // heic
                 (0x68, 0x65, 0x69, 0x78),  // heix
                 (0x68, 0x65, 0x69, 0x6D),  // heim
                 (0x68, 0x65, 0x69, 0x73),  // heis
                 (0x6D, 0x69, 0x66, 0x31),  // mif1
                 (0x68, 0x65, 0x76, 0x63):  // hevc
                return ("public.heic", "heic")
            default:
                break
            }
        }
        // TIFF (Mac screenshot 偶发): II*\0 / MM\0*
        if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00) ||
           (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) {
            return ("public.tiff", "tiff")
        }
        return (nil, "bin")
    }

    /// 成功路径 — 弹"已复制"绿 badge + 触觉。900ms 后自动消
    private func flashCopied() {
        UILatencyLog.mark("copy badge show", itemLogDetail())
        copyPulse &+= 1
        showBadge(.copied, autoHideMs: 900)
    }

    /// badge 状态机统一入口 — autoHideMs nil = 不自动消(留给后续 state 切换覆盖)
    private func showBadge(_ state: CopyState, autoHideMs: Int?) {
        copyBadgeTask?.cancel()
        withAnimation(.spring(response: 0.3)) { copyState = state }
        guard let ms = autoHideMs else { return }
        copyBadgeTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(ms))
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) { copyState = .idle }
                UILatencyLog.mark("copy badge hide", itemLogDetail())
            }
        }
    }

    private func decodeImage(_ data: Data, reason: String, sha: String) -> UIImage? {
        let start = CACurrentMediaTime()
        UILatencyLog.mark("image decode begin", itemLogDetail("reason=\(reason) sha=\(shortSHA(sha)) bytes=\(data.count)"))
        let image = UIImage(data: data)
        UILatencyLog.mark(
            "image decode end",
            itemLogDetail("reason=\(reason) success=\(image != nil) elapsed_ms=\(UILatencyLog.elapsedMS(since: start))")
        )
        return image
    }

    private func itemLogDetail(_ extra: String = "") -> String {
        let sha = item.blobSha256.map(shortSHA) ?? "nil"
        let base = "id=\(String(item.id.prefix(8))) kind=\(item.kind.rawValue) sha=\(sha)"
        return extra.isEmpty ? base : "\(base) \(extra)"
    }

    private func shortSHA(_ sha: String) -> String {
        String(sha.prefix(8))
    }

    // MARK: - Time

    static func relativeLabel(_ date: Date, now: Date = Date()) -> String {
        let secs = Int(now.timeIntervalSince(date))
        if secs < 5 { return "刚刚" }
        if secs < 60 { return "\(secs) 秒前" }
        let mins = secs / 60
        if mins < 60 { return "\(mins) 分钟前" }
        let hours = mins / 60
        if hours < 24 { return "\(hours) 小时前" }
        let days = hours / 24
        if days < 7 { return "\(days) 天前" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

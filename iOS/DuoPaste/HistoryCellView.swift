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
            // pinned 右上角 45° pin 图标——padding(6, 6) 让 icon 中心贴在 cornerRadius=18
            // 的圆弧上。**不用** .offset 推出 cardSurface bounds:长按时 iOS contextMenu
            // snapshot 只截 view frame 内容,offset 外部分会被裁掉。
            // 仅 body 路径挂 overlay,**不**放进 cardSurface 自身:长按 contextMenu preview
            // 复用 cardSurface 就天然不带 pin 装饰
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 3) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .rotationEffect(.degrees(45))
                        .opacity(item.pinned ? 1 : 0)
                    if store.isPinPending(item.id) {
                        Text("等待同步")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
                .allowsHitTesting(false)
            }
            // pinned 切换走 smooth 动画——gradient 渐显/渐隐 ~250ms,不"硬切"
            .animation(.smooth(duration: 0.25), value: item.pinned)
            .contentShape(.rect(cornerRadius: 18))
            .onTapGesture { triggerCopy() }
            .contextMenu {
                contextMenuItems()
            } preview: {
                // 接 previewContent 让长按看完整文本(ScrollView 可滚 4000 字符),
                // 卡片本体保持 lineLimit(5) 等高布局。previewContent 内部显式
                // .frame(width: 300) 锁尺寸避免渲染包围盒偏移。pin overlay 已经在
                // body 层而非 cardSurface 上,previewContent 跟 cardSurface 一样
                // 天然不带 pin 装饰,长按预览始终干净
                previewContent
            }
            .sensoryFeedback(.success, trigger: copyPulse)
    }

    /// 卡片视觉本体——纯卡片 chrome + content,**不带** pin overlay。pin 装饰在 body 层
     /// 加,这样 contextMenu preview 复用 cardSurface 就天然干净不带 pin 边框
    private var cardSurface: some View {
        cardBody
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
            .task(id: prefetchTaskID) {
                // 图片类 cell 上视区时自动拉 blob——长按预览 / tap 复制时 cache 已热,
                // 不再出现"首次长按 loading 不出图"。fetch 内部去重(同 sha 共享 inflight),
                // BlobCache 64MB 软上限 + FIFO 防长列表全部图片字节累积爆内存。
                // 已 cancel 的 sha 进黑名单不重拉(用户主动点取消下载的语义)。
                //
                // **150ms 防抖**:LazyVGrid 快滚时 cell 频繁 appear/disappear,task 在 sleep
                // 期间被 cancel 不发 fetch,避免快滚一闪而过的 cell 都打 server。Sleep 完成后
                // cell 仍在视区才真起 fetch。Task.isCancelled 双重检查防 sleep 边界 race
                guard isThumbnailable, let sha = item.blobSha256 else { return }
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
                guard blobs.cached(sha) == nil, !blobs.isCancelled(sha) else {
                    // 字节已在内存,decode 缩略图(已 decode 直接 no-op)
                    blobs.requestThumbnail(sha: sha, maxPx: 320)
                    return
                }
                _ = try? await blobs.fetch(sha).value
                if Task.isCancelled { return }
                // 字节进了 loaded,kick decode 写 thumbnails dict;view body 自然看到
                blobs.requestThumbnail(sha: sha, maxPx: 320)
            }
    }

    /// `.task(id:)` 用——sha + item.id 让两个非 image item(sha 都是 "")也能正确区分,
    /// 不会"切到下一张非图片 item 时不重启 task"。空 sha 的 task 早 return 不真起 fetch
    private var prefetchTaskID: String {
        (item.blobSha256 ?? "") + "|" + item.id
    }

    private var cardBody: some View {
        // isThumbnailable 多处用——一次 evaluation 后传下去,避免 body 评估期间多次
        // 重复 lowercased / suffix 检查(LazyVGrid + TimelineView 10s tick 时累加)
        let imageCard = isThumbnailable
        return VStack(alignment: .leading, spacing: 6) {
            cardContent(imageCard: imageCard)
            Spacer(minLength: 0)
            metaRow
        }
    }

    /// 卡片内容区——文本卡走多行 Text,图片卡(image kind / file kind 带 image blob)
    /// 走缩略图。缩略图未命中 cache 时显示占位 SF symbol + spinner,blob 拉回后
    /// SwiftUI 自然 reflow 出图
    @ViewBuilder
    private func cardContent(imageCard: Bool) -> some View {
        if imageCard, let sha = item.blobSha256 {
            thumbnailContent(sha: sha)
        } else {
            Text(item.displayPreview)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(6, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 卡片缩略图——**只读** BlobCache.thumbnails dict,**不**在 body 评估时同步 decode。
    /// decode 已挪到 .task 里 detached 跑(BlobCache.requestThumbnail),完成后 setThumbnail
    /// 触发 Observation 让 view body 重评出图。
    /// frame 高 ≈ Text(6 行) ≈ 110pt,跟文本卡视觉对齐
    @ViewBuilder
    private func thumbnailContent(sha: String) -> some View {
        ZStack {
            Color.primary.opacity(0.04)
            if let img = blobs.thumbnail(sha) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.5))
                    if blobs.isLoading(sha) || blobs.cached(sha) != nil {
                        // loading=网络拉中,或字节已到但 decode 还没完成,都显 spinner
                        ProgressView().controlSize(.mini)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            inlineAppIcon
            TimelineView(.periodic(from: .now, by: 10)) { context in
                Text(Self.relativeLabel(item.capturedAt, now: context.date))
            }
            if let size = sizeLabel {
                Text("·")
                Text(size)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let sha = item.blobSha256, blobs.isLoading(sha) {
                Text("·")
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// metaRow 起始 inline app icon。命中 sourceApp 显 macOS app icon(16pt 圆角矩形),
    /// 否则 kind SF symbol 兜底。16pt 是 caption 字号 (~12pt) 的 1.3x,跟时间/大小文本
    /// 同一视觉层级,不抢卡片主文字的注意力
    @ViewBuilder
    private var inlineAppIcon: some View {
        if let bid = item.sourceApp, let img = appIcons.cached(bid) {
            Image(uiImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: item.kindIconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    /// 卡片底部尺寸标签。image/file 走 blob 字节，text/url/rtf/html 走原文字符数。
    /// blob 行 sourceApp icon 已在右上交代来源，左下空出位给尺寸是更有信息量的选择。
    private var sizeLabel: String? {
        if let bytes = item.blobSize, bytes > 0 {
            return bytes.formatted(.byteCount(style: .file))
        }
        let full = item.textFull ?? item.preview ?? ""
        if full.isEmpty { return nil }
        return "\(full.count) 字"
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
        // 置顶/取消置顶——乐观切 + POST /pin fan-out。已知 limitation:跨 origin pin 不
        // 回传 origin 设备(本机 fold "pinned OR 聚合"兜底搜索语义,见 server /pin doc)
        Button {
            triggerTogglePin()
        } label: {
            if item.pinned {
                Label("取消置顶", systemImage: "pin.slash")
            } else {
                Label("置顶", systemImage: "pin")
            }
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
        .id(previewIdentity)
        .onAppear {
            UILatencyLog.mark("context menu preview appear", itemLogDetail())
        }
        .onDisappear {
            UILatencyLog.mark("context menu preview disappear", itemLogDetail())
        }
        .task(id: previewIdentity) {
            // image kind + file kind 带 image blob 都触发——之前只看 .image kind
            // 让 .png 文件长按只走 text scroll 路径,跟卡片渲染口径不齐
            if isThumbnailable, let sha = item.blobSha256 {
                let hasCache = blobs.cached(sha) != nil
                let isCancelled = blobs.isCancelled(sha)
                DebugLog.shared.append("preview .task fire sha=\(shortSHA(sha)) hasCache=\(hasCache) cancelled=\(isCancelled)")
                if !hasCache && !isCancelled {
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
    }

    private var previewIdentity: String {
        PreviewIdentity.make(
            itemID: item.id,
            kindRawValue: item.kind.rawValue,
            blobSHA256: item.blobSha256
        )
    }

    @ViewBuilder
    private var previewBody: some View {
        if isThumbnailable,
           let sha = item.blobSha256,
           let data = blobs.cached(sha),
           let img = decodeImage(data, reason: "preview", sha: sha) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    DebugLog.shared.append("previewBody render=image sha=\(shortSHA(sha)) bytes=\(data.count)")
                }
        } else if isThumbnailable {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                if item.blobSha256 != nil {
                    ProgressView().controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                let sha = item.blobSha256.map(shortSHA) ?? "nil"
                let hasCache = item.blobSha256.flatMap(blobs.cached) != nil
                let isLoading = item.blobSha256.map(blobs.isLoading) ?? false
                let isCancelled = item.blobSha256.map(blobs.isCancelled) ?? false
                DebugLog.shared.append("previewBody render=placeholder sha=\(sha) hasCache=\(hasCache) loading=\(isLoading) cancelled=\(isCancelled) hasSpinner=\(item.blobSha256 != nil)")
            }
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

        if let sha = item.blobSha256, itemHasImageBlob {
            if let cached = blobs.cached(sha) {
                UILatencyLog.mark("copy image cache hit", itemLogDetail("bytes=\(cached.count)"))
                copyImageBytes(cached, sha: sha, reason: "copy cached")
                return
            }
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
        store.removeOptimistic(item: item)
        coordinator.deleteItemOnServer(id: item.id)
    }

    /// 置顶/取消置顶——乐观切 store.pinned + 重排,再 POST /pin fan-out
    /// (跟 triggerDelete 同心智:乐观立即响应,server 失败下次 /since 自然 reconcile)
    private func triggerTogglePin() {
        UILatencyLog.mark("pin action begin", itemLogDetail("pinned_before=\(item.pinned)"))
        guard let newPinned = store.togglePinOptimistic(id: item.id) else { return }
        coordinator.togglePinOnServer(id: item.id, pinned: newPinned)
    }

    private func triggerShare() {
        UILatencyLog.mark("share action begin", itemLogDetail())
        if let sha = item.blobSha256, itemHasImageBlob {
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

    /// 该 item 是否应该在卡片里渲染图片缩略图——
    /// - kind=.image:必有 blob,无脑 yes
    /// - kind=.file + blob_mime=image/*:Mac 把 .png 文件读字节当 image 副本上传(同步路径)
    /// - kind=.file + path 后缀像图片:fileLooksLikeImage 判,且必须 blob 存在(iOS 拿不到 Mac 本机文件)
    private var itemHasImageBlob: Bool {
        guard item.blobSha256 != nil else { return false }
        if item.kind == .image { return true }
        if item.kind == .file, let mime = item.blobMime, mime.hasPrefix("image/") { return true }
        return false
    }

    private var isThumbnailable: Bool {
        guard let _ = item.blobSha256 else { return false }
        if item.kind == .image { return true }
        if item.kind == .file {
            if let mime = item.blobMime, mime.hasPrefix("image/") { return true }
            if let p = item.textFull, fileLooksLikeImage(path: p) { return true }
        }
        return false
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

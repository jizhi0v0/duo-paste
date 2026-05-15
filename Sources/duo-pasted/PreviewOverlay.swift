import AppKit
import SwiftUI
import PDFKit
import AVFoundation
import AVKit
import DuoPasteCore

/// 空格预览的独立浮窗。
///
/// 设计动机:第一版用 SwiftUI .overlay 叠在搜索 panel 里——panel 只有 312pt 高,
/// 容不下 iOS 截图(2.17 比例的竖屏)。撤掉 in-panel overlay 换独立 NSPanel:
/// - 飘在搜索 panel 上方,可以撑到屏高 70%
/// - image 按原生像素 aspect-fit,iOS 截图终于能完整看清
/// - nonactivating + canBecomeKey=false → 键盘焦点永远留在搜索 panel,空格/箭头/Esc
///   照常被 SearchPanelController 的 NSEvent monitor 截到
/// - 撤掉 SwiftUI .animation(.easeOut) 也顺便修了 user 反馈的"背景闪烁一下"
///   ——之前 in-panel overlay 触发 .ultraThickMaterial 整层 re-render,新方案 panel
///   是独立窗口跟搜索 panel 完全解耦
///
/// 定位:SearchView 通过 SelectedCardFramePreference 把 currentItem 卡的 .global frame
/// 上报到 AppState.selectedCardWindowRect;controller 把这个 frame 从 SwiftUI 坐标
/// (top-left)换算到屏幕坐标(bottom-left),浮窗水平居中于卡片,垂直贴在搜索 panel
/// 上方 12pt
@MainActor
final class PreviewPanelController {
    private let state: AppState
    private let blobs: BlobStore
    private weak var anchorPanel: NSPanel?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<PreviewPanelContent>?
    /// item.id → 解码完的 PreviewMedia 缓存,命中即刻同步 apply 不阻塞主线程。
    /// 不限容量——剪贴板典型几千条 item 但同一次会话用户只会预览少数;PDF/NSImage 各
    /// 几 MB,千条以内可接受。panel hide 不清(用户秒级 reopen 同 item 是常见场景)
    private var mediaCache: [String: PreviewMedia] = [:]
    /// 当前正在为哪个 item 跑后台解码 Task——切换 item 时 cancel + 检查 currentItemID
    /// 防止乱序覆盖(快速按箭头时多个 task 并发,只有最新那个 apply 生效)
    private var loadTask: Task<Void, Never>?
    private var currentItemID: String?

    init(state: AppState, blobs: BlobStore) {
        self.state = state
        self.blobs = blobs
    }

    /// 由 SearchPanelController 在搜索 panel 创建后调用,提供屏幕坐标换算的锚点。
    /// 不在 init 里传是因为 search panel 是 lazy 创建的(ensurePanel)
    func setAnchor(_ panel: NSPanel) {
        self.anchorPanel = panel
    }

    /// 显示/更新预览。`cardRectInGlobal` 是 SwiftUI 卡片在 .global(top-left)坐标空间的
    /// frame——caller 通过 PreferenceKey 拿到。
    ///
    /// 三条路径:
    /// 1) 缓存命中(item.id 已 decode 过)→ 同步 apply 即刻显示,0 卡顿
    /// 2) 不需要异步(text/url/file 非 image 非 pdf)→ 同步 .none + 缓存进表
    /// 3) image/pdf 缓存 miss → 先 apply .loading 占位让 panel 立刻可见,Task.detached
    ///    后台 decode (PDFDocument/NSImage 都在主线程上几十~几百 ms,放后台)。done 后回
    ///    main 检查仍是当前 item 才真正 apply
    ///
    /// 快速箭头切换场景:每次 show 取消上一个 task,但**仍把 decode 结果写进 cache**
    /// (即使用户已切走也帮下次预览预热),只是 apply UI 时 guard currentItemID
    func show(item: Item, cardRectInGlobal: CGRect) {
        guard let anchor = anchorPanel else { return }
        guard let screen = anchor.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame

        let isItemChange = (currentItemID != item.id)
        currentItemID = item.id
        if isItemChange { loadTask?.cancel() }

        // 1) 缓存命中 → 同步 apply
        if let cached = mediaCache[item.id] {
            apply(item: item, media: cached,
                  visibleFrame: visibleFrame, anchor: anchor,
                  cardRectInGlobal: cardRectInGlobal)
            return
        }
        // 2) 不需要异步解码 → 同步 .none + 缓存(下次同 item reposition 不重判)
        if !needsAsyncDecode(item) {
            // 注意:必须显式写 PreviewMedia.none,否则 Swift 推断成 Optional.none =
            // 删 key,缓存就失效了(这是 dict subscript 重载坑)
            mediaCache[item.id] = PreviewMedia.none
            apply(item: item, media: .none,
                  visibleFrame: visibleFrame, anchor: anchor,
                  cardRectInGlobal: cardRectInGlobal)
            return
        }
        // 3) image/pdf 异步:先 apply .loading 占位(panel 立刻可见显示 spinner),
        //    后台 decode 完成后再用真实 media 重 apply(panel 尺寸自然 resize 到原比例)
        apply(item: item, media: .loading,
              visibleFrame: visibleFrame, anchor: anchor,
              cardRectInGlobal: cardRectInGlobal)

        let targetID = item.id
        let capturedItem = item
        let capturedBlobs = blobs
        loadTask = Task { [weak self] in
            let decoded = await Self.decodeMedia(item: capturedItem, blobs: capturedBlobs)
            guard let self else { return }
            self.mediaCache[targetID] = decoded
            guard self.currentItemID == targetID,
                  self.state.previewShown,
                  self.state.selectedCardWindowRect != .zero,
                  let anchor = self.anchorPanel,
                  let screen = anchor.screen ?? NSScreen.main else { return }
            self.apply(item: capturedItem, media: decoded,
                       visibleFrame: screen.visibleFrame, anchor: anchor,
                       cardRectInGlobal: self.state.selectedCardWindowRect)
        }
    }

    func hide() {
        loadTask?.cancel()
        currentItemID = nil
        panel?.alphaValue = 0
        panel?.ignoresMouseEvents = true
    }

    private func needsAsyncDecode(_ item: Item) -> Bool {
        isImageLike(item) || isPDFLike(item) || Self.isVideoLikeStatic(item)
    }

    /// 把"算尺寸 + 写 SwiftUI rootView + 移动/显示 panel"封装一起。同步路径(缓存命中)
    /// 跟异步路径(.loading 占位 / decode 完回更新)都走这里,避免位置算法重复
    private func apply(item: Item, media: PreviewMedia,
                       visibleFrame: NSRect, anchor: NSPanel,
                       cardRectInGlobal: CGRect) {
        let contentSize = sizeFor(media: media, screenFrame: visibleFrame, anchor: anchor)
        let p = ensurePanel()
        // 先 update SwiftUI 内容再 resize panel——顺序反了 SwiftUI 用旧 size 一帧再换会抖
        hostingView?.rootView = PreviewPanelContent(item: item, media: media, blobs: blobs)
        if p.frame.size != contentSize {
            p.setContentSize(contentSize)
        }

        let cardScreenRect = convertGlobalToScreen(cardRectInGlobal, panel: anchor)
        var x = cardScreenRect.midX - contentSize.width / 2
        x = max(visibleFrame.minX + 20,
                min(visibleFrame.maxX - contentSize.width - 20, x))
        var y = anchor.frame.maxY + 12
        if y + contentSize.height > visibleFrame.maxY - 20 {
            y = visibleFrame.maxY - 20 - contentSize.height
        }
        p.setFrameOrigin(NSPoint(x: x, y: y))
        // alpha 切换可见性(替代 orderOut/orderFront 的 fade-in 动画带来的"黑一下")
        p.alphaValue = 1
        p.ignoresMouseEvents = false
        if !p.isVisible { p.orderFront(nil) }
    }

    /// SwiftUI .global (top-left, NSHostingView isFlipped=true 时) → 屏幕(bottom-left)。
    /// - panel.frame.minX 是 panel 在屏幕的左边
    /// - panel.frame.maxY 是 panel 在屏幕的上边(AppKit Y 向上)
    /// - SwiftUI rect.maxY 是卡片底沿到 hosting view 顶部的距离
    /// 所以卡片屏幕底沿 = panel.frame.maxY - rect.maxY
    private func convertGlobalToScreen(_ rect: CGRect, panel: NSWindow) -> NSRect {
        NSRect(
            x: panel.frame.minX + rect.minX,
            y: panel.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 按预解码完的 media 算 panel 内容尺寸。不再做任何 IO/解码,纯几何计算,放主线程安全。
    /// .loading / .none → 默认 720×420(loading 时用这个尺寸先撑住 panel,真正 media 到了再 resize)
    private func sizeFor(media: PreviewMedia, screenFrame: NSRect, anchor: NSPanel) -> NSSize {
        let maxW = screenFrame.width * 0.55
        let availableAbove = (screenFrame.maxY - 20) - (anchor.frame.maxY + 12)
        let maxH = min(screenFrame.height * 0.7, max(380, availableAbove))
        let chromeH: CGFloat = 36 + 28

        switch media {
        case .image(let img):
            let pixelW: CGFloat
            let pixelH: CGFloat
            if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                pixelW = CGFloat(rep.pixelsWide); pixelH = CGFloat(rep.pixelsHigh)
            } else if img.size.width > 0, img.size.height > 0 {
                pixelW = img.size.width; pixelH = img.size.height
            } else {
                return NSSize(width: 720, height: 420)
            }
            let contentMaxH = maxH - chromeH
            let scale = min(maxW / pixelW, contentMaxH / pixelH, 1.0)
            return NSSize(width: max(380, pixelW * scale), height: pixelH * scale + chromeH)
        case .pdf(let doc):
            if let page = doc.page(at: 0) {
                let bounds = page.bounds(for: .mediaBox)
                let pdfW = max(bounds.width, 1); let pdfH = max(bounds.height, 1)
                let contentMaxH = maxH - chromeH
                let scale = min(maxW / pdfW, contentMaxH / pdfH)
                return NSSize(width: max(380, pdfW * scale), height: pdfH * scale + chromeH)
            }
            return NSSize(width: 720, height: 420)
        case .video(_, let size):
            let pixelW = max(size.width, 1); let pixelH = max(size.height, 1)
            let contentMaxH = maxH - chromeH
            let scale = min(maxW / pixelW, contentMaxH / pixelH, 1.0)
            return NSSize(width: max(380, pixelW * scale), height: pixelH * scale + chromeH)
        case .none, .loading:
            return NSSize(width: 720, height: 420)
        }
    }

    /// 后台解码入口。`Item` + `BlobStore` 都是 Sendable,跨 actor 边界安全;返回值
    /// `PreviewMedia` 用 `@unchecked Sendable` 标记(NSImage/PDFDocument 单写多读,这里
    /// 只在 detached task 里构造一次就交出,后续 main actor 上只读不变)。
    /// 优先级 `.userInitiated` 让用户能感知到这是交互响应路径而非后台 batch
    nonisolated private static func decodeMedia(item: Item, blobs: BlobStore) async -> PreviewMedia {
        let detached: Task<PreviewMedia, Never> = Task.detached(priority: .userInitiated) {
            if Self.isImageLikeStatic(item), let sha = item.blobSha256,
               let data = try? blobs.read(sha256: sha) ?? nil,
               let img = NSImage(data: data) {
                return .image(img)
            }
            if Self.isPDFLikeStatic(item),
               let raw = item.textFull,
               let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first {
                let path = String(first)
                if FileManager.default.fileExists(atPath: path),
                   let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
                    // 后台触一下首页 mediaBox 让 PDFKit lazy-parse 首页结构,
                    // 主线程上 PDFView setDocument 时不会再卡
                    _ = doc.page(at: 0)?.bounds(for: .mediaBox)
                    return .pdf(doc)
                }
            }
            if Self.isVideoLikeStatic(item) {
                // 视频源 URL:优先 BlobStore(blob 备份的小视频),退化本机文件路径
                let url: URL? = {
                    if let sha = item.blobSha256, let u = blobs.locate(sha256: sha) { return u }
                    if let raw = item.textFull,
                       let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first {
                        let path = String(first)
                        if FileManager.default.fileExists(atPath: path) {
                            return URL(fileURLWithPath: path)
                        }
                    }
                    return nil
                }()
                if let url {
                    let asset = AVURLAsset(url: url)
                    do {
                        let tracks = try await asset.loadTracks(withMediaType: .video)
                        if let track = tracks.first {
                            let natural = try await track.load(.naturalSize)
                            let transform = try await track.load(.preferredTransform)
                            let displayed = natural.applying(transform)
                            let size = CGSize(width: abs(displayed.width), height: abs(displayed.height))
                            return .video(url, size)
                        }
                    } catch {
                        // decode 失败 fallthrough .none → 显示通用 file body
                    }
                }
            }
            return .none
        }
        return await detached.value
    }

    /// 给同步路径用的 @MainActor wrapper——直接 forward 到 nonisolated static 实现,
    /// 主线程上判别不需要 actor 隔离,共用 static 避免逻辑分两份漂移
    private func isImageLike(_ item: Item) -> Bool { Self.isImageLikeStatic(item) }
    private func isPDFLike(_ item: Item) -> Bool { Self.isPDFLikeStatic(item) }

    /// nonisolated static 版本——给 Task.detached 后台解码用,不能依赖 MainActor 隔离的 self
    nonisolated static func isImageLikeStatic(_ item: Item) -> Bool {
        guard item.blobSha256 != nil else { return false }
        if item.kind == .image { return true }
        if item.kind == .file {
            if let mime = item.blobMime, mime.hasPrefix("image/") { return true }
            if let p = item.textFull, fileLooksLikeImage(path: p) { return true }
        }
        return false
    }

    /// PDF 判别——不走 blob(单文件 PDF capture 不存 blob),凭 textFull 路径后缀 / 兜底 mime
    nonisolated static func isPDFLikeStatic(_ item: Item) -> Bool {
        guard item.kind == .file else { return false }
        if let mime = item.blobMime, mime == "application/pdf" { return true }
        guard let raw = item.textFull,
              let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return false
        }
        return String(first).lowercased().hasSuffix(".pdf")
    }

    /// 视频判别——AVFoundation 能解码的格式(mp4/m4v/mov),跟 ImageThumbnailCache.isVideoLike
    /// 同口径但接受 multi-line(虽然 fileLooksLikeVideo 自己拒)
    nonisolated static func isVideoLikeStatic(_ item: Item) -> Bool {
        if let mime = item.blobMime, mime.hasPrefix("video/") { return true }
        guard item.kind == .file, let raw = item.textFull,
              let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return false
        }
        return fileLooksLikeVideo(path: String(first))
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let initial = NSRect(x: 0, y: 0, width: 720, height: 420)
        let p = NonKeyHUDPanel(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // 砍掉 NSPanel 默认 fade-in/out 动画——它在 orderFront 时让窗口从透明渐变到不透明,
        // 视觉上就是用户反馈的"每次点击预览都黑一下"。配合 alpha 切换可见性,实现即时显示
        p.animationBehavior = .none

        let host = NSHostingView(
            rootView: PreviewPanelContent(item: nil, media: .none, blobs: blobs)
        )
        host.frame = initial
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        p.contentView = host
        p.invalidateShadow()
        self.hostingView = host
        self.panel = p
        return p
    }
}

/// 永不接受 key/main 状态的 HUDPanel——orderFront 后搜索 panel 保留 key,
/// 键盘事件全部走 SearchPanelController 的 NSEvent local monitor
@MainActor
final class NonKeyHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI 内容

/// 预览媒体载体——按 kind 携带不同的原始数据。image 走 NSImage,pdf 走 PDFDocument,
/// 其他(text/url/file 非 image 非 pdf)走 .none 让 contentBody 路由到对应子视图,
/// .loading 是异步 decode 期间的占位(panel 已可见但内容是 spinner)。
///
/// @unchecked Sendable:NSImage / PDFDocument 都是 NSObject 子类,文档保证只要不
/// 并发改同一实例就能跨线程读。这里语义是 decode 一次性构造 → 跨边界 → main actor
/// 上只读不变,符合契约
enum PreviewMedia: @unchecked Sendable {
    case none
    case loading
    case image(NSImage)
    case pdf(PDFDocument)
    /// 视频:URL 给 AVPlayer 播放,displaySize 是已应用 preferredTransform 的展示尺寸,
    /// sizeFor 用它算 panel 比例(竖拍视频要 H>W,naturalSize 不带 transform 会反)
    case video(URL, CGSize)
}

/// 浮窗内容视图。圆角卡片自身是 panel 全幅;header(36) + body(剩余) + footer(28)
@MainActor
struct PreviewPanelContent: View {
    let item: Item?
    let media: PreviewMedia
    let blobs: BlobStore

    var body: some View {
        ZStack {
            // macOS 26+ Liquid Glass;老系统 ultraThickMaterial 兜底
            glassBackground
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)

            if let item {
                VStack(spacing: 0) {
                    metaHeader(item: item)
                    Divider().opacity(0.4)
                    contentBody(item: item)
                        // .id(kindKey) 强制 SwiftUI 在 kind 切换时整体 swap 子树。
                        // 注意:之前尝试用 NSViewRepresentable + Coordinator 把所有 kind 的 NSView
                        // 全 lazy 挂着只 toggle isHidden,本意是切回同一 PDF 不重渲首页,但 NSImageView/
                        // PDFView 的 intrinsicContentSize 会通过 NSHostingView.updateAnimatedWindowSize
                        // (macOS 14+ 私有路径)推回 NSWindow auto-grow panel,从 497x706 涨到 1440x906。
                        // 试过 contentMinSize/MaxSize + sizingOptions=[] + didResize observer revert
                        // 全部无效(observer revert 还跟 windowDidLayout 死循环崩 NSException)。
                        // 回退到 SwiftUI 子树 + .id() clean swap:PDF 切回时 PDFView 重建会有"封面闪一下"
                        // 但 panel 尺寸守得住,综合体感胜出
                        .id(kindKey)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().opacity(0.4)
                    hintBar
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 浮窗玻璃背景。macOS 26+ Liquid Glass;老系统 ultraThickMaterial 兜底。
    /// glassEffect(in:) 自带 shape + clip,不需要再 fill;旧路径手动 fill 同 shape
    @ViewBuilder
    private var glassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThickMaterial)
        }
    }

    private func metaHeader(item: Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kindSymbol(item.kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(kindLabel(item.kind))
                .font(.system(size: 12, weight: .medium))
            if let sub = subtitle(item: item) {
                Text("·").foregroundStyle(.secondary)
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    /// 当前 media 对应的稳定身份 key——给 contentBody .id() 用,kind 切换强制干净 swap。
    /// video 把 URL 编进 key,确保切到不同视频时 SwiftUI 整体重建 VideoPreviewBody
    /// (否则 same .id 复用,@State player 不会重置 → 还在播旧视频)
    private var kindKey: String {
        switch media {
        case .none:
            if let item = item {
                if item.kind == .file { return "file-icon" }
                return "text"
            }
            return "none"
        case .loading: return "loading"
        case .image: return "image"
        case .pdf: return "pdf"
        case .video(let url, _): return "video:" + url.absoluteString
        }
    }

    @ViewBuilder
    private func contentBody(item: Item) -> some View {
        switch media {
        case .loading:
            ZStack {
                Color.primary.opacity(0.03)
                ProgressView().controlSize(.large)
            }
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.04))
        case .pdf(let doc):
            PDFPreviewBody(document: doc)
        case .video(let url, _):
            VideoPreviewBody(url: url)
        case .none:
            if isImageLike(item) {
                ZStack {
                    Color.primary.opacity(0.03)
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("图片预览失败").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else if item.kind == .file {
                FilePreviewBody(item: item)
            } else {
                TextPreviewBody(text: item.textFull ?? item.preview ?? "")
            }
        }
    }

    private func isImageLike(_ item: Item) -> Bool {
        guard item.blobSha256 != nil else { return false }
        if item.kind == .image { return true }
        if item.kind == .file {
            if let mime = item.blobMime, mime.hasPrefix("image/") { return true }
            if let p = item.textFull, fileLooksLikeImage(path: p) { return true }
        }
        return false
    }

    private var hintBar: some View {
        HStack(spacing: 12) {
            hintCell(label: "粘贴", key: "↩")
            hintCell(label: "关闭", key: "Space")
            hintCell(label: "切换", key: "← →")
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.primary.opacity(0.04))
    }

    private func hintCell(label: String, key: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func kindLabel(_ k: ItemKind) -> String {
        switch k {
        case .text: "文本"
        case .rtf: "富文本"
        case .html: "HTML"
        case .url: "链接"
        case .image: "图片"
        case .file: "文件"
        }
    }

    private func kindSymbol(_ k: ItemKind) -> String {
        switch k {
        case .text: "text.alignleft"
        case .rtf: "doc.richtext"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }

    private func subtitle(item: Item) -> String? {
        if case .pdf(let doc) = media {
            let count = doc.pageCount
            return count > 0 ? "\(count) 页" : nil
        }
        if let size = item.blobSize, size > 0 {
            return humanSize(size)
        }
        if item.kind == .url, let s = item.textFull,
           let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return u.host ?? s
        }
        if item.kind == .text || item.kind == .rtf || item.kind == .html {
            let text = item.textFull ?? item.preview ?? ""
            return "\(text.count) 字符"
        }
        return nil
    }

    private func humanSize(_ size: Int64) -> String {
        let kb = Double(size) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - SwiftUI 内容子树

/// 文本预览。NSTextView 走 NSLayoutManager 自带的 lazy line layout,百 KB 文本即时挂载,
/// 避免 SwiftUI `Text(string)` 没有 lazy 导致单次卡 200ms+
@MainActor
private struct TextPreviewBody: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        if let tv = scrollView.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.backgroundColor = .clear
            tv.textContainerInset = NSSize(width: 16, height: 14)
            tv.font = .systemFont(ofSize: 13)
            tv.string = text.isEmpty ? "（无内容）" : text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        let target = text.isEmpty ? "（无内容）" : text
        if tv.string != target {
            tv.string = target
            tv.scroll(NSPoint(x: 0, y: 0))
        }
    }
}

/// PDF 预览。NSViewRepresentable 包 PDFKit.PDFView——原生连续滚动 + autoScales 首页适配。
/// `.id(kindKey)` 在 PreviewPanelContent 切 kind 时会让这个 SwiftUI 视图整个 tear down 重建,
/// 切回同 PDF 时会重新 makeNSView + setDocument 触发首页重渲(肉眼"闪一下")。
/// 取舍:这点闪 vs panel 失控涨大,后者更糟,所以接受重建
@MainActor
private struct PDFPreviewBody: View {
    let document: PDFDocument
    var body: some View {
        PDFKitView(document: document)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.04))
    }
}

@MainActor
private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = document
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .clear
        v.acceptsDraggedFiles = false
        v.goToFirstPage(nil)
        return v
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
            nsView.goToFirstPage(nil)
        }
    }
}

@MainActor
/// 视频预览——AVPlayerView 走原生控件(play/pause/scrubber/音量/全屏)。
///
/// **历史**:第一版用 SwiftUI `VideoPlayer`,它内部 Swift class `VideoPlayerView` 继承
/// ObjC `AVPlayerView`,macOS 26.5 上 Swift runtime 初始化该 class metadata 时
/// `getSuperclassMetadata` demangle 失败 → SIGABRT。`failed to demangle superclass
/// of VideoPlayerView from mangled name 'So12AVPlayerViewC'`
///
/// **现版本**:直接 `NSViewRepresentable` 挂 AVPlayerView(纯 ObjC 类,Swift runtime
/// 不需要初始化它的 Swift class metadata,绕开 demangle 路径)。controlsStyle=.inline
/// 走底部贴边的 scrubber + 播放控件。autoplay 静音,user 想出声手动点音量
private struct VideoPreviewBody: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = false
        view.videoGravity = .resizeAspect
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true                                // 预览静音,不在用户搜索时突然出声
        player.automaticallyWaitsToMinimizeStalling = false  // 本地文件不要等 buffer
        view.player = player
        context.coordinator.player = player
        player.play()
        context.coordinator.statusObservation = item.observe(
            \.status, options: [.new]
        ) { item, _ in
            if item.status == .readyToPlay {
                Task { @MainActor in player.play() }
            }
        }
        context.coordinator.loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // no-op;parent .id(kindKey) 带 URL,切到不同视频走 makeNSView 重建
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.statusObservation?.invalidate()
        coordinator.statusObservation = nil
        if let obs = coordinator.loopObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        nsView.player = nil
    }

    final class Coordinator {
        var player: AVPlayer?
        var loopObserver: NSObjectProtocol?
        var statusObservation: NSKeyValueObservation?
    }
}

private struct FilePreviewBody: View {
    let item: Item
    var body: some View {
        let raw = item.textFull ?? item.preview ?? ""
        let paths = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return HStack(alignment: .center, spacing: 18) {
            Image(systemName: "doc.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: 96)
            VStack(alignment: .leading, spacing: 8) {
                if let first = paths.first {
                    Text(URL(fileURLWithPath: first).lastPathComponent)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(first)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if paths.count > 1 {
                    Text("及另外 \(paths.count - 1) 个文件")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}


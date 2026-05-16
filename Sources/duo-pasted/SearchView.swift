import SwiftUI
import AppKit
import AVFoundation
import DuoPasteCore
import DuoPasteSync

@MainActor private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    // .named → 极近时间显示 "now"，避免 RelativeDateTimeFormatter 默认的 "in 0 sec." 反向前缀
    f.dateTimeStyle = .named
    return f
}()

/// 按 sha256 → 缩略图的进程内 LRU-less 缓存。ItemCard 主区 200×188 显示原图 aspectFit。
///
/// content-addressed 缓存:同一 sha 的字节内容固定 → 缩略图也固定,缓存命中率高。
/// **maxPx=400** ≈ 卡片宽 200 × 2x retina,够清晰;原 Spotlight 列表 32pt row 用 64 太低,
/// 改卡片布局后调高让缩略图不糊。1000 image 缓存 ~10-30MB 内存,可接受
///
/// 加载策略:
/// - `cached(for:)` 同步查 dict,命中直接返回(SwiftUI body 内可直接调,不卡)
/// - `thumbnail(for:blobs:)` async,miss 时 Task.detached 跑 background CPU decode
/// - decode 失败的 key 进 `notDecodable` 黑名单,LazyHStack 重渲不再反复重试
///
/// **cache key**:blob-backed 项用 `sha:<sha256>`;file kind 走 Finder 复制(无 blob,只
/// 有路径)的视频/图片用 `path:<本机绝对路径>`——后者跨设备 mirror 在对端文件不存在
/// 时 decode fail 一次后进黑名单,UI fallback SF Symbol
@MainActor
final class ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    private var cache: [String: NSImage] = [:]
    private var notDecodable: Set<String> = []
    private static let maxPx: Int = 400

    /// thumbnail decode 专用执行队列。**核心目的**：限流 + 跟其它进程内工作隔离 thread budget。
    ///
    /// 历史 bug（2026-05-15 v9 OCR backfill 卡死）：原实现 `prefetch` for-loop fire 100+ 张
    /// `Task { thumbnail() }`，每个 thumbnail 内部又 `Task.detached(priority: .userInitiated)`，
    /// 协作池被 .userInitiated 持续占满 → 同进程内 VisionOCRRecognizer 的 `.utility`
    /// `DispatchQueue.global` 永久饥饿,`handler.perform` 永不返。详 plans 里 OCR 卡死分析。
    ///
    /// 修法（Nuke / Kingfisher 同款）：专用 `OperationQueue` 限并发 + qos=.utility。
    /// - `maxConcurrentOperationCount=4`：每张 decode 100-300ms（4K JPG），4 并发刚好
    ///   填满后台 CPU 不挤压;数字大了对单图延迟没帮助,反而吃光 thread。
    /// - `qos=.utility`：thumbnail prefetch 是"提前准备 UI 资源"，比 OCR（用户感知索引）
    ///   优先级低一档。两者各自有 budget,不再互相抢
    private static let decodeQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "io.duopaste.thumbnail.decode"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    /// blob-backed 优先用 sha;file kind 无 blob 时退化到路径(本机文件 URL 解析)
    nonisolated static func cacheKey(for item: Item) -> String? {
        if let sha = item.blobSha256 { return "sha:" + sha }
        if let p = item.textFull, !p.isEmpty, !p.contains("\n") {
            return "path:" + p
        }
        return nil
    }

    func cached(for item: Item) -> NSImage? {
        guard let key = Self.cacheKey(for: item) else { return nil }
        return cache[key]
    }

    /// 清空所有缓存 + decode 黑名单。
    ///
    /// 用途：mesh-fetch-missing / 「补齐缺失 blob」按钮拉回字节后，原本进了 notDecodable
    /// 黑名单的 sha（首次卡片出现时本机没字节，decode 失败）现在能正常 decode 了。
    /// 调一次让所有卡片下次 .task fire 时重新走 decode 路径。
    /// 配合 AppState.blobInventoryPulse bump 触发 .task 重 fire（光清缓存不够——卡片
    /// .task(id: cacheKey) 因为 sha 不变不会自动 re-fire）
    func invalidateAll() {
        cache.removeAll()
        notDecodable.removeAll()
    }

    /// PR cloudy-mirroring-walnut PR 3：加 `fetcher` + `storageMode` 参数让 optimized 模式
    /// 在本机缺 blob 时按需 GET /blob/<sha> 拉回。`.full` 模式 + 缺 blob 直接 return nil
    /// （理论上 PullWorker eager 路径已拉，缺失说明 catch-up 没跑过——`mesh-fetch-missing`
    /// CLI 补一次即可）。fetcher=nil 时退化跟老行为一致（没 peer / shared-secret 失败）
    func thumbnail(
        for item: Item,
        blobs: BlobStore,
        fetcher: (any BlobFetcher)? = nil,
        storageMode: StorageMode = .full
    ) async -> NSImage? {
        guard let key = Self.cacheKey(for: item) else { return nil }
        if let img = cache[key] { return img }
        if notDecodable.contains(key) { return nil }
        let isVideo = Self.isVideoLike(item)
        let sha = item.blobSha256
        let pathStr = item.textFull
        let maxPx = Self.maxPx

        // optimized 模式 + 缺 blob → 先 lazy fetch + putVerified 进 BlobStore，再走下面的
        // decode 路径（BlobStore.read 这下能命中）。fetch 失败 fallthrough decode（路径
        // fallback 仍可能命中本机文件 URL）。注意：跟 paste 路径不同——这里不显示 spinner，
        // 缩略图不到位 UI 就是占位图，缺图不阻塞用户操作
        if storageMode == .optimized,
           let sha,
           let fetcher,
           (try? blobs.read(sha256: sha) ?? nil) == nil,
           !blobs.exists(sha256: sha)
        {
            do {
                let outcome = try await fetcher.getBlob(sha256: sha)
                if case .found(let data) = outcome {
                    _ = try? blobs.putVerified(data, expectedSha256: sha)
                }
            } catch {
                // transient / rejected / shaMismatch 都吞掉走下面 fallback——
                // 用户看到的是占位图，不影响其他卡片
            }
        }

        // 提交到专用 OperationQueue 隔离 thread budget(详 `decodeQueue` 注释)。
        // Task.detached 旧实现走 cooperative pool .userInitiated 会把 OCR 饿死
        let img: NSImage? = await withCheckedContinuation { cont in
            Self.decodeQueue.addOperation {
                // 选源 URL:优先 BlobStore(content-addressed 稳),没 blob 退化到本机文件路径
                let sourceURL: URL? = {
                    if let sha, let blobURL = blobs.locate(sha256: sha) { return blobURL }
                    if let pathStr, !pathStr.isEmpty {
                        let u = URL(fileURLWithPath: pathStr)
                        if FileManager.default.fileExists(atPath: u.path) { return u }
                    }
                    return nil
                }()
                if isVideo {
                    guard let sourceURL else { cont.resume(returning: nil); return }
                    cont.resume(returning: Self.decodeVideoThumbnail(url: sourceURL, maxPx: maxPx))
                    return
                }
                // image 路径:优先 BlobStore.read(零拷贝走 Data),没 blob 时直读文件 URL
                if let sha, let data = try? blobs.read(sha256: sha) ?? nil {
                    cont.resume(returning: Self.decodeImageThumbnail(data: data, maxPx: maxPx))
                    return
                }
                if let sourceURL, let data = try? Data(contentsOf: sourceURL) {
                    cont.resume(returning: Self.decodeImageThumbnail(data: data, maxPx: maxPx))
                    return
                }
                cont.resume(returning: nil)
            }
        }
        if let img {
            cache[key] = img
        } else {
            notDecodable.insert(key)
        }
        return img
    }

    /// 后台预热——AppState.init / refresh 后调,把 results 里 thumbnailable 项(image +
    /// video)的 thumbnail 提前 decode 进 cache。每张卡 .task 命中 cached(sha:) 直接拿,
    /// 不闪 placeholder。已 cached / 黑名单的 sha 跳过,重复 prefetch 廉价。
    ///
    /// **关键**:实际 decode 工作进 `decodeQueue`(max=4 并发)而**不是**裸 `Task`。N=100+
    /// 张时旧实现 fire 100 个并发 Task 抢协作池 → OCR 饿死(2026-05-15 bug)。本函数只是
    /// 入队 + 解 continuation,for-loop body 是廉价 `addOperation` 调用,N 张大循环也无害
    ///
    /// **storage_mode=.optimized 跳过缺 blob 的预热**：用户没主动看就别 GET，避免后台流量
    /// 把对端打满。用户真切到那张卡 .task 会主动 fetch（thumbnail 函数走 lazy 路径）
    func prefetch(
        items: [Item],
        blobs: BlobStore,
        fetcher: (any BlobFetcher)? = nil,
        storageMode: StorageMode = .full
    ) {
        for item in items {
            guard let key = Self.cacheKey(for: item),
                  cache[key] == nil,
                  !notDecodable.contains(key),
                  Self.isThumbnailable(item) else { continue }
            // optimized 模式 + 缺本机 blob → 跳过预热（避免后台拉一堆字节，等用户真看再拉）
            if storageMode == .optimized,
               let sha = item.blobSha256,
               !blobs.exists(sha256: sha) {
                continue
            }
            Task { [weak self] in
                _ = await self?.thumbnail(for: item, blobs: blobs, fetcher: fetcher, storageMode: storageMode)
            }
        }
    }

    /// 静图判别:image kind 必须有 blob;file kind 走 mime / 路径后缀(可能无 blob)
    nonisolated static func isImageLike(_ item: Item) -> Bool {
        if item.kind == .image { return item.blobSha256 != nil }
        if item.kind == .file {
            if let mime = item.blobMime, mime.hasPrefix("image/") { return true }
            if let p = item.textFull, fileLooksLikeImage(path: p) { return true }
        }
        return false
    }

    /// 视频判别——AVFoundation 能解码的 mp4/m4v/mov。file kind Finder 复制无 blob,
    /// thumbnail() 解析时退化到本机文件 URL,所以这里不能 require blob 存在
    nonisolated static func isVideoLike(_ item: Item) -> Bool {
        if let mime = item.blobMime, mime.hasPrefix("video/") { return true }
        if item.kind == .file, let p = item.textFull, fileLooksLikeVideo(path: p) { return true }
        return false
    }

    /// 卡片缩略图能渲染的所有类型——image + video。kind=.file 的视频/图片走文件路径
    /// 后缀启发,kind=.image 直走 image
    nonisolated static func isThumbnailable(_ item: Item) -> Bool {
        isImageLike(item) || isVideoLike(item)
    }

    /// `nonisolated` 让 Task.detached 闭包能直接调——本函数纯 CG 调用 + 局部变量,无
    /// MainActor 状态访问,跑 background CPU 安全
    nonisolated private static func decodeImageThumbnail(data: Data, maxPx: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        // point size = pixel / 2(2x retina) 让 SwiftUI 用 point 摆放跟 32pt frame 对齐
        let size = NSSize(width: CGFloat(cgImg.width) / 2, height: CGFloat(cgImg.height) / 2)
        return NSImage(cgImage: cgImg, size: size)
    }

    /// 视频缩略图——AVAssetImageGenerator 抽帧。优先取 0.5s 帧避开开头黑场/淡入,失败
    /// 兜底 0s。maximumSize 让 AVF 自己 downscale 不传整张 4K decode 进内存
    nonisolated private static func decodeVideoThumbnail(url: URL, maxPx: Int) -> NSImage? {
        // 先做文件 readability sanity check——`FileManager.fileExists` 在 iCloud Documents /
        // ~/Documents 等 TCC 受保护目录上会返 true 但实际 daemon read 0 字节（macOS 14+
        // 默认 LaunchAgent 没"完整磁盘访问"权限）。短 read 探测失败时打 log 让用户知道
        // 真因
        let fm = FileManager.default
        if !fm.isReadableFile(atPath: url.path) {
            FileHandle.standardError.write(Data(
                "video-thumb: not readable (TCC?) path=\(url.path)\n".utf8
            ))
            return nil
        }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true   // 应用 metadata 旋转(竖拍视频别躺着)
        gen.maximumSize = CGSize(width: CGFloat(maxPx), height: CGFloat(maxPx))
        let attempts: [CMTime] = [
            CMTime(seconds: 0.5, preferredTimescale: 600),
            .zero,
        ]
        var lastErr: Error?
        for t in attempts {
            do {
                let cgImg = try gen.copyCGImage(at: t, actualTime: nil)
                let size = NSSize(width: CGFloat(cgImg.width) / 2, height: CGFloat(cgImg.height) / 2)
                return NSImage(cgImage: cgImg, size: size)
            } catch {
                lastErr = error
            }
        }
        FileHandle.standardError.write(Data(
            "video-thumb: copyCGImage failed url=\(url.lastPathComponent) err=\(lastErr.map { "\($0)" } ?? "nil")\n".utf8
        ))
        return nil
    }
}

/// 按 bundleID → app icon 的进程内 LRU-less 缓存。
/// NSWorkspace.icon(forFile:) 每次都 IO 一次（读 Info.plist + .icns），row 渲染时不能每次重算。
/// 没装的 bundleID（mirror 来的对端独有 app）会进 notFound 集合避免反复查 LaunchServices。
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]
    private var notFound: Set<String> = []

    /// 系统组件 bundleID 黑名单——LaunchServices 给得出 icon，但不代表真实"来源 app"。
    /// 已知触发场景：mini 屏幕锁着 / 无人前台时，NSWorkspace.frontmostApplication 报
    /// `com.apple.loginwindow`，而 loginwindow.app 自带 icon 是张白色网格占位图，UI 上很丑。
    /// 命中直接返 nil，走 SF Symbol fallback。
    private static let nonAppBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.WindowServer",
        "com.apple.dock",
        // self-capture sentinel：详见 Item.selfSourceAppSentinel。即便有别处误调
        // AppIconCache，也直接命中黑名单返 nil，让 leadingIcon 走 self badge 分支
        Item.selfSourceAppSentinel,
    ]

    func icon(forBundleID bid: String) -> NSImage? {
        if Self.nonAppBundleIDs.contains(bid) { return nil }
        if let img = cache[bid] { return img }
        if notFound.contains(bid) { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let img = NSWorkspace.shared.icon(forFile: url.path)
            cache[bid] = img
            return img
        }
        notFound.insert(bid)
        return nil
    }
}

/// SwiftUI PreferenceKey:把 currentItem 卡片的 .global frame 上报给 AppState/Controller。
/// .global 是 SwiftUI 在 hosting view(NSPanel 的 contentView)内的 top-left 坐标空间,
/// PreviewPanelController 拿到后再换算屏幕坐标(bottom-left)
private struct SelectedCardFramePreference: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 浮岛 panel 的玻璃背景。macOS 26+ 走 Liquid Glass (`.glassEffect`)——视觉更通透有
/// 折射感;老系统兜底 `.ultraThickMaterial` (NSVisualEffectView)。
///
/// **截图 tradeoff**:`.glassEffect` 配 `isOpaque=false + bg=.clear` 会让 CleanShotX 等
/// 截图工具抓到的 panel 透明(跟系统 Spotlight 同行为)。用户接受这个 trade-off 换 Liquid
/// Glass 视觉——本质上是"录屏 / 截图 vs 实时视觉"两选一。要回到 ultraThickMaterial 把
/// `if #available` 分支去掉即可
@MainActor
private struct PanelBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .background(Color.clear.glassEffect(.regular, in: shape))
                .clipShape(shape)
        } else {
            content
                .background(.ultraThickMaterial)
                .clipShape(shape)
        }
    }
}

struct SearchView: View {
    @Bindable var state: AppState
    /// Enter / 双击触发的 paste 回调。双击行传 `[item]` 单条;Enter 由 SearchPanelController
    /// 走 selectedItems 传多条。AppDelegate.pasteBack 根据数量决定单项 / 合并 / 降级路径
    var onPaste: ([Item]) -> Void
    var onClose: () -> Void
    /// 预览状态变化时通知 caller (SearchPanelController) 驱动 PreviewPanelController。
    /// `shown=true` 表示 show/update 浮窗(controller 自己 read state.currentItem + 卡片
    /// frame);false 表示 hide。在 panel hide 时 controller 也会兜底再 hide 一次
    var onPreviewChange: (Bool) -> Void = { _ in }
    /// 右键 contextMenu "在 Finder 显示" 触发,跟键盘 ⌘Return 走同一 handler。
    /// 仅 file/image kind 才在菜单里出现;nil = caller 不接菜单项不显示
    var onReveal: ((Item) -> Void)? = nil
    /// 右键 contextMenu "打开方式" 子菜单选中某 app 后触发。(item, app bundleURL)。
    /// nil = caller 不接子菜单不显示
    var onOpenWith: ((Item, URL) -> Void)? = nil

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // compactHeader 加 zIndex 让 slash 补全 overlay 浮在 chip 行之上——SwiftUI
            // VStack 默认 z 按声明顺序 ascending,compactHeader 在前 → z 比 compactFilterBar
            // 低 → overlay 会被 chip 行遮(用户反馈过)
            compactHeader.zIndex(10)   // 搜索框 + count(单行 ~42px)
            compactFilterBar           // chip 行 + 时间窗 + 仅置顶(~30px)
            // 主体卡片区域,横向 LazyHStack 滚动
            if state.results.isEmpty {
                emptyView
            } else {
                cardScroller
            }
        }
        // panel 内点空白(非 card / 非 TextField / 非 chip)关 preview——SwiftUI hit-test
        // 是 child-first,有 onTapGesture 的子视图(card / chip)优先吃 tap,父这层只在
        // 真正空白处 fire。配合 SearchPanelController 的 global click monitor(app 外
        // 点击退整个 panel)形成完整 "click outside to dismiss preview" 路径
        .contentShape(Rectangle())
        .onTapGesture {
            if state.previewShown { state.previewShown = false }
        }
        .overlay(alignment: .top) {
            // banner 用 overlay 浮在 header 上方,不占主体高度。
            // padding.top 让位给 header(42) + filterBar(30) = 72
            VStack(spacing: 4) {
                noticeBanner
                pasteProgressBanner
                skipBanner
                modeBanner
                clockSkewBanner
            }
            .padding(.top, 76)
            .padding(.horizontal, 14)
            .allowsHitTesting(false)  // overlay 不抢点击,user 还能点卡片
        }
        .frame(minWidth: 800, minHeight: 358, idealHeight: 358, maxHeight: 358)
        // 空格预览 = 独立 NSPanel(PreviewPanelController),不在 SearchView 里渲染。
        // 这里只做 trigger 把状态变化抛给 caller,真正 show/hide/reposition 由 controller
        // 完成。三个 onChange 覆盖触发面:
        //   1) previewShown true/false toggle
        //   2) selectedIDs 变化(箭头切换 currentItem) → 内容跟随
        //   3) selectedCardWindowRect 变化(滚动 / 布局更新) → 浮窗 reposition
        .onChange(of: state.previewShown) { _, shown in
            onPreviewChange(shown)
        }
        .onChange(of: state.selectedIDs) { _, _ in
            if state.previewShown { onPreviewChange(true) }
        }
        .onChange(of: state.selectedCardWindowRect) { _, _ in
            if state.previewShown { onPreviewChange(true) }
        }
        .onPreferenceChange(SelectedCardFramePreference.self) { rect in
            // PreferenceKey 在 layout 过程里多次 fire,只在值真正变化时写回,避免
            // 触发上面 onChange 死循环
            if rect != state.selectedCardWindowRect {
                state.selectedCardWindowRect = rect
            }
        }
        // Floating island:四角圆,panel 四周有 margin 不贴屏幕边。
        // macOS 26+ 走 Liquid Glass(.glassEffect),老系统兜底 ultraThickMaterial
        .modifier(PanelBackgroundModifier(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        // 让内容延伸到 NSPanel titlebar 区域（fullSizeContentView 把 contentView 占位让出来，
        // 但 SwiftUI 默认仍把 titlebar 计入 top safe area，所以 header 上方会留 ~28pt 空白）
        .ignoresSafeArea()
        // debounce 100ms：用户连打 / 切 chip 时上一个 task 被 .task(id:) cancel 掉，新 task
        // 先 sleep 100ms 再 refresh。停手 100ms 后才真正发远端请求——10 次按键的
        // 远端 roundtrip 合并成 1 次。CancellationError 自然吞掉。
        // id 用 filterID（query + kinds + timeRange 联合指纹），任一维度变化都触发新 fetch
        .task(id: state.filterID) {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                await state.refresh()
            } catch {
                // 被取消（用户继续打字 / 改筛选）→ 让下一个 task 接手，啥也不做
            }
        }
        .onAppear {
            searchFieldFocused = true
            // onAppear 时不 debounce——首次打开应当立刻 refresh
            Task { await state.refresh() }
        }
        // panel 被复用（orderOut 不销毁 hosting view），每次 show() bump openPulse
        // → 这里把焦点抢回 TextField + 立即 refresh，避免 reshow 时光标不见 / 看到 stale results
        .onChange(of: state.openPulse) { _, _ in
            // panel 复用：上次 hide 不会重置 @FocusState，再赋 true 是无效赋值，
            // 光标不会重新装回 field editor（表现为没有闪烁的输入提示）。
            // 先掀掉再下一 runloop 装回，强制 SwiftUI 走一次 focus 变化。
            searchFieldFocused = false
            DispatchQueue.main.async {
                searchFieldFocused = true
            }
            Task { await state.refresh() }
        }
        // 注：箭头 / Return / Esc 由 SearchPanelController 的 NSEvent local monitor
        // 截下来直接调 state.navigate / onPaste，绕过 SwiftUI TextField 对箭头键的吞噬。
    }

    /// 紧凑搜索头。search field 自带 capsule border + bg 像 macOS 标准 input;count 跟着
    /// 一起在 maxWidth 800 box 内居中。user 反馈"搜索框 + label + 时间是一个整体" → 三者
    /// 共享 maxWidth 让视觉聚焦同一区域;search 加 border 让它看着是"输入框"而非裸文字
    private var compactHeader: some View {
        HStack(spacing: 10) {
            // search 加 capsule bg + border,像标准 macOS 搜索 input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                // 已激活的 slash qualifier 渲染成 pill chip,排在 TextField 左侧。每个 chip
                // 自带 ✕ 一键删,Backspace 在 TextField 为空时弹最后一个(SearchPanelController
                // 装的 keyMonitor 拦 keyCode=51)
                ForEach(state.activeQualifiers, id: \.self) { qual in
                    QualifierChipPill(qualifier: qual) {
                        state.removeQualifier(qual)
                    }
                }
                TextField("搜索剪贴板历史 (输 / 触发筛选)", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .regular))
                    .focused($searchFieldFocused)
                if !state.query.isEmpty {
                    Button {
                        state.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.primary.opacity(searchFieldFocused ? 0.08 : 0.05))
            )
            .overlay(
                Capsule().strokeBorder(
                    searchFieldFocused
                        ? Color.accentColor.opacity(0.55)
                        : Color.primary.opacity(0.12),
                    lineWidth: searchFieldFocused ? 1.2 : 0.5
                )
            )
            // focus 态加 accent 色辉光环——SwiftUI shadow 不被 Capsule clip,自然外溢
            .shadow(
                color: searchFieldFocused ? Color.accentColor.opacity(0.22) : .clear,
                radius: searchFieldFocused ? 8 : 0,
                y: 1
            )
            .animation(.smooth(duration: 0.18), value: searchFieldFocused)
            // slash 补全候选浮层——绑在搜索框下方,跟搜索框 capsule 同宽
            .overlay(alignment: .bottomLeading) {
                if state.completionMenuVisible && !state.completionCandidates.isEmpty {
                    completionOverlay
                        .offset(y: 36)  // 36pt = capsule 高度 + 4pt 间距
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .zIndex(1)  // 让 overlay 浮在 chip 行之上
            Text("\(state.totalCount) 条")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        // maxWidth 800 居中:搜索框 + count 三件一组居中聚焦,跟卡片区横铺解耦
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: state.query) { _, _ in
            extractQualifierChips()
            updateCompletion()
        }
    }

    /// query 里出现已闭合（后跟空格）的合法 /xxx token → 自动抽到 activeQualifiers,
    /// query 字符串里只保留搜索文本 + 末尾未闭合的 /xxx(让补全菜单继续)。
    /// 用户输 `/image ocr` 时:输到 "/image " 那一刻 "/image" 立即变 chip,query 变 "ocr"
    private func extractQualifierChips() {
        let (extracted, remaining) = QueryParser.extractCompleted(state.query)
        guard !extracted.isEmpty else { return }
        for q in extracted where !state.activeQualifiers.contains(q) {
            state.activeQualifiers.append(q)
        }
        // 抽完后 query 字符串只剩搜索文本 + 末尾未闭合 /xxx
        if remaining != state.query {
            state.query = remaining
        }
    }

    /// slash 补全候选浮层——VStack 列出 QueryParser.suggestions 候选,高亮项 accent 背景
    private var completionOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.completionCandidates.enumerated()), id: \.offset) { idx, candidate in
                let isHighlighted = idx == state.completionHighlight
                Button {
                    acceptCompletion(at: idx)
                } label: {
                    HStack(spacing: 8) {
                        Text(candidate.display)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(isHighlighted ? Color.white : .primary)
                        Spacer()
                        Text(qualifierHint(candidate.qualifier))
                            .font(.system(size: 11))
                            .foregroundStyle(isHighlighted ? Color.white.opacity(0.75) : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isHighlighted ? Color.accentColor : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    /// qualifier 显示对应的中文提示文本（候选行右侧）
    private func qualifierHint(_ q: QueryQualifier) -> String {
        switch q {
        case .kind(let k):
            switch k {
            case .text: return "文本"
            case .rtf: return "富文本"
            case .html: return "HTML"
            case .url: return "链接"
            case .image: return "图片"
            case .file: return "文件"
            }
        case .fileSubKind(let s):
            switch s {
            case .video: return "视频"
            case .pdf: return "PDF"
            case .audio: return "音频"
            case .imageFile: return "图片文件"
            }
        case .imageMerged: return "图片(合并)"
        case .textSuffix(let s): return "文件名 *\(s)"
        }
    }

    /// 监听 query 变化：当前 token（按空白拆，取最后一个）以 `/` 开头时弹补全菜单
    private func updateCompletion() {
        let lastToken = state.query.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if lastToken.hasPrefix("/"), lastToken.count >= 1 {
            let suggestions = QueryParser.suggestions(prefix: lastToken)
            state.completionCandidates = suggestions
            state.completionMenuVisible = !suggestions.isEmpty
            // highlight 跟随候选数量 clamp
            if state.completionHighlight >= suggestions.count {
                state.completionHighlight = 0
            }
        } else {
            state.completionMenuVisible = false
            state.completionCandidates = []
            state.completionHighlight = 0
        }
    }

    /// 鼠标点候选行 → 接受补全。键盘 Enter 路径走 SearchPanelController 直接调
    /// state.acceptCompletion()（同样 binding 到 AppState 上的实现）
    private func acceptCompletion(at index: Int) {
        state.acceptCompletion(at: index)
    }

    /// 紧凑 filter 行 ~30px。原 filterBar 高 ~46px,缩小 chip 字号 + padding 让它适配 panel。
    /// chip 行跟 header 同样 maxWidth 800 居中,跟卡片区横铺解耦
    ///
    /// **chip 折叠策略**：primary = [文本] [图片合并] [链接] [PDF]，secondary 的
    /// [富文本] [HTML] [视频] [音频] [图片文件] [文件] 折进 "更多 ▾" Menu。
    /// 心智：覆盖 90% 高频，secondary 用得少不该一直占空间。
    /// [图片] chip 合并语义——同时响应 .image kind（原生剪贴板截图）+ .imageFile sub-kind
    /// (Finder 复制的 .png 文件)，用户视角"图片就是一种东西"
    private var compactFilterBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        // 文本 chip
                        KindChip(
                            kind: .text,
                            isSelected: state.isKindActive(.text),
                            count: state.kindCounts.isEmpty ? nil : (state.kindCounts[.text] ?? 0),
                            onTap: { toggleKind(.text) }
                        )
                        // 图片 chip——合并 .image + .imageFile 计数 / toggle
                        KindChip(
                            kind: .image,
                            isSelected: state.isKindActive(.image) || state.isFileSubKindActive(.imageFile),
                            count: (state.kindCounts.isEmpty && state.fileSubKindCounts.isEmpty) ? nil : state.imageMergedCount,
                            onTap: { state.toggleImageChip() }
                        )
                        // 链接 chip
                        KindChip(
                            kind: .url,
                            isSelected: state.isKindActive(.url),
                            count: state.kindCounts.isEmpty ? nil : (state.kindCounts[.url] ?? 0),
                            onTap: { toggleKind(.url) }
                        )
                        // PDF chip
                        FileSubKindChip(
                            sub: .pdf,
                            isSelected: state.isFileSubKindActive(.pdf),
                            count: state.fileSubKindCounts.isEmpty ? nil : (state.fileSubKindCounts[.pdf] ?? 0),
                            onTap: { toggleFileSubKind(.pdf) }
                        )
                        // 更多 ▾ Menu——折叠 secondary chip
                        moreChipMenu
                        if !state.selectedKinds.isEmpty || !state.selectedFileSubKinds.isEmpty || !state.activeQualifiers.isEmpty {
                            Button {
                                state.clearAllFilters()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("清除类型筛选")
                        }
                        pinnedOnlyChip
                    }
                }
                timeRangeMenu
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 10)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity, alignment: .center)
            // 跟卡片区域分隔的 hairline
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    /// secondary chip 折叠菜单——[富文本] [HTML] [视频] [音频] [图片文件] [文件]。
    /// 任一 secondary 选中时按钮加 `•` accent dot 提示
    private var moreChipMenu: some View {
        let secondaryKinds: [ItemKind] = [.rtf, .html, .file]
        let secondarySubs: [FileSubKind] = [.video, .audio, .imageFile]
        let anySelected = secondaryKinds.contains { state.isKindActive($0) }
            || secondarySubs.contains { state.isFileSubKindActive($0) }
        return Menu {
            ForEach(secondaryKinds, id: \.self) { kind in
                Button {
                    toggleKind(kind)
                } label: {
                    Label {
                        let n = state.kindCounts[kind] ?? 0
                        Text("\(kindMenuLabel(kind)) (\(n))")
                    } icon: {
                        Image(systemName: state.isKindActive(kind) ? "checkmark" : "")
                    }
                }
            }
            Divider()
            ForEach(secondarySubs, id: \.self) { sub in
                Button {
                    toggleFileSubKind(sub)
                } label: {
                    Label {
                        let n = state.fileSubKindCounts[sub] ?? 0
                        Text("\(subMenuLabel(sub)) (\(n))")
                    } icon: {
                        Image(systemName: state.isFileSubKindActive(sub) ? "checkmark" : "")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("更多")
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                if anySelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(.primary)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func kindMenuLabel(_ k: ItemKind) -> String {
        switch k {
        case .text: "文本"
        case .rtf: "富文本"
        case .html: "HTML"
        case .url: "链接"
        case .image: "图片"
        case .file: "文件"
        }
    }

    private func subMenuLabel(_ s: FileSubKind) -> String {
        switch s {
        case .video: "视频"
        case .pdf: "PDF"
        case .audio: "音频"
        case .imageFile: "图片文件"
        }
    }

    /// 当前预览锚点的 item id——跟 AppState.currentItem 同口径(selectedIDs.last ?? 第一个)。
    /// 用 String? 而不是 Item? 让 ForEach 内的 `==` 比较廉价(不重比整个 Item struct)
    private var previewAnchorID: String? {
        state.selectedIDs.last ?? state.results.first?.id
    }

    /// Paste.app 风格横向卡片滚动。LazyHStack 让千条 item 不卡——出视口的卡 unload。
    /// ScrollViewReader.scrollTo 配 selectedIDs.last + scrollPulse 让箭头导航能滚到选中卡
    private var cardScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // alignment .top 让卡片顶贴 ScrollView 顶,frame maxHeight infinity + top
                // alignment 让 LazyHStack 占满 ScrollView 高度但卡片靠顶——消除 user 反馈
                // 的"第二次打开 panel 底部还有大空隙"(SwiftUI 默认 vertical centering 让卡片
                // 在 ScrollView 内居中,下方留空白)
                // spacing=10 + 每张卡 .padding(.trailing, 12) → 视觉间距 22pt 跟之前一致。
                // trailing padding 让 card 的 frame(被 .id 标识 + 被 scrollTo 锚定的那个)
                // 含 12pt slack,topRight icon 的 8pt 溢出落在 slack 内,scrollTo 最右卡时
                // 不会被 ScrollView clip 切掉 icon
                LazyHStack(alignment: .top, spacing: 10) {
                    // 前 9 张挂 ⌘1 ~ ⌘9 序号,enumerated 拿 index;之后传 nil 不显示角标
                    ForEach(Array(state.results.enumerated()), id: \.element.id) { offset, item in
                        ItemCard(
                            item: item,
                            index: offset < 9 ? offset + 1 : nil,
                            isSelected: state.selectedIDs.contains(item.id),
                            selfDeviceID: state.deps.deviceID,
                            snippet: state.snippets[item.id],
                            blobs: state.deps.blobs,
                            fetcher: state.pasteBlobFetcher,
                            storageMode: state.deps.config.mesh.storageMode,
                            blobInventoryPulse: state.blobInventoryPulse
                        )
                        // 仅 currentItem 那张卡上挂 GeometryReader 发布 frame——currentItem
                        // = selectedIDs.last,跟 PreviewPanelController 锚定逻辑一致。
                        // GeometryReader 必须在 .padding 前,读到的是 240pt 卡本身的 frame
                        // 而不是 252pt 含 slack 的 padded frame(影响 preview 浮窗锚点)
                        .background {
                            if item.id == previewAnchorID {
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(
                                            key: SelectedCardFramePreference.self,
                                            value: geo.frame(in: .global)
                                        )
                                }
                            }
                        }
                        // 右侧 12pt slack 给 topRight icon 的 8pt 溢出留位置;.id 在 padding
                        // 后挂,scrollTo 锚定 252pt 含 slack 的 padded frame,最右卡 scrollTo
                        // 后 icon 仍在 viewport 内
                        .padding(.trailing, 12)
                        .id(item.id)
                        // user 反馈不要点击放大动画 + 首卡 scale 会让左边框超出 viewport 被裁,
                        // scaleEffect 全撤掉,选中态靠 accent border + shadow 高亮即可
                        // 双击粘贴(无视 selectedIDs)
                        .gesture(
                            TapGesture(count: 2).onEnded {
                                onPaste([item])
                            }
                        )
                        // 单击改 selection;NSEvent.modifierFlags 同步取 cmd/shift 状态
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.command) {
                                    if let i = state.selectedIDs.firstIndex(of: item.id) {
                                        state.selectedIDs.remove(at: i)
                                    } else {
                                        state.selectedIDs.append(item.id)
                                        state.anchorID = item.id
                                    }
                                } else if mods.contains(.shift) {
                                    guard let anchor = state.anchorID,
                                          let from = state.results.firstIndex(where: { $0.id == anchor }),
                                          let to = state.results.firstIndex(where: { $0.id == item.id })
                                    else {
                                        state.selectedIDs = [item.id]
                                        state.anchorID = item.id
                                        return
                                    }
                                    let lo = min(from, to)
                                    let hi = max(from, to)
                                    state.selectedIDs = (lo...hi).map { state.results[$0].id }
                                } else {
                                    // 普通单击 → 单选 + 触发 scrollTo center,让点击 viewport
                                    // 边缘的卡也滚到完整可见(原版只有键盘 navigate 才滚)
                                    state.selectedIDs = [item.id]
                                    state.anchorID = item.id
                                    state.scrollPulse &+= 1
                                }
                            }
                        )
                        // 右键 contextMenu —— "粘贴 / 在 Finder 显示 / 打开方式 / 置顶"。
                        // 注意:点击 contextMenu 项不走单击/双击 gesture 路径,所以右键时
                        // selectedIDs 不被改;菜单永远只操作 `item`(被右键点中的那张卡),
                        // 不是 selectedItems。这跟 Finder 行为对齐:右键单张文件不改多选
                        .contextMenu {
                            Button("粘贴") { onPaste([item]) }
                            if let onReveal,
                               item.kind == .file || item.kind == .image {
                                Button("在 Finder 显示") { onReveal(item) }
                            }
                            Divider()
                            if let onOpenWith {
                                OpenWithMenu(item: item, onOpenWith: onOpenWith)
                            }
                            Divider()
                            Button(item.pinned ? "取消置顶" : "置顶") {
                                state.togglePin(item)
                            }
                        }
                    }
                }
                // 顶部 12pt 给 icon offset(y:-8) 上溢出留 buffer + 跟 filter hairline 间距
                .padding(.top, 12)
            }
            // 横向 padding 22 跟 header/filterBar 对齐,panel 左右两侧 padding 统一。
            // frame height 254 = 卡片 236 + top 12 + bottom 6 余量,ScrollView 不 fill remaining
            // (user 反馈"重复打开 window 下方仍有 padding" = ScrollView fill remaining 时
            // SwiftUI 让内容 vertical center 留下方空白)
            .frame(height: 254)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            .onChange(of: state.scrollPulse) { _, _ in
                if let id = state.selectedIDs.last {
                    // anchor=nil → SwiftUI "scrolls the view minimally to make it visible"——
                    // 卡片已在 viewport 内不动,只在边缘部分可见才滚最少距离让它完整露出。
                    // 之前 anchor: .center 会让每次点击都把卡片硬居中,中间卡也被强滚很烦
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板历史", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFieldFocused)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("\(state.totalCount) 条")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    /// 类型 chip 行 + 时间窗下拉。
    ///
    /// - 类型 chip 多选：空 = 全部（不带 IN 过滤）。pill 风格，选中状态 accent 填充
    /// - 时间窗放右侧 Menu：单选「全部 / 24h / 7d / 30d」
    ///
    /// chip 顺序按 ItemKind 出现频次手排（text 最常用 → 排最左），不按 enum 声明序。
    /// 改 chip 时不要按 ItemKind.allCases 遍历——枚举序 (text/rtf/html/url/image/file)
    /// 把 rtf/html 推到前面会让用户每次都要扫过去找"图片"
    ///
    /// 布局：左侧 chip 区横向滚动（panel 收窄时不会让 "文本" 垂直堆叠成 "文 / 本"，
    /// trackpad 双指水平滑动可见全部 chip），右侧 timeRangeMenu 固定贴边——时间窗高频，
    /// 不能因为滚动隐藏到屏外。chip 内部全部 `.fixedSize()` 保自然宽度。
    private var filterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filterChipKinds, id: \.self) { kind in
                        // 契约：空 dict（出错降级）→ nil 隐藏数字；非空 dict（fold-aware 正常路径）
                        // → 缺 key 默认 0 显示 "图片 0"。这样 KindChip 头注释的 "0 也显示" 才真生效
                        KindChip(
                            kind: kind,
                            isSelected: state.selectedKinds.contains(kind),
                            count: state.kindCounts.isEmpty ? nil : (state.kindCounts[kind] ?? 0),
                            onTap: { toggleKind(kind) }
                        )
                    }
                    if !state.selectedKinds.isEmpty {
                        Button {
                            state.selectedKinds.removeAll()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清除类型筛选")
                    }
                    pinnedOnlyChip
                }
                .padding(.vertical, 1)
            }
            timeRangeMenu
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    /// 「仅置顶」开关——风格跟 KindChip 一致，但单 chip 即开关，不带 ✕
    private var pinnedOnlyChip: some View {
        Button {
            state.pinnedOnly.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                Text("仅置顶")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(state.pinnedOnly ? Color.white : .primary)
            .background(
                Capsule()
                    .fill(state.pinnedOnly ? Color.accentColor : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// chip 排列顺序：剪贴板使用频次心智（文本/图片/链接最常用 → 排前面）
    private var filterChipKinds: [ItemKind] {
        [.text, .image, .url, .file, .rtf, .html]
    }

    /// `.file` 细分 chip 顺序——视频 / PDF / 音频 / 图片文件,按出现频次
    private var filterChipFileSubKinds: [FileSubKind] {
        [.video, .pdf, .audio, .imageFile]
    }

    private func toggleKind(_ kind: ItemKind) {
        if state.selectedKinds.contains(kind) {
            state.selectedKinds.remove(kind)
        } else {
            state.selectedKinds.insert(kind)
        }
    }

    private func toggleFileSubKind(_ sub: FileSubKind) {
        if state.selectedFileSubKinds.contains(sub) {
            state.selectedFileSubKinds.remove(sub)
        } else {
            state.selectedFileSubKinds.insert(sub)
        }
    }

    private var timeRangeMenu: some View {
        Menu {
            ForEach(AppState.TimeRange.allCases) { range in
                Button {
                    state.timeRange = range
                } label: {
                    if state.timeRange == range {
                        Label(range.label, systemImage: "checkmark")
                    } else {
                        Text(range.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                Text(state.timeRange.label)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(state.timeRange == .all ? .secondary : Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(state.timeRange == .all ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.15))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 一次性 notice（pin mirror 行被拒等）。文案 3s 自动消失（AppState 控制）。
    /// 跟 skipBanner 区分：notice 是即时操作反馈（按 ⌘P 没生效原因），
    /// skipBanner 是后台 capture 事件（用户没看 panel 时也会塞进来）。
    @ViewBuilder
    private var noticeBanner: some View {
        if let text = state.recentNotice {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(text)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
        }
    }

    /// 体积超限 banner：5 分钟内有 skip → 黄色提示「最近一次复制太大没存」。
    /// ✕ 可关；不持久化，重启就清。这是 capture cap 的可见出口——光 stderr log
    /// 用户感知不到，会以为"daemon 挂了 / bug"。
    @ViewBuilder
    private var skipBanner: some View {
        if let skip = state.recentSkip,
           Date().timeIntervalSince(skip.occurredAt) < 300 {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                Text(skipDescription(skip))
                Spacer()
                Button {
                    state.dismissSkip()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.18))
        }
    }

    /// blob 懒拉过程中的状态条：
    /// - `.idle` → 不显示
    /// - `.fetching` → 蓝色 spinner + "拉取图片…"（含 sizeHint 可知时）
    /// - `.failed` → 红色 banner 显示错误文案；Esc 关闭 panel 或 Enter 重试由 key monitor 处理
    @ViewBuilder
    private var pasteProgressBanner: some View {
        switch state.pasteProgress {
        case .idle:
            EmptyView()
        case .fetching(_, let sizeHint):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                if let s = sizeHint, s > 0 {
                    Text("拉取图片字节（约 \(humanBytes(Int(s)))）…")
                } else {
                    Text("拉取图片字节…")
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.15))
        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text("图片粘贴失败：\(reason)")
                Spacer()
                Button {
                    state.pasteProgress = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.18))
        }
    }

    private func skipDescription(_ s: AppState.SkipNotice) -> String {
        let kindLabel = s.kind == .blob ? "图片/文件" : "文本"
        return "刚才有一段\(kindLabel)太大没入库（\(humanBytes(s.bytes)) > \(humanBytes(s.limit))）；剪贴板本身正常，可直接 Cmd+V 粘贴"
    }

    private func humanBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    /// 顶部 banner：
    /// - `.local` → 不显示（standalone 或 mesh 还没追平任何 peer 的初始态）
    /// - `.mesh(stalenessSec: nil)` → 不显示（peer 配了但还没成功跑过 pull tick）
    /// - `.mesh(stalenessSec)` 稳态 0-60s → 不显示
    /// - `.mesh(stalenessSec)` > 300s → 黄色显示「peer 同步滞后」
    ///   pull interval 默认 30s，稳态 staleness 应在 0-60s。超过 300s 说明 PullWorker
    ///   卡死 / peer 不可达 / 时钟漂移，这时才有告知价值
    @ViewBuilder
    private var modeBanner: some View {
        switch state.searchMode {
        case .mesh(let stalenessSec) where (stalenessSec ?? 0) > 300:
            HStack(spacing: 6) {
                Image(systemName: "internaldrive.badge.exclamationmark")
                Text("peer 同步滞后")
                Text("·").foregroundStyle(.secondary)
                Text("已 \(humanStaleness(stalenessSec ?? 0)) 未拉取").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15))
        case .mesh, .local:
            EmptyView()
        }
    }

    /// 时钟偏移 banner：|skew| 超过阈值才显示。HMAC 签名容忍 ±5 分钟 skew，所以这是早期预警：
    /// 用户能看到偏移大小 → 提示去 NTP / sleep 设置排查，免得后面收到 401 才找原因。
    @ViewBuilder
    private var clockSkewBanner: some View {
        if let skew = state.clockSkewMs, abs(skew) >= state.clockSkewWarnMs {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark")
                Text("时钟偏移：primary 比本机\(skew > 0 ? "快" : "慢") \(humanSkew(abs(skew)))")
                Text("·").foregroundStyle(.secondary)
                Text("接近 5 分钟会签名失败").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15))
        }
    }

    private func humanSkew(_ ms: Int64) -> String {
        if ms < 1_000 { return "\(ms)ms" }
        let sec = ms / 1_000
        if sec < 60 { return "\(sec)s" }
        return "\(sec / 60)m\(sec % 60)s"
    }

    private func humanStaleness(_ sec: Int) -> String {
        if sec < 60 { return "\(sec)s" }
        if sec < 3600 { return "\(sec / 60)m" }
        return "\(sec / 3600)h"
    }

    private var emptyView: some View {
        // 区分两个语义：库里真空（首次安装）vs 当前筛选导致空。后者只要 query / kinds /
        // timeRange / pinnedOnly 任一非默认就成立——文案不同避免用户误以为 daemon 挂了
        let hasActiveFilter = !state.query.isEmpty
            || !state.selectedKinds.isEmpty
            || state.timeRange != .all
            || state.pinnedOnly
        return VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(hasActiveFilter ? "当前筛选无结果" : "还没有任何剪贴板历史")
                .foregroundStyle(.secondary)
            if let err = state.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 旧 list(LazyVStack 垂直列表)已被 cardScroller(LazyHStack 横向卡片)替代,见 body 调用
}

/// 类型 chip 单元。pill capsule，选中状态 accent 填充 + 白字。
/// 单击 toggle 选中状态。视觉跟 timeRangeMenu 的 capsule 保持一致——padding / radius 同步
///
/// `count` 非 nil 时尾巴挂活计数 "图片 19"——让用户立刻看出哪个类稀疏。
/// 0 也显示（"图片 0"），避免用户误以为 filter 失效；nil = 出错降级时隐藏。
/// nil/0 的区分发生在 caller：空 kindCounts dict（出错降级）→ nil；非空 dict
/// （fold-aware 路径有命中）→ 缺 key 默认 0。
/// `.file` 细分 chip——风格跟 KindChip 一致,kind 换成 FileSubKind
/// 搜索框内已激活的 slash qualifier pill —— `/image` `/pdf` `/java` 等。pill 风格,
/// 自带 ✕ 按钮一键删,Backspace 在 TextField 空时弹最后一个。颜色弱于 KindChip 的
/// selected 态(不抢搜索焦点),但跟普通 .ultraThinMaterial 区分,让 chip 边界清晰
private struct QualifierChipPill: View {
    let qualifier: QueryQualifier
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(displayText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.accentColor.opacity(0.18))
        )
        .overlay(
            Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
        )
        .fixedSize()
    }

    private var displayText: String {
        switch qualifier {
        case .kind(let k):
            switch k {
            case .text: return "/text"
            case .rtf: return "/rtf"
            case .html: return "/html"
            case .url: return "/url"
            case .image: return "/image"
            case .file: return "/file"
            }
        case .fileSubKind(let s):
            switch s {
            case .video: return "/video"
            case .pdf: return "/pdf"
            case .audio: return "/audio"
            case .imageFile: return "/imagefile"
            }
        case .imageMerged: return "/image"
        case .textSuffix(let s): return s.hasPrefix(".") ? "/" + String(s.dropFirst()) : "/" + s
        }
    }
}

private struct FileSubKindChip: View {
    let sub: FileSubKind
    let isSelected: Bool
    let count: Int?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : .primary)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
            )
            .shadow(
                color: isSelected ? Color.accentColor.opacity(0.35) : .clear,
                radius: isSelected ? 6 : 0,
                y: 1
            )
            .animation(.smooth(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var label: String {
        switch sub {
        case .video: "视频"
        case .pdf: "PDF"
        case .audio: "音频"
        case .imageFile: "图片文件"
        }
    }

    private var symbol: String {
        switch sub {
        case .video: "play.rectangle"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .imageFile: "photo.on.rectangle"
        }
    }
}

private struct KindChip: View {
    let kind: ItemKind
    let isSelected: Bool
    let count: Int?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : .primary)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
            )
            .shadow(
                color: isSelected ? Color.accentColor.opacity(0.35) : .clear,
                radius: isSelected ? 6 : 0,
                y: 1
            )
            .animation(.smooth(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        // 不加这个，父 HStack 收窄时会把 "文本" 压成 "文 / 本" 垂直堆叠（Text 默认允许多行换行）。
        // 配合 filterBar 外层 ScrollView 横滚——panel 即使窄到 minWidth=640 chip 也保自然宽度
        .fixedSize()
    }

    private var label: String {
        switch kind {
        case .text: "文本"
        case .rtf: "富文本"
        case .html: "HTML"
        case .url: "链接"
        case .image: "图片"
        case .file: "文件"
        }
    }

    private var symbol: String {
        switch kind {
        case .text: "text.alignleft"
        case .rtf: "doc.richtext"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

private struct ItemCard: View {
    let item: Item
    /// 1-9 = 在 results 数组前 9 位,footer 右下显示 ⌘N 角标对应 ⌘1-9 快捷粘贴;
    /// nil = 位置超出快捷范围,不显示角标
    let index: Int?
    let isSelected: Bool
    /// `item.originDevice != selfDeviceID` 表示 PullWorker 从对端镜像过来的远端 item,
    /// 卡片右上角大 icon 左下叠橙色 arrow.down.left 角标
    let selfDeviceID: String
    /// 含 STX/ETX 高亮标记的 FTS snippet,query 非空 + 命中时非 nil
    let snippet: String?
    /// BlobStore reference 让 contentArea 异步加载 image kind / file-as-image 缩略图
    let blobs: BlobStore
    /// PR cloudy-mirroring-walnut PR 3：optimized storage_mode 下缩略图缺 blob 走这个
    /// fetcher 按需拉。nil = 没配 peer / shared-secret 失败，缺 blob 直接占位
    let fetcher: (any BlobFetcher)?
    let storageMode: StorageMode
    /// AppState.blobInventoryPulse 透传——补齐缺失 blob 后 bump 让本卡 .task 重 fire 走
    /// decode 路径。光靠 ImageThumbnailCache.invalidateAll 不够（.task id 不变不会 re-fire）
    let blobInventoryPulse: Int

    /// 缩略图状态。.task 异步加载完 set;LazyHStack 卡滚出视野 unload 时 cancel + 重置
    @State private var thumbnail: NSImage?
    /// PR cloudy-mirroring-walnut PR 4：手动点 ☁️ 触发下载时的进度态。thumbnail 路径
    /// 自动 lazy fetch 不显 spinner（缩略图占位本身已是提示）；用户主动点 ☁️ 才显
    @State private var cloudDownloading: Bool = false
    @State private var cloudLastError: String?
    /// 鼠标悬停态——驱动 hover ring overlay + shadow boost。**不**驱动 scaleEffect:
    /// 首卡 scaleEffect 会让左边框超出 cardScroller viewport 被裁(见 cardScroller 注释),
    /// hover 效果靠 glow ring + shadow 实现
    @State private var isHovered: Bool = false

    private var isRemoteMirror: Bool {
        item.originDevice != selfDeviceID
    }

    /// 是否应该显示缩略图——直接复用 ImageThumbnailCache.isThumbnailable
    /// (image kind / image-like file / video-like file 都接)
    private var shouldShowThumbnail: Bool {
        ImageThumbnailCache.isThumbnailable(item)
    }

    var body: some View {
        VStack(spacing: 0) {
            contentArea       // 主区 188(image aspectFill / 文本多行 / file 图标)
            footer            // 32 (meta + 右下 ⌘N 角标)
        }
        .frame(width: 240, height: 236)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.07 : 0.035))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            // 选中态 accent 描边 + 加粗;未选中按 remote mirror 决定:橙色淡描表示
            // 对端镜像(替代之前的 remoteOriginBadge 角标——跟右上 source icon 叠加看不清),
            // 本地 own 走淡灰发丝线。选中态优先于 remote 状态(用户 focus 在卡内容时
            // 来源信号让位选择反馈)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    strokeColor,
                    lineWidth: isSelected ? 2 : (isRemoteMirror ? 1 : 0.5)
                )
        )
        // hover ring——选中前 hint 这张卡可点击。白色细描 + 模糊给"高亮"感不抢
        // accent 选中态。isSelected 时不显示(避免跟 accent 描边打架)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isHovered && !isSelected ? 0.22 : 0),
                    lineWidth: 1
                )
                .blur(radius: 0.5)
        )
        // 选中卡 accent 辉光;hover 卡黑色 ambient shadow——两态独立动画,切换平滑
        .shadow(
            color: isSelected
                ? Color.accentColor.opacity(0.4)
                : (isHovered ? Color.black.opacity(0.18) : .clear),
            radius: isSelected ? 14 : (isHovered ? 10 : 0),
            x: 0, y: isSelected ? 4 : (isHovered ? 3 : 0)
        )
        .animation(.smooth(duration: 0.22), value: isSelected)
        .animation(.smooth(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
        // source app icon 钉右上**边框上**——半溢出卡片让 icon "贴"在边沿,
        // 避免内嵌方案遮挡卡内文字。cardScroller 给每张卡 .padding(.trailing, 12) 留
        // slack,scrollTo 最右卡时含 slack 的 padded frame 全可见 → icon 不被 clip
        .overlay(alignment: .topTrailing) {
            topRightSourceIcon
                .offset(x: 8, y: -8)
        }
        // PR cloudy-mirroring-walnut PR 4：☁️ cloud badge——optimized 模式 + 本机缺 blob 显示。
        // 钉到右下角避免跟右上的 source app icon 打架；点击主动触发 lazy fetch
        .overlay(alignment: .topLeading) {
            CloudBadgeView(
                state: CloudBadgeStateCalculator.state(
                    storageMode: storageMode,
                    item: item,
                    blobs: blobs,
                    isDownloading: cloudDownloading,
                    lastError: cloudLastError
                ),
                onTap: { triggerCloudDownload() }
            )
            .padding(6)
            .offset(x: item.pinned ? 30 : 0, y: 0)
        }
        // pin 角标内嵌左上(不溢出),克制风格区别于 source icon 的"贴纸"
        .overlay(alignment: .topLeading) {
            if item.pinned {
                pinBadge
                    .padding(6)
            }
        }
        .task(id: "\(ImageThumbnailCache.cacheKey(for: item) ?? "")|\(blobInventoryPulse)") {
            guard shouldShowThumbnail else {
                if thumbnail != nil { thumbnail = nil }
                return
            }
            if let cached = ImageThumbnailCache.shared.cached(for: item) {
                if thumbnail !== cached { thumbnail = cached }
                return
            }
            let img = await ImageThumbnailCache.shared.thumbnail(
                for: item, blobs: blobs,
                fetcher: fetcher, storageMode: storageMode
            )
            if !Task.isCancelled, thumbnail !== img {
                thumbnail = img
            }
        }
    }

    /// PR cloudy-mirroring-walnut PR 4：用户点 ☁️ 主动触发 lazy GET /blob。
    /// fetcher nil（standalone / shared-secret 失败）→ 立即标 failed 显红色 !
    /// 成功 → BlobStore.putVerified 写盘 + 清掉 cache key 让 thumbnail .task 重渲
    private func triggerCloudDownload() {
        guard !cloudDownloading,
              let sha = item.blobSha256,
              let fetcher else {
            if fetcher == nil { cloudLastError = "未配置 peer / shared-secret 加载失败" }
            return
        }
        cloudDownloading = true
        cloudLastError = nil
        Task {
            defer { cloudDownloading = false }
            do {
                let outcome = try await fetcher.getBlob(sha256: sha)
                if case .found(let data) = outcome {
                    _ = try blobs.putVerified(data, expectedSha256: sha)
                    // 触发 .task 重 decode 缩略图——cache key 由 sha 决定，put 后下次
                    // task fires 自然命中 BlobStore.read。强制 thumbnail=nil 让 SwiftUI
                    // re-evaluate placeholder→image 切换
                    thumbnail = nil
                } else {
                    cloudLastError = "peer 上无此 blob (404)"
                }
            } catch let err as GetBlobError {
                cloudLastError = "\(err)"
            } catch {
                cloudLastError = "\(error)"
            }
        }
    }

    /// pin 角标——卡片右上角小圆,标记 pinned 状态。
    /// macOS 26+ 走 Liquid Glass(.glassEffect 圆形),老系统 ultraThinMaterial 兜底
    @ViewBuilder
    private var pinBadge: some View {
        let icon = Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(6)
        if #available(macOS 26.0, *) {
            icon.glassEffect(.regular, in: Circle())
        } else {
            icon.background(.ultraThinMaterial, in: Circle())
        }
    }

    /// 视频卡左下 ▶ 角标——hint 这是视频不是静图,跟图片缩略图视觉区分
    @ViewBuilder
    private var videoPlayBadge: some View {
        let icon = Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(6)
        if #available(macOS 26.0, *) {
            icon.glassEffect(.regular.tint(Color.black.opacity(0.55)), in: Circle())
        } else {
            icon.background(Color.black.opacity(0.55), in: Circle())
        }
    }

    /// 卡片主区(200×188)。image kind 走原图 aspectFit(显示完整,letterbox 用深色背景填充);
    /// loading 走 placeholder;text 类走多行文字。视频缩略图叠 ▶ 角标区分静图
    @ViewBuilder
    private var contentArea: some View {
        if shouldShowThumbnail, let thumb = thumbnail {
            ZStack {
                Color.primary.opacity(0.08)  // letterbox 填充色,跟 footer 一致
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
            .frame(width: 240, height: 204)
            .overlay(alignment: .bottomLeading) {
                if ItemClassifier.isVideo(item) {
                    videoPlayBadge.padding(8)
                }
            }
        } else if shouldShowThumbnail {
            // 加载中:placeholder
            ZStack {
                Color.primary.opacity(0.03)
                Image(systemName: "photo")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            .frame(width: 240, height: 204)
        } else if item.kind == .file {
            // file 卡(非 image-as-file):大文件 SF Symbol + 文件名
            VStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary.opacity(0.7))
                previewText
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
            .frame(width: 240, height: 204)
        } else {
            // text/url/rtf/html:多行内容。**padding 必须在 frame 之前**——SwiftUI 顺序
            // 决定 padding 加在 frame 内还是外:frame 在 padding 之前会让 padding 加到 frame
            // 外面被外层 ItemCard 200×220 strict frame 吃掉,padding 失效文字顶到卡边
            previewText
                .font(.system(size: 13))
                .lineLimit(8)
                .lineSpacing(1.5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(width: 240, height: 204)
        }
    }

    /// 卡片 footer(200×32):左 kind/size/time meta + 右 ⌘N 序号角标。
    /// app icon 移到卡片右上角(topRightSourceIcon),footer 不再有 leading icon
    private var footer: some View {
        HStack(spacing: 6) {
            Text(footerMeta)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let idx = index {
                indexBadge(idx)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 240, height: 32)
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    /// 右下 ⌘N 角标——前 9 张卡显示 ⌘1 ~ ⌘9,提示用户可按 ⌘+数字键快速粘贴。
    /// SearchPanelController.installKeyMonitor 拦 ⌘1-9 keyCode 路由到 onPaste
    private func indexBadge(_ idx: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: "command")
                .font(.system(size: 9, weight: .semibold))
            Text("\(idx)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            Capsule().fill(Color.primary.opacity(0.08))
        )
    }

    /// 卡片右上角 source app icon——半溢出卡片右上顶点,贴纸风格。
    /// self capture 走 accent 圆 + 剪贴板图标。远端镜像信号已移到卡片 stroke
    /// (橙色描边),不再叠 badge 在 icon 上避免跟 app icon 视觉打架
    @ViewBuilder
    private var topRightSourceIcon: some View {
        if item.isSelfCapture {
            ZStack {
                Circle().fill(Color.accentColor)
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
        } else if let bid = item.sourceApp,
                  let img = AppIconCache.shared.icon(forBundleID: bid) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
        } else {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Image(systemName: kindSymbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 20, height: 20)
        }
    }

    /// 卡片底部 meta 行。规则按 kind/sub-kind 分支:
    /// - 图片 (kind=image / .file+.imageFile / .file+.video) 卡 **省略 kind 字**——
    ///   缩略图本身已是视觉提示,再写"图片"是冗余
    ///   - .image: "尺寸 · 时间"（原生剪贴板无文件名）
    ///   - .file+.imageFile / .file+.video: "文件名 · 尺寸 · 时间"
    /// - PDF / 音频 / 普通文件 / 其他 kind 保留 kindLabel(视觉提示弱或无缩略图)
    private var footerMeta: String {
        let rel = relativeFormatter.localizedString(for: capturedDate, relativeTo: Date())
        let size = item.blobSize.map { humanSize($0) }
        var parts: [String] = []

        if item.kind == .image {
            // 原生剪贴板图片：尺寸 · 时间
            if let s = size { parts.append(s) }
        } else if item.kind == .file {
            switch ItemClassifier.fileSubKind(item) {
            case .imageFile, .video:
                // Finder 复制的图片/视频文件：文件名 · 尺寸 · 时间
                if let name = firstFileName { parts.append(name) }
                if let s = size { parts.append(s) }
            case .pdf, .audio, .none:
                // PDF / 音频 / 普通文件：保留 kindLabel
                parts.append(kindLabel)
            }
        } else {
            // text/rtf/html/url：保留 kindLabel
            parts.append(kindLabel)
        }

        parts.append(rel)
        return parts.joined(separator: " · ")
    }

    /// `.file` kind 第一行路径的文件名。textFull 是 `\n`-join 路径串(CaptureService 写入),
    /// 取首行 → URL.lastPathComponent。跟 `previewText` 的文件名解析口径一致
    private var firstFileName: String? {
        guard let raw = item.textFull,
              let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return nil
        }
        let name = URL(fileURLWithPath: String(first)).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// 选中态 accent 描边优先;未选中按 remote mirror 区分:
    /// 对端镜像橙色淡描;本地 own 原淡灰发丝线
    private var strokeColor: Color {
        if isSelected { return Color.accentColor }
        if isRemoteMirror { return Color.orange.opacity(0.5) }
        return Color.primary.opacity(0.08)
    }

    /// kind 中文标签——meta 行第一列显示。`.file` 按 ItemClassifier 细分到
    /// 视频/PDF/音频/图片文件,普通文件继续 "文件"
    private var kindLabel: String {
        switch item.kind {
        case .text: return "文本"
        case .rtf: return "富文本"
        case .html: return "HTML"
        case .url: return "链接"
        case .image: return "图片"
        case .file:
            switch ItemClassifier.fileSubKind(item) {
            case .video: return "视频"
            case .pdf: return "PDF"
            case .audio: return "音频"
            case .imageFile: return "图片文件"
            case .none: return "文件"
            }
        }
    }

    /// app icon 不可用时的 fallback symbol。`.file` 同样按 sub-kind 细分
    private var kindSymbol: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .rtf: return "doc.richtext"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .url: return "link"
        case .image: return "photo"
        case .file:
            switch ItemClassifier.fileSubKind(item) {
            case .video: return "play.rectangle"
            case .pdf: return "doc.richtext"
            case .audio: return "waveform"
            case .imageFile: return "photo.on.rectangle"
            case .none: return "doc"
            }
        }
    }

    private var capturedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(item.capturedAtNs) / 1_000_000_000)
    }

    /// 优先用 snippet（FTS 命中片段，匹配词加粗），否则回退到 preview。
    /// snippet 用 STX/ETX 做标记：拆成 plain / bold 交替的 Text 链。
    /// 注意返回类型 `Text`（不能用 @ViewBuilder 的 _ConditionalContent，要支持
    /// `.lineLimit(2)` 这类只对 Text 生效的修饰）
    private var previewText: Text {
        // file 行 text_full 存完整路径；FTS snippet 也是路径片段——
        // 同目录下多条结果路径段相同，用户无法区分。
        // 始终显示完整文件名，并尝试把 snippet 里的高亮词匹配到文件名内加粗。
        if item.kind == .file {
            let raw = item.textFull ?? item.preview ?? ""
            let names = raw.split(separator: "\n", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0)).lastPathComponent }
                .filter { !$0.isEmpty }
            if let first = names.first {
                let head = highlightedFileName(first, from: snippet)
                if names.count == 1 { return head }
                return head + Text(" +\(names.count - 1)").foregroundStyle(.secondary)
            }
        }
        if let s = snippet, !s.isEmpty {
            return highlightedText(from: s)
        }
        return Text(item.preview ?? "")
    }

    /// 完整文件名显示，若搜索词恰好命中文件名则加粗，否则返回纯文本。
    /// 高亮词从 snippet 的 STX/ETX 标记里提取，取最长的那个避免短子串抢先。
    private func highlightedFileName(_ name: String, from snippet: String?) -> Text {
        var terms: [String] = []
        var rest = (snippet ?? "")[...]
        while let s = rest.range(of: "\u{02}") {
            let after = rest[s.upperBound...]
            if let e = after.range(of: "\u{03}") {
                terms.append(String(after[..<e.lowerBound]))
                rest = after[e.upperBound...]
            } else { break }
        }
        guard let term = terms.max(by: { $0.count < $1.count }),
              !term.isEmpty,
              let range = name.range(of: term, options: .caseInsensitive) else {
            return Text(name)
        }
        return Text(String(name[..<range.lowerBound]))
            + Text(String(name[range])).bold()
            + Text(String(name[range.upperBound...]))
    }

    private func highlightedText(from snippet: String) -> Text {
        // snippet 形如 "abc \u{02}match\u{03} def \u{02}more\u{03} ghi"
        var result = Text("")
        var rest = snippet[...]
        while let startRange = rest.range(of: "\u{02}") {
            let beforeStart = rest[..<startRange.lowerBound]
            result = result + Text(String(beforeStart))
            let afterStart = rest[startRange.upperBound...]
            if let endRange = afterStart.range(of: "\u{03}") {
                let matched = afterStart[..<endRange.lowerBound]
                result = result + Text(String(matched)).bold()
                rest = afterStart[endRange.upperBound...]
            } else {
                // 没找到收尾 marker——把剩下的全当 plain（防御性，不应发生）
                result = result + Text(String(afterStart))
                rest = ""[...]
                break
            }
        }
        if !rest.isEmpty {
            result = result + Text(String(rest))
        }
        return result
    }

    private func humanSize(_ size: Int64) -> String {
        let kb = Double(size) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

import Foundation
import Observation
import DuoPasteCore
import DuoPasteSync

/// SwiftUI 视图与底层 Database/CaptureService 的桥接。
/// 持有当前搜索字符串、结果列表和高亮行号；提供 refresh / paste / 监听捕获更新等动作。
@MainActor
@Observable
final class AppState {
    var query: String = ""
    var results: [Item] = []
    /// `id → snippet`（含 STX/ETX 高亮标记）。仅 query 非空 + FTS 命中时有内容。
    /// SearchView ItemRow 用 `snippet(for:)` 拿；为 nil 时 fallback 到 item.preview。
    var snippets: [String: String] = [:]
    /// 按选择顺序追加的选中 id 列表。空 = 没显式选中(currentItem 取 results.first 兜底)。
    /// 单选 = 长度 1。多选 = 长度 N,顺序就是 paste 时的合并顺序——cmd+点 append 到末尾,
    /// shift+点按 results 列表顺序整段替换(不按点击顺序)
    var selectedIDs: [String] = []
    /// shift+点的 range 锚点。普通单击 / 箭头导航 / cmd+点 → 更新到当前;
    /// shift+点 → 不动 anchor,只改 selectedIDs(Finder 行为)。没 anchor 时 shift+点退化单选
    var anchorID: String?
    var lastError: String?
    /// 当前搜索源——决定顶部 banner 显示什么。
    var searchMode: SearchProvider.Mode = .local
    /// 当前 query 条件下匹配的真实总数（不受 list limit 截断）。UI counter 显示这个。
    /// - 空 query → 库（或 union 后）里全部条数
    /// - 有 query → FTS 命中总数
    var totalCount: Int = 0
    /// 按 kind 分桶的命中数（忽略 selectedKinds 自身——chip 上的数字含义是"如果只选这个
    /// kind 会有多少"，跟当前已勾选 chip 集合无关）。UI 端 KindChip 用来挂 "图片 (19)"。
    var kindCounts: [ItemKind: Int] = [:]
    /// 按 FileSubKind 分桶的命中数(.file kind 细分:视频/PDF/音频/图片文件)。
    /// 跟 kindCounts 同语义忽略 selectedFileSubKinds 自身,给 chip 数字用
    var fileSubKindCounts: [FileSubKind: Int] = [:]
    /// 类型筛选(base kind)。空集 = 全部不过滤;非空 + selectedFileSubKinds 走 OR 关系
    /// (SearchQuery.kinds OR SearchQuery.fileSubKinds)
    var selectedKinds: Set<ItemKind> = []
    /// `.file` kind 的虚拟 sub-kind 筛选(视频/PDF/音频/图片文件)。空集 = 不带 sub
    /// 过滤;非空跟 selectedKinds OR 起作用
    var selectedFileSubKinds: Set<FileSubKind> = []
    /// 时间窗筛选。`.all` = 不带 fromNs；其他换算成 SearchQuery.fromNs
    var timeRange: TimeRange = .all
    /// 仅显示已置顶。SearchQuery.pinnedOnly → SQL `pinned = 1`
    var pinnedOnly: Bool = false
    /// 临时一次性提示（lazy blob 部分失败等场景），3s 自动清掉。
    /// 不持久化；SearchView 顶部以 caption 形态短暂显示
    var recentNotice: String?
    /// owner-routed pin command 尚未从 canonical owner replay 回来的 item。
    /// 卡片显示“等待同步”；daemon 重启后从 v13 pin_operation 表恢复。
    var pendingPinItemIDs: Set<String> = []

    // MARK: - slash 补全菜单状态
    /// 搜索框输入 `/xxx` 时弹的补全菜单是否显示。SearchView 监听 query 变化时按当前 token
    /// 是否以 `/` 开头来 set，SearchPanelController.installKeyMonitor 据此把 ↑↓/Enter/Esc
    /// 路由到补全菜单而非卡片导航
    var completionMenuVisible: Bool = false
    /// 补全菜单高亮项的 index。↑↓ 改它
    var completionHighlight: Int = 0
    /// 补全候选列表。SearchView .onChange(query) 时刷
    var completionCandidates: [(display: String, qualifier: QueryQualifier)] = []

    /// 已激活的 slash qualifier —— 搜索框左侧以 pill chip 形态渲染(QualifierChip),
    /// 每个带 ✕ 按钮可点删。SearchView onChange(query) 监听到空格后的合法 /xxx token
    /// 时自动抽进来；用户 Enter 选补全候选也是 append 到这里。
    ///
    /// 跟 query: String 是两条独立 state ——
    /// - query 装搜索文本 + 末尾未闭合的 /xxx(让补全菜单匹配)
    /// - activeQualifiers 装已成型的 chip qualifier
    /// refresh() 时两者取并集传给 SearchQuery。
    /// chip selectedKinds / selectedFileSubKinds 跟 activeQualifiers 也是 OR 并集——
    /// 用户点 PDF chip 跟 /pdf 选补全是等价的两条入口
    var activeQualifiers: [QueryQualifier] = []

    /// 时间窗选项。换算成 SearchQuery.fromNs（toNs 始终 nil = 不卡上界）。
    /// 注：用 wall-clock 算窗口起点，时钟偏移大时窗口范围会跟实际感受偏离——
    /// 但 mirror 端 ingested_at_ns 已对齐 primary，主要影响是 own-origin item 在
    /// client 上的"24h 窗"边界，秒级偏差不影响心智
    enum TimeRange: String, CaseIterable, Identifiable, Sendable {
        case all
        case day
        case week
        case month

        public var id: String { rawValue }

        func fromNs(now: Date = Date()) -> Int64? {
            let secondsAgo: TimeInterval
            switch self {
            case .all: return nil
            case .day:   secondsAgo = 24 * 3600
            case .week:  secondsAgo = 7 * 24 * 3600
            case .month: secondsAgo = 30 * 24 * 3600
            }
            return Int64((now.timeIntervalSince1970 - secondsAgo) * 1_000_000_000)
        }

        var label: String {
            switch self {
            case .all:   "全部时间"
            case .day:   "最近 24 小时"
            case .week:  "最近 7 天"
            case .month: "最近 30 天"
            }
        }
    }

    /// 任意筛选维度变化都要触发 SearchView .task(id:) 重新发请求。
    /// 拼成一个紧凑字符串而非 Hashable struct——避免给 ItemKind / TimeRange 加 Hashable
    /// 约束链（其实都已经满足，但用 String 也省去 SwiftUI Equatable 比较的实例化）
    var filterID: String {
        let kindsStr = selectedKinds.map { $0.rawValue }.sorted().joined(separator: ",")
        let subsStr = selectedFileSubKinds.map { $0.rawValue }.sorted().joined(separator: ",")
        // activeQualifiers 进 filterID:string 化保留顺序,变化触发 .task(id:) 重 fetch
        let qualsStr = activeQualifiers.map { qualifierKey($0) }.joined(separator: ",")
        return "\(query)\u{1F}\(timeRange.rawValue)\u{1F}\(kindsStr)\u{1F}\(subsStr)\u{1F}\(qualsStr)\u{1F}\(pinnedOnly ? "1" : "0")"
    }

    /// QueryQualifier 的 string key,filterID 用
    private func qualifierKey(_ q: QueryQualifier) -> String {
        switch q {
        case .kind(let k): return "k:\(k.rawValue)"
        case .fileSubKind(let s): return "s:\(s.rawValue)"
        case .textSuffix(let s): return "x:\(s)"
        case .imageMerged: return "im"
        }
    }

    /// chip kind 高亮判定：chip 自身 selectedKinds 选中，**或** activeQualifiers 里出现
    /// 该 kind 的 slash qualifier 都算高亮（[图片] chip 同时响应 `.imageMerged`）
    func isKindActive(_ k: ItemKind) -> Bool {
        if selectedKinds.contains(k) { return true }
        for q in activeQualifiers {
            if case .kind(let kk) = q, kk == k { return true }
            if k == .image, case .imageMerged = q { return true }
        }
        return false
    }

    /// chip sub-kind 高亮判定。imageFile sub-kind 同时响应 `.imageMerged`（用户想精准筛
    /// 文件路径图片仍然要显式 `/imagefile`）
    func isFileSubKindActive(_ sub: FileSubKind) -> Bool {
        if selectedFileSubKinds.contains(sub) { return true }
        for q in activeQualifiers {
            if case .fileSubKind(let ss) = q, ss == sub { return true }
            if sub == .imageFile, case .imageMerged = q { return true }
        }
        return false
    }

    /// [图片] chip toggle：合并语义同时操作 .image + .imageFile 两个 Set，让 SQL 端通过
    /// kinds OR fileSubKinds 拿到两种存储路径
    func toggleImageChip() {
        let active = selectedKinds.contains(.image) || selectedFileSubKinds.contains(.imageFile)
        if active {
            selectedKinds.remove(.image)
            selectedFileSubKinds.remove(.imageFile)
        } else {
            selectedKinds.insert(.image)
            selectedFileSubKinds.insert(.imageFile)
        }
    }

    /// [图片] chip 计数 = 原生剪贴板图片 + 文件路径图片之和
    var imageMergedCount: Int {
        (kindCounts[.image] ?? 0) + (fileSubKindCounts[.imageFile] ?? 0)
    }

    /// ✕ 清除按钮调用：同时清 chip selection + activeQualifiers + 剥 query 里 slash token,
    /// 让"清除筛选"一键到位
    func clearAllFilters() {
        selectedKinds.removeAll()
        selectedFileSubKinds.removeAll()
        activeQualifiers.removeAll()
        // query 里末尾未闭合的 / token 也清掉（用户输了 "/pd" 没选补全就点 ✕，残留没意义）
        // 先 extract 然后 remaining 就是清干净后的状态
        let (_, remaining) = QueryParser.extractCompleted(query)
        // remaining 可能还含未闭合的 /xxx,继续 split 把开头 / 的 token 都剔
        let cleaned = remaining
            .split(separator: " ", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("/") }
            .joined(separator: " ")
        if cleaned != query {
            query = cleaned
        }
    }

    /// 接受补全 —— 把 query 末尾未闭合的 /xxx token 剥掉,候选 qualifier 加进 activeQualifiers。
    /// 不再往 query 字符串里塞 alias 字面量(老姿态),让搜索框只装"搜索文本",chip 体现 qualifier。
    /// SearchPanelController 在 completionMenuVisible 时把 Enter 路由到这里
    func acceptCompletion(at index: Int? = nil) {
        let idx = index ?? completionHighlight
        guard idx < completionCandidates.count else { return }
        let candidate = completionCandidates[idx]
        // 剥掉末尾 /xxx token —— 找最后一个空格,后面那段就是末尾 token
        if let lastSpace = query.lastIndex(of: " ") {
            query = String(query[...lastSpace])
        } else {
            query = ""
        }
        // 加进 activeQualifiers(去重)
        if !activeQualifiers.contains(candidate.qualifier) {
            activeQualifiers.append(candidate.qualifier)
        }
        completionMenuVisible = false
        completionCandidates = []
        completionHighlight = 0
    }

    /// 补全菜单 ↑↓ 移动高亮项
    func moveCompletionHighlight(by delta: Int) {
        guard !completionCandidates.isEmpty else { return }
        let n = completionCandidates.count
        completionHighlight = ((completionHighlight + delta) % n + n) % n
    }

    /// 关闭补全菜单（Esc 路径）
    func dismissCompletion() {
        completionMenuVisible = false
        completionCandidates = []
        completionHighlight = 0
    }

    /// Backspace 在 query 为空 + activeQualifiers 非空时,弹掉最后一个 chip。
    /// SearchPanelController 在 keyCode=51 拦截路由
    func popLastQualifier() {
        guard !activeQualifiers.isEmpty else { return }
        activeQualifiers.removeLast()
    }

    /// 点 chip ✕ 删特定 qualifier
    func removeQualifier(_ q: QueryQualifier) {
        activeQualifiers.removeAll { $0 == q }
    }
    /// 键盘导航触发滚动用的脉冲计数；每次箭头导航 +1，触发 SearchView 滚动到选中项。
    /// 鼠标点击只改 selectedIDs 不动这个，避免不必要的滚动。
    var scrollPulse: Int = 0
    /// 面板每次显示的脉冲计数。SearchPanelController.show() 每次 +1。
    /// SearchView 用 .onChange 监听：把 TextField 焦点抢回来 + 立即 kick 一次 refresh。
    /// 原因：NSPanel 被复用（orderOut 不销毁 hosting view），onAppear / .task(id:query)
    /// 在 reshow 时不会再 fire，焦点会丢、stale results 不会刷新。
    var openPulse: Int = 0
    /// 用户点过卡 / 空白把 input 摘焦点后再按字母键时,keyMonitor 拦下首字符吃进
    /// query 并 bump 这个 pulse,让 SearchView 把 TextField 焦点抢回来。后续字符
    /// 走正常 TextField 输入路径
    var inputFocusPulse: Int = 0
    /// mesh-fetch-missing / 「补齐缺失 blob」拉回字节后 bump，让 SearchView 卡片 .task
    /// 重 fire 走 decode 路径（光清 ImageThumbnailCache.invalidateAll 不够——
    /// .task(id: cacheKey) 因为 sha 不变不会自动 re-fire，要把 pulse 拼进 id）
    var blobInventoryPulse: Int = 0
    /// PullWorker 上一轮探测到的 primary 时钟偏移（毫秒，signed）。
    /// nil = 还没探测过 / 未启用 pull。banner 阈值由 `clockSkewWarnMs` 决定，
    /// AppState 不做阈值判断，只透传给 SearchView 显示。
    var clockSkewMs: Int64?
    /// 触发 banner 的偏移阈值（毫秒）。跟 PullWorker.Config.clockSkewWarnMs 保持一致。
    /// 这里冗余存一份是为了让 UI 不依赖 sync 模块的内部 const。
    var clockSkewWarnMs: Int64 = 30_000
    /// 最近一次 capture 被跳过的提示（超过 CaptureLimits）。
    /// 5 分钟内有值 → SearchView 顶部黄色 banner；用户能手动 ✕ 关闭立即清掉。
    /// 不持久化——重启就清，是 "刚才有点东西没存下来" 的实时提示。
    var recentSkip: SkipNotice?
    /// 当前进程内的临时捕获暂停。故意不写配置：daemon 重启即恢复，避免永久漏记。
    var capturePause: CapturePause?

    /// blob 懒拉状态。`.fetching` 时 panel 顶部 spinner overlay；
    /// `.failed` 时 banner 显示错误文案 + 用户 Esc 或 Enter 重试
    var pasteProgress: PasteProgress = .idle

    /// macOS Accessibility (AXIsProcessTrusted) 权限是否已授予。
    /// 启动时 AppDelegate 抓一次刷进来,SettingsView 显示状态 + "打开系统设置"按钮。
    /// false 时 PasteInjector.injectCmdV graceful degradation:pasteboard 已写,用户
    /// 自己切回去 Cmd+V 仍能粘——**不阻塞** paste 主路径。Settings 用户授权完后没
    /// 实时回调,需要重新启动 daemon 或手动调 refreshAccessibilityTrusted() 才会刷
    var accessibilityTrusted: Bool = true

    /// Quick Look 风格的空格预览开关。true 时由 SearchPanelController 创建/显示独立
    /// 浮窗(PreviewPanelController)挂在搜索 panel 上方;内容跟随 currentItem 实时
    /// 刷新(箭头导航能切换被预览的项)。
    /// 由 SearchPanelController 的 NSEvent monitor 在空格键路径上 toggle;panel
    /// hide / 复用打开都会复位成 false 避免下次打开还残留预览态。
    var previewShown: Bool = false

    /// SearchView 上报的当前选中卡片在 SwiftUI .global 坐标空间(top-left)的 frame。
    /// PreviewPanelController 用它换算屏幕坐标决定浮窗水平居中位置 + 跟随箭头切换。
    /// 用结构体而非 Optional——选中态保证有 currentItem,frame=.zero 用作 "还没测量" 哨兵
    var selectedCardWindowRect: CGRect = .zero

    enum PasteProgress: Equatable, Sendable {
        case idle
        case fetching(itemID: String, sizeHint: Int64?)  // sizeHint=blobSize 可知时让 UI 显示进度
        case failed(reason: String)
    }

    let deps: AppDependencies
    @ObservationIgnored private var capturePolicy: CapturePolicy
    @ObservationIgnored private var capturePauseExpiryTask: Task<Void, Never>?
    /// AppDelegate 注入，用于同步菜单栏图标 / 状态菜单。
    @ObservationIgnored var onCapturePauseChanged: ((CapturePause?) -> Void)?
    /// 非 owner Mac 新建 pin operation 后立即唤醒对应 mesh worker（生产由 AppDelegate 注入）。
    @ObservationIgnored var onPinOperationQueued: (() -> Void)?

    /// PR cloudy-mirroring-walnut PR 3：optimized storage_mode 下 UI 路径（缩略图 /
    /// 空格预览）触发按需 lazy GET /blob/<sha>。由 AppDelegate.setupPasteBlobFetcher 设置；
    /// nil = 没配 peer / shared-secret 加载失败，UI 缺 blob 时显占位即可。
    /// 跟 AppDelegate.pasteBlobFetcher 同一份引用——paste 路径 + UI 路径共用一个 fetcher
    /// 让 keep-alive 连接池命中率高
    ///
    /// **生命周期硬契约**: daemon 单 instance,AppDelegate 启动期设置一次。
    /// `ItemCard.==` 不比较 fetcher 引用,依赖此契约——任何未来引入的 hot reload
    /// 路径(config 在线 reload / secret 轮换 rebuild)必须同步更新 ItemCard equality,
    /// 否则 fetcher 换实例后 cell 仍认为 equal,thumbnail 不会重 load
    var pasteBlobFetcher: (any BlobFetcher)?

    /// SmartTransport 当前每个 peer 的决策快照——SettingsView 订阅展示。
    /// MeshSupervisor 启动时 + 每次 reconcileTransports 完后 push 进来，时间戳让 UI 能算
    /// "上次刷新于 N 秒前"
    struct TransportSnapshot: Sendable, Equatable, Identifiable {
        let id: Int           // peerIndex
        let configuredHost: String
        let chosenHost: String
        let chosenPort: Int?
        let learnedPonteHost: String?
        let manualPullURL: String?
        let kind: Kind        // .ponte / .tailscale —— 给 UI 上 chip 颜色用
        /// host → RTT,>= 0 = reachable,-1 = probe 失败。初始来自 SmartTransport.discover
        /// 的所有 candidate;runtime 由 PullWorker /health tick 通过 `updateChosenHostRtt`
        /// 覆盖 chosenHost 一条让 UI 反映真实健康度。其他 candidate 行保持 discover 那次的
        /// 快照(诚实展示——非 chosen 行 runtime 没在探,只能等下次 reconcile)
        var httpRttMs: [String: Int64]

        enum Kind: Sendable { case ponte, tailscale }

        init(decision: SmartTransport.PeerDecision) {
            self.id = decision.peerIndex
            self.configuredHost = decision.configuredURL.host ?? "?"
            self.chosenHost = decision.chosenPullURL.host ?? "?"
            self.chosenPort = decision.chosenPullURL.port
            self.learnedPonteHost = decision.learnedPonteHost
            self.manualPullURL = decision.manualPullURL?.absoluteString
            self.kind = decision.chosenWSKind == .urlSession ? .ponte : .tailscale
            var rtts: [String: Int64] = [:]
            for (url, ms) in decision.httpRttMs {
                if let h = url.host { rtts[h] = ms }
            }
            self.httpRttMs = rtts
        }
    }

    /// 当前 transport 决策快照列表 + 上次更新时间。MeshSupervisor 注入回调写这里
    var transports: [TransportSnapshot] = []
    var transportsUpdatedAt: Date? = nil

    /// 由 AppDelegate 在 MeshSupervisor 初始化 / reconcile 完成时调(main actor)
    func setTransports(_ decisions: [SmartTransport.PeerDecision]) {
        self.transports = decisions.map(TransportSnapshot.init)
        self.transportsUpdatedAt = Date()
    }

    /// 由 PullWorker /health tick 完成后通过 PeerBuilder.onHealthProbed 回调过来。
    /// 只覆盖该 peer 当前 chosenHost 对应的 RTT 条目,其他 candidate 行不动——非 chosen
    /// runtime 没在探,改了就是说谎。peerIndex 越界 silent ignore(reconcile 中途的临时态)。
    /// 同时刷 transportsUpdatedAt 让 UI"上次决策刷新 N 秒前"也跟 runtime 健康同步,用户
    /// 能直观看到这一行确实是新的
    func updateChosenHostRtt(peerIndex: Int, rttMs: Int64) {
        guard transports.indices.contains(peerIndex) else { return }
        var snap = transports[peerIndex]
        snap.httpRttMs[snap.chosenHost] = rttMs
        transports[peerIndex] = snap
        transportsUpdatedAt = Date()
    }

    /// 单次跳过的提示。`bytes` / `limit` 单位字节，UI 端 humanize。`kind` 决定文案。
    struct SkipNotice: Equatable, Sendable {
        enum Kind: Sendable { case text, blob }
        let kind: Kind
        let bytes: Int
        let limit: Int
        let occurredAt: Date
    }

    /// 由 AppDelegate.handleCapture 在拿到 `.skippedTooLarge` outcome 时调用。
    /// 副作用：5 分钟后自动清掉（如果还没被新的 skip 覆盖 / 用户没手动 ✕）——
    /// 否则 SwiftUI 不会自己重新求值 `Date().timeIntervalSince() < 300`，banner 永驻。
    func recordSkip(kind: SkipNotice.Kind, bytes: Int, limit: Int) {
        let notice = SkipNotice(kind: kind, bytes: bytes, limit: limit, occurredAt: Date())
        self.recentSkip = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            // 仅当 recentSkip 仍是本次塞进去的那条时才清；中间被新 skip 覆盖或被
            // dismissSkip 清掉 → 不该再动
            if self?.recentSkip == notice {
                self?.recentSkip = nil
            }
        }
    }

    func dismissSkip() {
        self.recentSkip = nil
    }

    // MARK: - Capture privacy / pause

    func updateExcludedBundleIDs(_ bundleIDs: [String]) {
        capturePolicy = CapturePolicy(excludedBundleIDs: bundleIDs)
    }

    /// watcher 的 pre-extraction gate 与 AppDelegate 的 defense-in-depth 共用同一决策。
    func captureDecision(
        sourceAppBundleID: String?,
        now: Date = Date()
    ) -> CapturePolicy.Decision {
        expireCapturePauseIfNeeded(now: now)
        return capturePolicy.decision(
            sourceAppBundleID: sourceAppBundleID,
            pause: capturePause,
            now: now
        )
    }

    func shouldCapture(sourceAppBundleID: String?, now: Date = Date()) -> Bool {
        captureDecision(sourceAppBundleID: sourceAppBundleID, now: now) == .allow
    }

    func activeCapturePause(now: Date = Date()) -> CapturePause? {
        expireCapturePauseIfNeeded(now: now)
        return capturePause
    }

    func pauseCapture(for duration: TimeInterval, now: Date = Date()) {
        guard duration > 0 else {
            resumeCapture()
            return
        }
        setCapturePause(.until(now.addingTimeInterval(duration)), now: now)
    }

    func pauseCaptureUntilResumed() {
        setCapturePause(.untilResumed)
    }

    func resumeCapture() {
        capturePauseExpiryTask?.cancel()
        capturePauseExpiryTask = nil
        guard capturePause != nil else { return }
        capturePause = nil
        onCapturePauseChanged?(nil)
    }

    private func setCapturePause(_ pause: CapturePause, now: Date = Date()) {
        capturePauseExpiryTask?.cancel()
        capturePauseExpiryTask = nil
        capturePause = pause
        onCapturePauseChanged?(pause)

        guard let deadline = pause.deadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now))
        let nanoseconds = UInt64(min(delay, TimeInterval(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        capturePauseExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, self?.capturePause == pause else { return }
            self?.resumeCapture()
        }
    }

    private func expireCapturePauseIfNeeded(now: Date) {
        guard let pause = capturePause, !pause.isActive(at: now) else { return }
        resumeCapture()
    }

    /// owner-routed pin toggle。writer tx 内原子读取/翻转：own-origin 直接 canonical apply，
    /// mirror 行只乐观显示并持久化 operation，PullWorker 定向投递 owner；重试按 UUID 幂等。
    func togglePin(_ item: Item) {
        let id = item.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (_, result) = try await self.deps.database.togglePinIntent(
                    id: id,
                    operationID: UUID().uuidString,
                    selfDeviceID: self.deps.deviceID,
                    now: Clock.nowNs()
                )
                switch result {
                case .applied(_, let newIngest, let duplicate):
                    if !duplicate {
                        let broadcaster = self.deps.wsBroadcaster
                        let deviceID = self.deps.deviceID
                        Task {
                            await broadcaster.broadcastCursorAdvanced(
                                deviceID: deviceID,
                                latestIngestedAtNs: newIngest
                            )
                        }
                    }
                case .pending:
                    self.onPinOperationQueued?()
                }
                await self.refresh()
            } catch BumpError.notFound {
                // 行已被硬删 / 不存在:本机 UI 跟 DB 失同步,refresh 一次让卡片消失
                await self.refresh()
            } catch BumpError.deleted {
                // 行已 tombstone(常见:iOS DELETE /item 已落库但本机 onItemMutated→refresh 还没跑):
                // 同上 refresh 强制对齐,避免列表残留显示已删行
                await self.refresh()
            } catch {
                // 走 recentNotice banner——SearchView 顶部 caption 形态展示 3s 自动消失。
                // 不写 lastError 是因为 SearchView 只在 empty state 渲染 lastError(results.isEmpty),
                // 列表非空时 pin 失败完全没 surface + 下次 keystroke refresh() 自动清掉
                self.postNotice("pin 失败: \(error)")
            }
        }
    }

    /// Mac UI 删除入口(plan hashed-allen §E):⌘Backspace / contextMenu "删除"调用。
    /// 复用 togglePin 的 broadcaster fire-and-forget pattern:softDelete cascade
    /// 删 fold group + 多 sibling 取 max(ingested) 喂 broadcaster + refresh + 3s banner。
    ///
    /// 不弹二次确认 alert(剪贴板心智下删除高频);误删要 undo 走未来的 admin-undelete CLI。
    ///
    /// **多选**:转发到 [deleteItems];单 contextMenu 的"删除"按钮永远只传单条
    /// (跟 Finder 右键单张文件不改多选心智一致,见 SearchView contextMenu 注释)
    func deleteItem(_ item: Item) {
        deleteItems([item])
    }

    /// 多选删除:⌘Backspace 从 SearchPanelController 走这里,传整个 selectedItems。
    /// 对每个 id 跑 cascade,合并 max(ingested) 一次喂 broadcaster + 单次 refresh +
    /// 累加 banner 总数。
    ///
    /// 错误处理:逐条独立 try/catch——某条 alreadyDeleted/notFound 不该让其他 id
    /// 失败。其他错误累加到 banner;成功条数也累加,让用户看到"删了 N 条(M 条失败)"
    func deleteItems(_ items: [Item]) {
        guard !items.isEmpty else { return }
        let ids = items.map(\.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var deletedCount = 0
            var maxIngest: Int64 = 0
            var failedCount = 0
            for id in ids {
                do {
                    let results = try await self.deps.database.softDelete(
                        id: id,
                        now: Clock.nowNs()
                    )
                    deletedCount += results.count
                    if let m = results.map(\.ingestedAtNs).max() {
                        maxIngest = Swift.max(maxIngest, m)
                    }
                } catch BumpError.alreadyDeleted {
                    // 幂等:行已 tombstone(可能 cascade 中前一条 id 把它带删了 / 重复 ⌘Backspace race)
                    continue
                } catch BumpError.notFound {
                    // 行已不存在,继续处理剩余 ids
                    continue
                } catch {
                    failedCount += 1
                    FileHandle.standardError.write(Data(
                        "AppState.deleteItems: id=\(id) failed: \(error)\n".utf8
                    ))
                }
            }
            if maxIngest > 0 {
                let broadcaster = self.deps.wsBroadcaster
                let deviceID = self.deps.deviceID
                Task {
                    await broadcaster.broadcastCursorAdvanced(
                        deviceID: deviceID,
                        latestIngestedAtNs: maxIngest
                    )
                }
            }
            await self.refresh()
            // 友好 banner:不暴露 raw error type 给用户。明细写 stderr 便于排查
            switch (deletedCount, failedCount) {
            case (0, 0):
                break  // 全部幂等/notFound,UI 已 refresh 对齐就好
            case (let d, 0):
                self.postNotice("已删除 \(d) 条")
            case (0, let f):
                self.postNotice("删除失败(\(f) 项),详见日志")
            case (let d, let f):
                self.postNotice("已删除 \(d) 条 · \(f) 项失败")
            }
        }
    }

    /// 一次性 3s notice。同一文案在窗口内重复触发不会延长——只在过期后才能换新内容。
    /// **任何**写 recentNotice 的入口都必须走这条路,直接赋字段会绕过 3s timer 让 banner
    /// 永久残留(踩过坑:pasteBack 跨 kind fallback 写 banner 后 panel 复用 state 让用户
    /// 重开 panel 仍看见旧提示)
    func postNotice(_ text: String) {
        self.recentNotice = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 只有还是同一条 notice 时才清——中间被新 notice 覆盖就不动
            if self?.recentNotice == text {
                self?.recentNotice = nil
            }
        }
    }

    init(deps: AppDependencies) {
        self.deps = deps
        self.capturePolicy = CapturePolicy(excludedBundleIDs: deps.config.capture.excludedBundleIDs)
        // 同步预填本地最新 listLimit 条，避免 panel 首次打开 SwiftUI 第一帧渲染
        // 时 results=[] → 看到 "0 条" 闪一下。Panel 触发 .task 后会异步 refresh
        // 一次（可能从 remote 拿更新），把这里的结果替换/扩展。
        // 用本地不走 searchProvider，绕开 remote 慢路径——0 ms 同步可拿到结果。
        let initial = (try? deps.searchAPI.search(SearchQuery(limit: Self.listLimit))) ?? []
        self.results = initial
        if let firstID = initial.first?.id {
            self.selectedIDs = [firstID]
            self.anchorID = firstID
        }
        // 同步 init 阶段 mirror union 还没接入（searchProvider 没跑），用本机 item 计数作初值——
        // panel 打开后第一次 refresh() 会替换成正确的 union/mirror 总数。
        self.totalCount = (try? deps.searchAPI.count(SearchQuery())) ?? initial.count
        self.kindCounts = (try? deps.searchAPI.countByKind(SearchQuery())) ?? [:]
        self.fileSubKindCounts = (try? deps.searchAPI.countByFileSubKind(SearchQuery())) ?? [:]
        // 后台预热 image thumbnail——daemon 重启后 ImageThumbnailCache 空,首次打开 panel
        // 时每张 image 卡 .task 命中 miss 会先显占位再异步 replace。这里 fire-and-forget
        // 让 decode 提前跑,常规场景(daemon 启动后秒级以上才开 panel)cache 已 hot
        ImageThumbnailCache.shared.prefetch(
            items: initial,
            blobs: deps.blobs,
            fetcher: pasteBlobFetcher,
            storageMode: deps.config.mesh.storageMode
        )
    }

    /// 列表一次最多返回多少条。比 totalCount 小时只是 UI 截断,无业务语义——稀疏类型
    /// (比如图片只有 19 条,文本却几百条)必须 limit 够大才能滚到底找到。
    /// **200 不是 1000**:Instruments 验证 1000 时 LazyHStack/LazyHVStack reconciliation
    /// (LazyLayoutViewCache + GraphHost.flushTransactions + AG::Graph::UpdateState)
    /// 在 results 替换时占用 main thread 100-158ms,触发 expensive app update hitch。
    /// 砍到 200 让 lazy 容器 diff 成本压一档,剪贴板搜索场景"看最近 + top 命中"几乎
    /// 完全覆盖。totalCount 仍走独立 SQL COUNT(query)不受 limit 影响,chip 数仍真实
    static let listLimit = 200

    /// 上一次 refresh 起的 detached fetch Task。新一轮 refresh 开头 cancel 它,
    /// 防止快速连打 query 时 N 个 detached SQL read 堆在 GRDB pool reader 队列。
    /// @ObservationIgnored:这是内部并发状态,UI 不依赖也不应触发 SwiftUI 重渲
    @ObservationIgnored private var currentSearchTask: Task<SearchProvider.Outcome, Error>?

    /// 当前应该粘贴的项：优先选中项(取 selectedIDs 末位 = 最后一次 cmd+点 / 单击的那个),
    /// 否则取列表首项兜底。**注**:多项 paste 用 `selectedItems`,这里只是单项 fallback
    var currentItem: Item? {
        if let last = selectedIDs.last, let it = results.first(where: { $0.id == last }) {
            return it
        }
        return results.first
    }

    /// 多项 paste 入口。按 selectedIDs 顺序拿 Item;被 filter chip 过滤掉的 id 自动跳过。
    /// 空数组 = 没显式选中,调用方应该 fallback 到 currentItem
    var selectedItems: [Item] {
        selectedIDs.compactMap { id in results.first(where: { $0.id == id }) }
    }

    /// 箭头键导航。任何方向键都重置成单选 + 重置 anchor——多选只走鼠标 cmd/shift+点
    func navigate(by delta: Int) {
        guard !results.isEmpty else { return }
        let curID = selectedIDs.last
        let idx = results.firstIndex(where: { $0.id == curID }) ?? 0
        let next = max(0, min(results.count - 1, idx + delta))
        let id = results[next].id
        selectedIDs = [id]
        anchorID = id
        scrollPulse &+= 1
    }

    func refresh() async {
        // 把 chip selection 跟 activeQualifiers 取并集落到 SearchQuery —— 用户点 PDF chip
        // 跟选 /pdf 补全必须等价。imageMerged 同时贡献到 kinds(.image) + fileSubKinds(.imageFile)
        var kindsUnion = selectedKinds
        var subsUnion = selectedFileSubKinds
        var suffixes: [String] = []
        for qual in activeQualifiers {
            switch qual {
            case .kind(let k):
                kindsUnion.insert(k)
            case .fileSubKind(let s):
                subsUnion.insert(s)
            case .imageMerged:
                kindsUnion.insert(.image)
                subsUnion.insert(.imageFile)
            case .textSuffix(let s):
                suffixes.append(s)
            }
        }
        // query 里可能还有用户尚未确认的末尾 /xxx token（补全菜单显示但未 Enter）—— 走
        // QueryParser.extractCompleted 兜底:把已闭合的 /xxx 也算上,让用户即使不走补全
        // 直接输 "/pdf hello" 也能正确筛
        let (extraQuals, remaining) = QueryParser.extractCompleted(query)
        for qual in extraQuals {
            switch qual {
            case .kind(let k): kindsUnion.insert(k)
            case .fileSubKind(let s): subsUnion.insert(s)
            case .imageMerged: kindsUnion.insert(.image); subsUnion.insert(.imageFile)
            case .textSuffix(let s): suffixes.append(s)
            }
        }
        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = SearchQuery(
            text: trimmed.isEmpty ? nil : trimmed,
            fromNs: timeRange.fromNs(),
            kinds: Array(kindsUnion),
            fileSubKinds: Array(subsUnion),
            textFullSuffixes: suffixes,
            pinnedOnly: pinnedOnly,
            limit: Self.listLimit
        )
        // **E**: 把 SearchProvider.search 整段(4 次同步 SQL + fold + 转 Item array)
        // 搬出 main actor。SearchProvider.search 是 async 但内部全同步——`async`
        // 只为接口稳定保留(见 SearchClient.swift:72-74 注释),实际所有工作在调用者
        // actor 上跑。Task.detached 让这段在后台 thread 执行,main actor 只 await
        // 结果 + 做 setter 赋值。SearchProvider 是 Sendable struct,SearchAPI 内部
        // GRDB pool 是 thread-safe,跨 thread 调用安全。
        //
        // **P1/P2 cancel 协议**:
        // - detached child 不继承父 .task(id:) 的 cancel——父被替换时 detached
        //   仍跑完,`try await task.value` 不会主动抛
        // - cancel 旧 currentSearchTask:防止快速连打堆 N 个 detached read 占满
        //   GRDB reader 池;detached body 入口 checkCancellation 能在 SQL 开始前
        //   早退,SQL 已开始的 cancel 不掉(SQLite 同步调用),但结果会被 .value
        //   throw + Task.isCancelled check 双层拦截不落地
        // - await 后显式 check Task.isCancelled:父 .task(id:) cancel 时 await
        //   不主动抛,这里挡住 stale outcome 写进 self.results 让 UI 闪旧 query
        self.currentSearchTask?.cancel()
        let provider = deps.searchProvider
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await provider.search(q)
        }
        self.currentSearchTask = task
        let outcome: SearchProvider.Outcome
        do {
            outcome = try await task.value
        } catch is CancellationError {
            // detached 内 checkCancellation 早退,或者 .value 在父 cancel 后 throw
            return
        } catch {
            self.lastError = "\(error)"
            return
        }
        // 父 .task(id:) 被 cancel 时 await .value 不抛,这里硬挡 stale 写入
        if Task.isCancelled {
            return
        }
        // **F**: 每个 setter 前 equality guard——内容等价时直接跳过,避免 Observation
        // 框架 didSet wave 触发下游 ForEach diff / chip 重渲。新旧 Item array 在
        // query 没变的高频 refresh(openPulse / onAppear)场景下大概率等价,
        // ItemCard EquatableView 已能跳 body 重算,这里再叠一层让 ForEach enumerate
        // 都不发生
        if self.results != outcome.items {
            self.results = outcome.items
        }
        // refresh 拿到新 results 顺路预热 thumbnail——新 mirror 进来的 image 项
        // 让下次卡进 viewport 时已 cached。已 cached / 黑名单的 sha 自动跳过
        ImageThumbnailCache.shared.prefetch(
            items: outcome.items,
            blobs: deps.blobs,
            fetcher: pasteBlobFetcher,
            storageMode: deps.config.mesh.storageMode
        )
        if self.snippets != outcome.snippets {
            self.snippets = outcome.snippets
        }
        if self.searchMode != outcome.mode {
            self.searchMode = outcome.mode
        }
        if self.totalCount != outcome.totalCount {
            self.totalCount = outcome.totalCount
        }
        if self.kindCounts != outcome.kindCounts {
            self.kindCounts = outcome.kindCounts
        }
        if self.fileSubKindCounts != outcome.fileSubKindCounts {
            self.fileSubKindCounts = outcome.fileSubKindCounts
        }
        if let pending = try? await deps.database.pendingPinItemIDs(),
           self.pendingPinItemIDs != pending {
            self.pendingPinItemIDs = pending
        }
        // 每次 refresh 顺便快照 mesh 时钟偏移——PullWorker 在后台 30s 一次刷新，
        // SearchView banner 用 worst-case（所有 peer 中绝对值最大那个）
        let newSkew = deps.meshStatus.worstClockSkewMs()
        if self.clockSkewMs != newSkew {
            self.clockSkewMs = newSkew
        }
        updateSelection(forItems: outcome.items, queryIsEmpty: trimmed.isEmpty)
        if self.lastError != nil {
            self.lastError = nil
        }
    }

    /// 列表刷新后调整选中行,策略统一 "kept 优先":
    /// - **原选中行至少一个仍在 results 里** → 保留那部分顺序(过滤掉已被删的)
    /// - **原选中行全被过滤掉 / 当前空选** → 退化单选第一项 + 触发滚到顶
    ///
    /// **不分 queryIsEmpty**——原版 query 空时强制 reset 到第一项,导致 panel 已打开时
    /// 新 capture refresh 把用户当前 cmd/shift 多选状态吹掉(user 反馈"选择中有新 copy
    /// 丢失所有状态还滚到最前面")。改成只在 kept 真的空时才 reset
    private func updateSelection(forItems items: [Item], queryIsEmpty: Bool) {
        let available = Set(items.map { $0.id })
        let kept = selectedIDs.filter { available.contains($0) }

        if !kept.isEmpty {
            if kept != selectedIDs { selectedIDs = kept }
            return
        }
        let firstID = items.first?.id
        selectedIDs = firstID.map { [$0] } ?? []
        anchorID = firstID
        if firstID != nil { scrollPulse &+= 1 }
    }
}

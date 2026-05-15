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
    /// 临时一次性提示（pin mirror 行被拒等场景），3s 自动清掉。
    /// 不持久化；SearchView 顶部以 caption 形态短暂显示
    var recentNotice: String?

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
        return "\(query)\u{1F}\(timeRange.rawValue)\u{1F}\(kindsStr)\u{1F}\(subsStr)\u{1F}\(pinnedOnly ? "1" : "0")"
    }
    /// 键盘导航触发滚动用的脉冲计数；每次箭头导航 +1，触发 SearchView 滚动到选中项。
    /// 鼠标点击只改 selectedIDs 不动这个，避免不必要的滚动。
    var scrollPulse: Int = 0
    /// 面板每次显示的脉冲计数。SearchPanelController.show() 每次 +1。
    /// SearchView 用 .onChange 监听：把 TextField 焦点抢回来 + 立即 kick 一次 refresh。
    /// 原因：NSPanel 被复用（orderOut 不销毁 hosting view），onAppear / .task(id:query)
    /// 在 reshow 时不会再 fire，焦点会丢、stale results 不会刷新。
    var openPulse: Int = 0
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

    /// blob 懒拉状态。`.fetching` 时 panel 顶部 spinner overlay；
    /// `.failed` 时 banner 显示错误文案 + 用户 Esc 或 Enter 重试
    var pasteProgress: PasteProgress = .idle

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

    /// 切换 item 的 pinned 状态。仅对 own-origin 行生效；mirror 行（别的机器产生的）
    /// 给个一次性 notice 提示，不抛错。
    ///
    /// 行为细节：
    /// - own-origin + 状态变化 → Database.setPinned writer tx + refresh
    /// - own-origin + 同状态 → no-op（不动 ingested_at_ns 避免无谓 cursor 推进）
    /// - mirror 行（origin ≠ self）→ 显示 notice"只能置顶本机产生的项"，3s 自动消失
    ///
    /// 调用方：SearchPanelController 的 ⌘P key monitor。同步执行：单行 UPDATE +
    /// 一次 MAX 查询，pool.write 在 main actor 上 < 1ms，不卡 UI
    func togglePin(_ item: Item) {
        guard item.originDevice == deps.deviceID else {
            postNotice("只能置顶本机产生的项")
            return
        }
        do {
            let didUpdate = try deps.database.setPinned(
                id: item.id,
                pinned: !item.pinned,
                selfDeviceID: deps.deviceID,
                now: Clock.nowNs()
            )
            if didUpdate {
                Task { await refresh() }
            }
        } catch {
            self.lastError = "pin 失败: \(error)"
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
        ImageThumbnailCache.shared.prefetch(items: initial, blobs: deps.blobs)
    }

    /// 列表一次最多返回多少条。比 totalCount 小时只是 UI 截断，无业务语义——稀疏类型
    /// （比如图片只有 19 条，文本却几百条）必须 limit 够大才能滚到底找到。LazyVStack 渲
    /// 染千行不卡，SQLite 拉千行 row ~10ms 内
    static let listLimit = 1000

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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = SearchQuery(
            text: trimmed.isEmpty ? nil : trimmed,
            fromNs: timeRange.fromNs(),
            kinds: Array(selectedKinds),
            fileSubKinds: Array(selectedFileSubKinds),
            pinnedOnly: pinnedOnly,
            limit: Self.listLimit
        )
        do {
            let outcome = try await deps.searchProvider.search(q)
            self.results = outcome.items
            // refresh 拿到新 results 顺路预热 thumbnail——新 mirror 进来的 image 项
            // 让下次卡进 viewport 时已 cached。已 cached / 黑名单的 sha 自动跳过
            ImageThumbnailCache.shared.prefetch(items: outcome.items, blobs: deps.blobs)
            self.snippets = outcome.snippets
            self.searchMode = outcome.mode
            self.totalCount = outcome.totalCount
            self.kindCounts = outcome.kindCounts
            self.fileSubKindCounts = outcome.fileSubKindCounts
            // 每次 refresh 顺便快照 mesh 时钟偏移——PullWorker 在后台 30s 一次刷新，
            // SearchView banner 用 worst-case（所有 peer 中绝对值最大那个）
            self.clockSkewMs = deps.meshStatus.worstClockSkewMs()
            updateSelection(forItems: outcome.items, queryIsEmpty: trimmed.isEmpty)
            self.lastError = nil
        } catch is CancellationError {
            // 用户在打字，新查询正在替换旧的，正常
        } catch {
            self.lastError = "\(error)"
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

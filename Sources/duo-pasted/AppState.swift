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
    var selectedID: String?
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
    /// 类型筛选。空集 = 全部（不带 WHERE 过滤）；非空 = SearchQuery.kinds IN (...)
    /// chip 行 UI 多选 toggle，状态变化触发 refresh
    var selectedKinds: Set<ItemKind> = []
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
        return "\(query)\u{1F}\(timeRange.rawValue)\u{1F}\(kindsStr)\u{1F}\(pinnedOnly ? "1" : "0")"
    }
    /// 键盘导航触发滚动用的脉冲计数；每次箭头导航 +1，触发 SearchView 滚动到选中项。
    /// 鼠标点击只改 selectedID 不动这个，避免不必要的滚动。
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

    /// 一次性 3s notice。同一文案在窗口内重复触发不会延长——只在过期后才能换新内容
    private func postNotice(_ text: String) {
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
        self.selectedID = initial.first?.id
        // 同步 init 阶段 mirror union 还没接入（searchProvider 没跑），用本机 item 计数作初值——
        // panel 打开后第一次 refresh() 会替换成正确的 union/mirror 总数。
        self.totalCount = (try? deps.searchAPI.count(SearchQuery())) ?? initial.count
        self.kindCounts = (try? deps.searchAPI.countByKind(SearchQuery())) ?? [:]
    }

    /// 列表一次最多返回多少条。比 totalCount 小时只是 UI 截断，无业务语义——稀疏类型
    /// （比如图片只有 19 条，文本却几百条）必须 limit 够大才能滚到底找到。LazyVStack 渲
    /// 染千行不卡，SQLite 拉千行 row ~10ms 内
    static let listLimit = 1000

    /// 当前应该粘贴的项：优先选中项，否则取列表首项。
    var currentItem: Item? {
        if let id = selectedID, let it = results.first(where: { $0.id == id }) {
            return it
        }
        return results.first
    }

    func navigate(by delta: Int) {
        guard !results.isEmpty else { return }
        let idx = results.firstIndex(where: { $0.id == selectedID }) ?? 0
        let next = max(0, min(results.count - 1, idx + delta))
        selectedID = results[next].id
        scrollPulse &+= 1
    }

    func refresh() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = SearchQuery(
            text: trimmed.isEmpty ? nil : trimmed,
            fromNs: timeRange.fromNs(),
            kinds: Array(selectedKinds),
            pinnedOnly: pinnedOnly,
            limit: Self.listLimit
        )
        do {
            let outcome = try await deps.searchProvider.search(q)
            self.results = outcome.items
            self.snippets = outcome.snippets
            self.searchMode = outcome.mode
            self.totalCount = outcome.totalCount
            self.kindCounts = outcome.kindCounts
            // 每次 refresh 顺便快照 mirror 时钟偏移——PullWorker 在后台 30s 一次刷新，
            // SearchView banner 用这个值
            self.clockSkewMs = deps.mirrorStatus.clockSkewMs()
            updateSelection(forItems: outcome.items, queryIsEmpty: trimmed.isEmpty)
            self.lastError = nil
        } catch is CancellationError {
            // 用户在打字，新查询正在替换旧的，正常
        } catch {
            self.lastError = "\(error)"
        }
    }

    /// 列表刷新后调整选中行：
    /// - **query 空**（首次打开 / 清空搜索）→ 强制选第一项（最新捕获），并触发滚回顶部
    /// - **query 非空 + 原选中行仍在结果里** → 保持选中（让"缩小关键词"流不丢焦点）
    /// - **query 非空 + 原选中行不在结果里** → 选第一项
    private func updateSelection(forItems items: [Item], queryIsEmpty: Bool) {
        let newSelection: String?
        if queryIsEmpty {
            newSelection = items.first?.id
        } else if let id = self.selectedID, items.contains(where: { $0.id == id }) {
            newSelection = id  // preserve
        } else {
            newSelection = items.first?.id
        }
        if newSelection != self.selectedID {
            self.selectedID = newSelection
            // selection 跳到非临近行（清空搜索时常见），SearchView 需要重新滚到选中项；
            // scrollPulse 是唯一让它滚动的入口
            if newSelection != nil {
                self.scrollPulse &+= 1
            }
        }
    }
}

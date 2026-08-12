import Foundation
import Observation
import DuoPasteCore

struct HistorySyncStatus: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        case initialSync
        case verifyingExistingCache
        case rebuilding
        case ready
    }

    enum Activity: Sendable, Equatable {
        case idle
        case syncing
        case paused
        case failed
    }

    var mode: Mode = .initialSync
    var activity: Activity = .idle
    var localItemCount: Int = 0
    var sourceTrackedItemCount: Int?
    var serverTotalCount: Int?
    var currentPeer: String?
    var lastSuccessAt: Date?
    var failureMessage: String?

    /// `ready` only means the durable mirror passed a full source-count audit. Any in-flight,
    /// paused, or failed attempt makes the current state non-strict until another pass completes.
    var isStrictlyCaughtUp: Bool {
        mode == .ready && activity == .idle
    }
}

/// iOS full-history SQLite mirror 的 MainActor UI projection。
/// `items` 只保留最近 1000 条供首页渲染；完整 metadata、cursor 与 FTS 都住在
/// `MetadataMirrorStore`。Coordinator/BackgroundPullService 共用同一个 SQLite page apply。
@Observable
@MainActor
final class HistoryStore {
    nonisolated static let displayLimit = 1_000
    nonisolated static let syncPausedDefaultsKey = "metadataSyncPausedByUser"
    private nonisolated let mirror: MetadataMirrorStore?
    private nonisolated let checkpointStore: MetadataMirrorSyncCheckpointStore
    private let mirrorFileExistedAtLaunch: Bool

    init() {
        let existed = FileManager.default.fileExists(atPath: Self.mirrorFile.path)
        self.mirrorFileExistedAtLaunch = existed
        self.mirror = Self.openMirrorOrNil()
        self.checkpointStore = MetadataMirrorSyncCheckpointStore(path: Self.syncCheckpointFile)
    }

    /// 显示用,按 captured_at_ns DESC + pinned-first 排好序的列表。
    private(set) var items: [Item] = []
    /// Full-history completeness is separate from connection status. A partial initial/refill cache
    /// remains searchable, but the UI must keep labeling it as incomplete until strict audit success.
    private(set) var syncStatus = HistorySyncStatus()
    /// 搜索框文本。非空文本或 qualifier 由本机 SQLite FTS/SearchAPI 返回。
    var query: String = ""

    /// 已激活的 slash qualifier —— `HistoryView.filterChipRow` 直接读写本字段(Mail 风格
    /// 独立 chip 行,不走 `.searchable(tokens:)`),跟 query 双轨并存:filter 走两者交集
    /// (qualifier OR 内 + text contains AND)。
    ///
    /// **单一真相源**——之前 View 有一份 `@State Set`,store 有一份 `[QueryQualifier]`,
    /// 通过 onChange 单向同步。坑:`HistoryStore.reset()` 清 store 端,View @State 不会
    /// 收到通知,chip 高亮还在但 filter 已不生效(数据/UI 失配)。改成 Set 直接住在 store,
    /// View 通过 @Observable 路径绑定,reset 自然让 View 重渲。
    ///
    /// **不对称性 caveat**:`query` **仍是** `HistoryView.@State searchText` 持有,store
    /// 里装的是搜索框 mirror(`HistoryView.onChange(searchText)` 同步写,issue #44 后
    /// 不再压在 debounce 后面)。所以 `reset()` 把 `query=""` 但 View `searchText`
    /// 不会清,下次用户敲键 onChange 才同步回来。`reset()` 当前 doc 标"测试/debug 用",
    /// 生产路径没调,所以接受这条不对称——把 searchText 也搬进 store 等于每键热路径
    /// 都过 @Observable 一次,得不偿失
    ///
    /// 内存态,不持久化——重启回零;qualifier 是探索性筛选不是用户长期 preference
    var activeQualifiers: Set<QueryQualifier> = []

    /// 本机 SQLite FTS 返回的最新结果。它和 Mac 直接使用同一个 `SearchAPI` 实现。
    /// **匹配**靠 `q` + `qualifiers` 联合判断是否对得上当前 store.query;
    /// 不一致 → 不用(过期),走 fallback. **qualifier snapshot**(review #48 Minor 1):
    /// 用户取消 chip → `activeQualifiers` 变小 → onChange 250ms debounce 后才发新一轮
    /// /search。这 250ms 窗口内若只比 `q` 命中 cache,`filtered` 会拿 server-收窄过的 items
    /// 再 client-side filter (更宽的 qualifier),等于双重过滤 → 显示比"应该出现"少 → 闪烁。
    /// 把 qualifiers 也存进 cache,dispatch 时 strict 比对让 stale cache 不命中,自然走
    /// contains fallback 直到新一轮 /search 返回
    struct LocalSearchResult: Equatable, Sendable {
        let q: String
        let qualifiers: Set<QueryQualifier>
        let items: [Item]
        let snippets: [String: String]
        let totalCount: Int
    }
    private(set) var lastLocalSearch: LocalSearchResult?

    /// SwiftUI 直接绑这个——过滤 + fold 后的列表。
    /// - 空 query + 空 qualifier → 全列表(本机 fold)
    /// - 非空 query 或 qualifier → 完整 SQLite mirror 上的 SearchAPI 结果
    /// - debounce 尚未返回 → 最近 1000 条 projection 上临时 contains/filter，不阻塞输入
    ///
    /// **Fold 契约定义在 `Item.foldByTextFull`(DuoPasteCore)**——跨 origin 同 text_full
    /// 折一条,winner = max(captured_at_ns),pinned OR 聚合。修 Continuity / ToDesk 把同
    /// 文本镜到两台 Mac 后 iOS 看见两张卡(两个不同 origin_device)而 Mac UI 只一张的不对齐.
    /// 排序契约在本路径单独应用:(pinned DESC, captured_at_ns DESC)——Mac fold 多一层
    /// prefix24h boost,iOS 列表无 query 时不需要;有 query 走本机 SearchAPI 就有了
    ///
    /// **Qualifier 语义**:OR 起来——`/pdf /video` 匹配 (kind=file 且 subkind=pdf) OR
    /// (kind=file 且 subkind=video)。空集合等于不过滤。跟 Mac SearchAPI 契约对齐。
    ///
    /// `HistoryFilterDispatch.ServerSearchContext` 是历史命名；这里把本地结果适配给同一纯
    /// dispatch 函数，网络搜索已经不存在。
    var filtered: [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsDatabaseSearch = !trimmed.isEmpty || !activeQualifiers.isEmpty
        if needsDatabaseSearch,
           let local = lastLocalSearch,
           local.q == trimmed,
           local.qualifiers == activeQualifiers {
            return local.items
        }
        // 实际 dispatch 逻辑住在 DuoPasteCore.HistoryFilterDispatch——纯函数,4 条分支
        // 契约直接在 DuoPasteCoreTests 覆盖,改 dispatch 单测先 fail. 这里只做"把
        // store 里 @Observable 字段转纯数据 + 调 dispatch"的胶水
        let cache = lastLocalSearch.map {
            HistoryFilterDispatch.ServerSearchContext(
                q: $0.q,
                qualifiers: $0.qualifiers,
                items: $0.items
            )
        }
        return HistoryFilterDispatch.dispatch(
            items: items,
            query: query,
            lastServerSearch: cache,
            qualifiers: Array(activeQualifiers)
        )
    }

    /// 250ms debounce 后在 utility thread 跑本地 FTS。响应回来时再次核对 query + qualifier
    /// snapshot，取消/过期结果都不会污染当前 UI。
    func searchLocal(q: String, qualifiers: [QueryQualifier]) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let qualifierSet = Set(qualifiers)
        guard !trimmed.isEmpty || !qualifierSet.isEmpty else {
            lastLocalSearch = nil
            return
        }
        guard let mirror else { return }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try mirror.search(text: trimmed, qualifiers: qualifiers, limit: 500)
            }.value
            try Task.checkCancellation()
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed,
                  activeQualifiers == qualifierSet else { return }
            var patched = result.items.filter { !optimisticallyDeletedIDs.contains($0.id) }
            for index in patched.indices {
                if let desired = pendingPinTargets[patched[index].id] {
                    patched[index].pinned = desired
                }
                if let optimisticNs = optimisticCapturedAtNs[patched[index].id] {
                    patched[index].capturedAtNs = max(patched[index].capturedAtNs, optimisticNs)
                }
            }
            patched.sort(by: Self.iosListOrder)
            lastLocalSearch = LocalSearchResult(
                q: trimmed,
                qualifiers: qualifierSet,
                items: patched,
                snippets: result.snippets,
                totalCount: result.totalCount
            )
        } catch is CancellationError {
            // New keystroke/qualifier superseded this query.
        } catch {
            DebugLog.shared.append("local mirror search failed: \(error)")
        }
    }

    func refreshActiveSearch() async {
        await searchLocal(q: query, qualifiers: Array(activeQualifiers))
    }

    func clearLocalSearch() {
        lastLocalSearch = nil
    }

    // MARK: - 删除失败追踪

    /// 乐观删除状态机——按 id + text_full 双维度记 pending,让 merge() 把 in-flight
    /// /since 带回的同 text_full sibling 屏蔽在 grace 窗口内不入库(防 fold-aware 闪回),
    /// grace 后仍回流的算 resurrected 弹 banner。契约定义 + 单测在 DuoPasteCore.
    private var deleteTracker = OptimisticDeleteTracker()

    /// `merge()` 检测到删除未送达时写,UI 顶部 banner 显示,5s 自动消(或用户点 ✕)。
    /// 这里只展示提示——条目本身已被 /since 重新 insert 回 `items`,无法回滚乐观删除
    /// (内容字段已丢),用户看到提示后自行决定重试或忽略
    private(set) var deleteFailureMessage: String?
    /// iOS 本地乐观 pin 尚未得到 owner canonical 确认的绝对值意图。
    private var pendingPinTargets: [String: Bool] = [:]
    /// 最近页之外的 FTS 命中同样可以被乐观 bump/delete；overlay 不能只依赖 `items`。
    private var optimisticCapturedAtNs: [String: Int64] = [:]
    private var optimisticallyDeletedIDs: Set<String> = []

    func isPinPending(_ id: String) -> Bool { pendingPinTargets[id] != nil }

    func markPinPending(id: String, desiredPinned: Bool) {
        pendingPinTargets[id] = desiredPinned
    }

    func markPinApplied(id: String, desiredPinned: Bool) {
        guard pendingPinTargets[id] == desiredPinned else { return }
        pendingPinTargets.removeValue(forKey: id)
    }

    /// 每页 canonical 行落库后的本地乐观状态对账。由 `MetadataMirrorStore.synchronize`
    /// 的 `onPageApplied` 驱动（前台 pull 与 BGAppRefreshTask 共用同一条路径）。
    ///
    /// **为什么必须有这个 hook**：R2.1 之后 item 行归 SQLite mirror 所有，列表由
    /// `refreshFromMirror()` 从 SQLite 重新投影，原来的 `merge(_:)` 里"把 incoming 并进
    /// 内存数组"那半边确实被取代了——但它同时还承担着三件**没有替代品**的对账工作，
    /// 随着 `merge` 一起变成死代码：
    ///
    /// 1. **删除未送达**：`removeOptimistic` 把 id 放进 `optimisticallyDeletedIDs`，
    ///    `refreshFromMirror` / `searchLocal` 据此把行藏起来。Mac 不可达时 DELETE 被
    ///    swallow（`PeerSyncCoordinator.deleteItemOnServer`），行根本没被 tombstone；
    ///    没有本函数就永远没人把它从集合里拿出来 —— 卡片一直"假装已删"，橙色 banner
    ///    （`HistoryView` 的 `deleteFailureMessage`）永远不出现，重启后条目又无声无息
    ///    地回来了。
    /// 2. **pin 等待同步**：非 owner 的 pin 走 owner-routed command，`/pin` 返回
    ///    `pending`，`markPinApplied` 不会被调用（它只在 `applied` 时调）。CLAUDE.md
    ///    要求"后续 canonical `/since` 行确认目标值再清"——就是这里。否则卡片永久显示
    ///    "等待同步"。
    /// 3. **tombstone 清场**：真 tombstone 回流时清掉三张 overlay 表，避免无界增长。
    ///
    /// `skipIds` 在 mirror 架构下不需要特别处理：grace 窗口内的 sibling 仍在
    /// `optimisticallyDeletedIDs` 里，投影时本来就是隐藏的。
    func reconcileOptimisticState(with incoming: [Item]) {
        guard !incoming.isEmpty else { return }
        let outcome = deleteTracker.observeIncoming(incoming)

        for it in incoming {
            if it.isTombstone {
                // server 真删掉了：乐观态功成身退，overlay 全清
                pendingPinTargets.removeValue(forKey: it.id)
                optimisticCapturedAtNs.removeValue(forKey: it.id)
                optimisticallyDeletedIDs.remove(it.id)
                continue
            }
            // canonical 行已经达到目标值 → owner 的 pin 命令确实回放到了，清"等待同步"
            if let desired = pendingPinTargets[it.id], it.pinned == desired {
                pendingPinTargets.removeValue(forKey: it.id)
            }
        }

        // grace 之后仍以 active 身份回流 = 删除没送达。放出来让用户看见并重试——
        // 不回滚乐观删除（内容字段已丢），只恢复可见性 + 提示
        for id in outcome.resurrectedIds { optimisticallyDeletedIDs.remove(id) }
        let resurrectedCount = outcome.resurrectedIds.count
        if resurrectedCount > 0 {
            deleteFailureMessage = resurrectedCount == 1
                ? "1 条删除未送达 Mac,已恢复显示——可重试"
                : "\(resurrectedCount) 条删除未送达 Mac,已恢复显示——可重试"
        }
    }

    /// 用户在 iOS 上 tap 复制一条 → 本机乐观把它顶到最前。
    ///
    /// **乐观更新** — 不等 Mac 经 UCB 链路 re-capture / bump / 通过 WS 推回来:
    /// 直接本机改 capturedAtNs = now + 重排。Mac 真 bump 了通过 /since 回来时 merge
    /// 保 max(本机, incoming) 不掉刚顶的位置;Mac 没 bump(UCB 没透)本机顶一直在
    func bumpToFront(id: String) {
        let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        optimisticCapturedAtNs[id] = nowNs
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].capturedAtNs = nowNs
        } else if let item = lastLocalSearch?.items.first(where: { $0.id == id }) {
            var promoted = item
            promoted.capturedAtNs = nowNs
            items.append(promoted)
        } else {
            return
        }
        items.sort(by: Self.iosListOrder)
        items = Array(items.prefix(Self.displayLimit))
        if let r = lastLocalSearch, let index = r.items.firstIndex(where: { $0.id == id }) {
            var patched = r.items
            patched[index].capturedAtNs = nowNs
            patched.sort(by: Self.iosListOrder)
            lastLocalSearch = LocalSearchResult(
                q: r.q,
                qualifiers: r.qualifiers,
                items: patched,
                snippets: r.snippets,
                totalCount: r.totalCount
            )
        }
    }

    /// 用户长按"置顶/取消置顶"路径——本机乐观立即切 `pinned` + 重排,coordinator 异步
    /// POST /pin/<id>?pinned=N 让 Mac DB 落库。本机重排契约 = `merge` 路径(pinned DESC,
    /// captured_at_ns DESC)。
    ///
    /// 失败兜底:下次 /since 拉 Mac 权威值时 `merge` 会用 server pinned 覆盖本机(`max`
    /// 兜底只对 capturedAtNs),所以乐观值跟 server 不一致时最终会被纠正。中间窗口
    /// (几百 ms 到几秒)用户视感"立即生效"
    ///
    /// Returns: 切换后的 pinned 值;item 不存在返 nil(调用方 swallow,不上 server)
    @discardableResult
    func togglePinOptimistic(id: String) -> Bool? {
        let current = items.first(where: { $0.id == id })
            ?? lastLocalSearch?.items.first(where: { $0.id == id })
        guard let current else { return nil }
        let newPinned = !current.pinned
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].pinned = newPinned
        }
        items.sort(by: Self.iosListOrder)
        // 同步 patch 本地 FTS result，避免搜索状态下等待 canonical /since 回放才更新。
        if let r = lastLocalSearch, let i = r.items.firstIndex(where: { $0.id == id }) {
            var patched = r.items
            patched[i].pinned = newPinned
            patched.sort(by: Self.iosListOrder)
            lastLocalSearch = LocalSearchResult(
                q: r.q,
                qualifiers: r.qualifiers,
                items: patched,
                snippets: r.snippets,
                totalCount: r.totalCount
            )
        }
        return newPinned
    }

    /// iOS 列表排序契约 — pinned DESC,captured_at_ns DESC。`filtered` 文档详述跟 Mac
    /// 排序契约的差异(Mac 多 prefix24h boost)。**单点契约住在 `HistoryFilterDispatch.iosListOrder`**
    /// 这里转一层让 HistoryStore 内部 merge / bumpToFront / togglePinOptimistic 调用点
    /// 不必直接拼 module 前缀,API surface 稳定
    nonisolated static func iosListOrder(_ a: Item, _ b: Item) -> Bool {
        HistoryFilterDispatch.iosListOrder(a, b)
    }

    /// 用户长按"删除"路径——本机乐观立即移除,server 端 DELETE /item/<id> 在 coordinator
    /// 异步发(server 自己 cascade 同 text_full sibling,见 `Database.softDelete`).
    /// 失败的话(网络抖 / Mac 不可达)下一次 /since 拉自然 re-insert——`merge()` 通过
    /// `deleteTracker` 检测到 + 弹 banner 提示用户。**不**回滚乐观删除(内容字段已丢)
    ///
    /// **Fold-aware cascade**:text-kind 按同 `text_full`；blob-kind 按 15s 内跨 origin
    /// 同 SHA display cluster，把 `items` 里的 active sibling 一并从内存集合移除，
    /// 跟 server cascade 范围对齐.不然 fold 立刻 elect 另一条同 text 的 sibling 当代表
    /// → 用户感觉"卡片删了又出现"(直到 server cascade tombstone 通过 /since 回流才真消失)
    func removeOptimistic(item: Item) {
        let idsToRemove = deleteTracker.markDeleted(item, in: items)
        optimisticallyDeletedIDs.formUnion(idsToRemove)
        items.removeAll { idsToRemove.contains($0.id) }
        if let r = lastLocalSearch {
            let patched = r.items.filter { !idsToRemove.contains($0.id) }
            lastLocalSearch = LocalSearchResult(
                q: r.q,
                qualifiers: r.qualifiers,
                items: patched,
                snippets: r.snippets.filter { !idsToRemove.contains($0.key) },
                totalCount: max(0, r.totalCount - (r.items.count - patched.count))
            )
        }
    }

    /// 用户点 banner ✕ 或 5s 自动消时调
    func dismissDeleteFailureMessage() {
        deleteFailureMessage = nil
    }

    /// 测试 / debug 用——把内存集合清空。
    func reset() {
        items = []
        query = ""
        activeQualifiers = []
        pendingPinTargets.removeAll()
        optimisticCapturedAtNs.removeAll()
        optimisticallyDeletedIDs.removeAll()
        lastLocalSearch = nil
    }

    // MARK: - SQLite mirror / legacy migration

    nonisolated static var persistenceDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("HistoryStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var mirrorFile: URL { persistenceDir.appendingPathComponent("mirror.sqlite") }
    /// Durable completion proof must survive iOS purging the Caches directory that owns mirror.sqlite.
    nonisolated static var syncCheckpointFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("DuoPaste", isDirectory: true)
            .appendingPathComponent("metadata-sync-checkpoint.json")
    }
    /// Pre-R2.1 files. They remain named here solely for one-time verified migration.
    nonisolated static var itemsFile: URL { persistenceDir.appendingPathComponent("items.json") }
    nonisolated static var cursorFile: URL { persistenceDir.appendingPathComponent("cursor.json") }

    nonisolated static func openMirror() throws -> MetadataMirrorStore {
        try MetadataMirrorStore(path: mirrorFile)
    }

    private nonisolated static func openMirrorOrNil() -> MetadataMirrorStore? {
        do {
            return try openMirror()
        } catch {
            DebugLog.shared.append("HistoryStore mirror open failed: \(error)")
            return nil
        }
    }

    /// App launch: import the old bounded JSON cache for instant continuity, verify every decoded ID
    /// exists in SQLite, then delete both legacy files. The old cursor is never imported because it
    /// may have advanced past metadata truncated by the 1000-row cap.
    func restore() {
        guard let mirror else {
            if let data = try? Data(contentsOf: Self.itemsFile),
               let restored = try? JSONDecoder().decode([Item].self, from: data) {
                items = Array(restored.sorted(by: Self.iosListOrder).prefix(Self.displayLimit))
            }
            return
        }
        let legacyExists = FileManager.default.fileExists(atPath: Self.itemsFile.path)
        if legacyExists {
            do {
                let data = try Data(contentsOf: Self.itemsFile)
                let legacy = try JSONDecoder().decode([Item].self, from: data)
                _ = try mirror.importLegacyItems(legacy)
                guard try mirror.containsItemIDs(Set(legacy.map(\.id))) else {
                    throw HistoryStoreError.legacyVerificationFailed
                }
                try FileManager.default.removeItem(at: Self.itemsFile)
                try? FileManager.default.removeItem(at: Self.cursorFile)
                DebugLog.shared.append("HistoryStore migrated legacy JSON items=\(legacy.count); cursor reset for full refill")
            } catch {
                // Keep the source files for a later retry; never silently claim a successful upgrade.
                DebugLog.shared.append("HistoryStore legacy migration failed: \(error)")
            }
        } else {
            // A cursor without its bounded item cache is unusable and dangerous; SQLite owns cursor now.
            try? FileManager.default.removeItem(at: Self.cursorFile)
        }

        refreshFromMirror()
        reloadSyncCheckpoint(useLaunchMirrorExistence: true)
    }

    func refreshFromMirror() {
        guard let mirror else { return }
        do {
            var recent = try mirror.recentItems(limit: Self.displayLimit)
            recent.removeAll { optimisticallyDeletedIDs.contains($0.id) }
            for index in recent.indices {
                if let desired = pendingPinTargets[recent[index].id] {
                    recent[index].pinned = desired
                }
                if let optimisticNs = optimisticCapturedAtNs[recent[index].id] {
                    recent[index].capturedAtNs = max(recent[index].capturedAtNs, optimisticNs)
                }
            }
            items = recent.sorted(by: Self.iosListOrder)
        } catch {
            DebugLog.shared.append("HistoryStore refresh mirror failed: \(error)")
        }
    }

    /// Reconcile the evictable SQLite mirror with the durable strict-completion proof. App launch
    /// uses the pre-open file existence bit so opening a new empty DB cannot hide a cache purge;
    /// foreground resume uses current existence so a successful BG pull becomes visible immediately.
    func reloadSyncCheckpoint(useLaunchMirrorExistence: Bool = false) {
        guard syncStatus.activity != .syncing else { return }
        guard let mirror else {
            syncStatus.activity = .failed
            syncStatus.failureMessage = "本地 SQLite 历史无法打开，请重新启动后再试"
            return
        }
        do {
            let localItemCount = try mirror.totalItemCount()
            let cursor = try mirror.cursor()
            let checkpoint = try checkpointStore.load()
            let mirrorExists = useLaunchMirrorExistence
                ? mirrorFileExistedAtLaunch
                : FileManager.default.fileExists(atPath: Self.mirrorFile.path)
            let disposition = MetadataMirrorBootstrapDisposition.classify(
                mirrorFileExisted: mirrorExists,
                localItemCount: localItemCount,
                cursor: cursor,
                checkpoint: checkpoint
            )
            switch disposition {
            case .initialSync:
                syncStatus = HistorySyncStatus(
                    mode: .initialSync,
                    activity: .idle,
                    localItemCount: localItemCount
                )
            case .verifyingExistingCache:
                syncStatus = HistorySyncStatus(
                    mode: .verifyingExistingCache,
                    activity: .idle,
                    localItemCount: localItemCount
                )
            case .rebuilding:
                syncStatus = HistorySyncStatus(
                    mode: .rebuilding,
                    activity: .idle,
                    localItemCount: localItemCount,
                    // The durable checkpoint describes the evicted archive, not this partial refill.
                    sourceTrackedItemCount: nil,
                    serverTotalCount: checkpoint?.lastServerTotalCount,
                    currentPeer: checkpoint?.lastPeerDeviceID,
                    lastSuccessAt: checkpoint?.lastSuccessAt
                )
            case .ready(let checkpoint):
                syncStatus = HistorySyncStatus(
                    mode: .ready,
                    activity: .idle,
                    localItemCount: localItemCount,
                    sourceTrackedItemCount: checkpoint.lastSourceTrackedItemCount,
                    serverTotalCount: checkpoint.lastServerTotalCount,
                    currentPeer: checkpoint.lastPeerDeviceID,
                    lastSuccessAt: checkpoint.lastSuccessAt
                )
            }
            if isSyncPausedByUser {
                syncStatus.activity = .paused
                syncStatus.failureMessage = nil
            }
        } catch {
            syncStatus.activity = .failed
            syncStatus.failureMessage = "本地同步状态读取失败：\(error.localizedDescription)"
            DebugLog.shared.append("HistoryStore sync checkpoint reload failed: \(error)")
        }
    }

    func persistedCursor() -> SinceCursor {
        guard let mirror else { return .zero }
        do { return try mirror.cursor() }
        catch {
            DebugLog.shared.append("HistoryStore cursor read failed: \(error)")
            return .zero
        }
    }

    /// 前台与 BG pull 的统一 gap-safe 路径。正常先从持久化 cursor 增量拉；server
    /// `total_count` 暴露迟到旧行缺口时，Core 自动从 zero 做非破坏性 backfill。
    func synchronizeMetadata(
        client: PeerClient,
        currentPeer: String?,
        pageLimit: Int = 500,
        maxPages: Int = 200
    ) async throws -> MetadataMirrorSyncReport {
        guard let mirror else { throw HistoryStoreError.mirrorUnavailable }
        markSyncStarted(currentPeer: currentPeer)
        do {
            let report = try await mirror.synchronize(
                pageLimit: pageLimit,
                maxPages: maxPages,
                progress: { progress in
                    await self.applySyncProgress(progress)
                },
                onPageApplied: { pageItems in
                    await self.reconcileOptimisticState(with: pageItems)
                },
                fetchPage: { cursor, limit in
                    try await client.fetchSince(cursor: cursor, limit: limit)
                }
            )
            try Task.checkCancellation()
            refreshFromMirror()
            try markSyncComplete(report)
            return report
        } catch is CancellationError {
            // Every completed page is already durable. Refresh the bounded projection; explicit
            // user cancellation already labeled it paused, while automatic route switches stay
            // transient and let their replacement pull own the status.
            refreshFromMirror()
            resolveCancelledSyncActivity()
            throw CancellationError()
        } catch {
            // URLSession/NWConnection may surface a transport error after its parent task was
            // cancelled for route switching. Treat it as cancellation so an obsolete route cannot
            // overwrite the replacement pull's UI with a stale failure.
            if Task.isCancelled {
                refreshFromMirror()
                resolveCancelledSyncActivity()
                throw CancellationError()
            }
            refreshFromMirror()
            markSyncFailed(error)
            throw error
        }
    }

    func markSyncStarted(currentPeer: String?) {
        if let currentPeer, !currentPeer.isEmpty {
            syncStatus.currentPeer = currentPeer
        }
        syncStatus.activity = .syncing
        syncStatus.failureMessage = nil
    }

    func applySyncProgress(_ progress: MetadataMirrorSyncProgress) {
        // 取消之后到达的进度必须丢弃。`cancelPull` 是同步 @MainActor（markSyncPaused →
        // task.cancel() 之间没有 await），所以它跟本函数在 main actor 上严格串行：一次
        // progress 要么整个跑在 cancel 之前（随后被 `.paused` 正确覆盖），要么跑在之后
        // 被这道 guard 挡下。
        //
        // 少了这道 guard 就有一个真实窗口：用户点「取消」时恰好有一页刚 commit ——
        // `pullPass` 先 applyPage 再 await progress，最后才 checkCancellation。progress
        // 把 activity 从 `.paused` 又推回 `.syncing`，随后 CancellationError 抛出，没人
        // 再改它。结果：卡片永久停在「首次同步中」，取消按钮消失（isPulling 已 false），
        // 而 `reloadSyncCheckpoint` 开头的 `guard activity != .syncing` 让之后每一次
        // 前台恢复都变成 no-op —— 只能重启 app 才能解开。
        guard !Task.isCancelled else { return }
        if progress.pass == .backfill {
            syncStatus.mode = .rebuilding
        }
        syncStatus.activity = .syncing
        syncStatus.localItemCount = progress.localItemCount
        syncStatus.sourceTrackedItemCount = progress.sourceTrackedItemCount
        syncStatus.serverTotalCount = progress.serverTotalCount
        if syncStatus.currentPeer == nil {
            syncStatus.currentPeer = progress.sourceDeviceID
        }
    }

    /// 取消收尾兜底：确保没有任何 activity 停在「正在同步」这句谎话上。
    ///
    /// 用户主动取消时 `cancelPull` 已经置 `.paused`，这里不动它——**也绝不能**在这里调
    /// `markSyncPaused()`，那会写 `syncPausedDefaultsKey` 把用户级自动同步一并关掉，
    /// 而 route 切换并不是用户的暂停意图。
    ///
    /// 剩下的情况是 `cancelPullForHTTPRouteChange`：如果替补 pull 没能接手（切换后
    /// kickPull 未触发 / 立刻失败），`.syncing` 就没有主人了。降级成 `.idle` 让
    /// `reloadSyncCheckpoint` 能重新分类，而不是被它开头的 guard 永久短路。
    private func resolveCancelledSyncActivity() {
        guard syncStatus.activity == .syncing else { return }
        syncStatus.activity = .idle
    }

    func markSyncPaused() {
        UserDefaults.standard.set(true, forKey: Self.syncPausedDefaultsKey)
        syncStatus.activity = .paused
        syncStatus.failureMessage = nil
    }

    func markSyncResumed() {
        UserDefaults.standard.set(false, forKey: Self.syncPausedDefaultsKey)
        if syncStatus.activity == .paused {
            syncStatus.activity = .idle
        }
    }

    var isSyncPausedByUser: Bool {
        UserDefaults.standard.bool(forKey: Self.syncPausedDefaultsKey)
    }

    @discardableResult
    func markSyncFailed(_ error: Error) -> String {
        let message = Self.readableSyncFailure(error)
        syncStatus.activity = .failed
        syncStatus.failureMessage = message
        return message
    }

    private func markSyncComplete(_ report: MetadataMirrorSyncReport) throws {
        let successAt = Date()
        let peerDeviceID = report.sourceDeviceID ?? syncStatus.currentPeer
        let checkpoint = MetadataMirrorSyncCheckpoint(
            lastSuccessAt: successAt,
            lastPeerDeviceID: peerDeviceID,
            lastLocalItemCount: report.localTotalCount,
            lastSourceTrackedItemCount: report.sourceTrackedItemCount,
            lastServerTotalCount: report.serverTotalCount,
            finalCursor: report.finalCursor
        )
        try checkpointStore.save(checkpoint)
        UserDefaults.standard.set(false, forKey: Self.syncPausedDefaultsKey)
        syncStatus = HistorySyncStatus(
            mode: .ready,
            activity: .idle,
            localItemCount: report.localTotalCount,
            sourceTrackedItemCount: report.sourceTrackedItemCount,
            serverTotalCount: report.serverTotalCount,
            currentPeer: peerDeviceID,
            lastSuccessAt: successAt
        )
    }

    nonisolated static func readableSyncFailure(_ error: Error) -> String {
        if let metadataError = error as? MetadataMirrorSyncError {
            switch metadataError {
            case .cursorDidNotAdvance:
                return "Mac 返回的同步游标没有推进，请点“立即刷新”重试"
            case .pageLimitExceeded:
                return "本次数据较多，当前进度已保存；点“继续同步”即可接着拉取"
            case .countMismatch(let expected, let actual):
                return "完整性校验未通过（Mac \(expected) 条，本机 \(actual) 条），请继续同步修复"
            case .sourceChanged:
                return "同步期间切换了 Mac，已安全暂停；请立即刷新重试"
            }
        }
        if let peerError = error as? PeerClientError {
            switch peerError {
            case .httpStatus(let code) where code == 401 || code == 403:
                return "配对凭据已失效，请到设置重新配对"
            case .httpStatus(let code):
                return "Mac 返回 HTTP \(code)，请稍后立即刷新"
            case .nonHTTP:
                return "Mac 返回了无效响应，请检查当前 peer"
            default:
                return peerError.localizedDescription
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .notConnectedToInternet:
                return "当前离线；已同步到本机的历史仍可搜索"
            case .timedOut:
                return "连接 Mac 超时；请检查 Mac 是否在线后立即刷新"
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
                return "暂时连不上 Mac；本地历史仍可用，恢复网络后可继续同步"
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return "配对凭据已失效，请到设置重新配对"
            default:
                break
            }
        }
        let fallback = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "同步失败，请检查网络后立即刷新" : fallback
    }
}

private enum HistoryStoreError: LocalizedError {
    case mirrorUnavailable
    case legacyVerificationFailed

    var errorDescription: String? {
        switch self {
        case .mirrorUnavailable: return "本地 SQLite mirror 无法打开"
        case .legacyVerificationFailed: return "旧 JSON 导入后 ID 校验失败"
        }
    }
}

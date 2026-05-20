import Foundation
import Observation
import DuoPasteCore

/// 主进程持有的全局 Item 集合。Coordinator 从 peer 拉到新页就 merge() 进来。
/// 没本地 GRDB——重启丢全部内存数据,下次 launch 从 cursor=.zero 重新拉。
/// (后续要加 GRDB mirror 时把 merge() 改成走 db,搜索改成 SearchAPI)
@Observable
@MainActor
final class HistoryStore {
    /// 显示用,按 captured_at_ns DESC + pinned-first 排好序的列表。
    private(set) var items: [Item] = []
    /// 搜索框文本。空 → 全列表;非空 → 优先用 server 端 FTS5 结果,失败 fallback 本机 contains。
    var query: String = ""

    /// Mac peer 远端 `/search` 返回的最新结果。query 非空时优先用它显示——FTS5 + fold-aware,
    /// 跟 Mac UI 口径一致。query 切换 / coordinator 失败时清掉走 fallback。
    /// **匹配**靠 `q` 字段判断是否对得上当前 store.query;`q != store.query` 时不用(过期)
    struct ServerSearchResult: Equatable, Sendable {
        let q: String
        let items: [Item]
        let snippets: [String: String]
        let totalCount: Int
    }
    private(set) var lastServerSearch: ServerSearchResult?

    /// SwiftUI 直接绑这个——过滤 + fold 后的列表。
    /// - 空 query → 全列表(本机 fold)
    /// - query 命中最近 server 搜索 → 用 server fold-aware items(server 已 fold,不再二次 fold)
    /// - 否则 → 本机 contains fallback 后 fold(server 还在拉 / 失败 / 离线时)
    ///
    /// **Fold 契约定义在 `Item.foldByTextFull`(DuoPasteCore)**——跨 origin 同 text_full
    /// 折一条,winner = max(captured_at_ns),pinned OR 聚合。修 Continuity / ToDesk 把同
    /// 文本镜到两台 Mac 后 iOS 看见两张卡(两个不同 origin_device)而 Mac UI 只一张的不对齐.
    /// 排序契约在本路径单独应用:(pinned DESC, captured_at_ns DESC)——Mac fold 多一层
    /// prefix24h boost,iOS 列表无 query 时不需要;有 query 走 server search 路径就有了
    var filtered: [Item] {
        guard !query.isEmpty else { return Self.foldAndSort(items) }
        if let r = lastServerSearch, r.q == query {
            return r.items
        }
        let q = query.lowercased()
        let matched = items.filter { item in
            (item.preview?.lowercased().contains(q) ?? false)
                || (item.textFull?.lowercased().contains(q) ?? false)
                || (item.extractedText?.lowercased().contains(q) ?? false)
        }
        return Self.foldAndSort(matched)
    }

    /// fold + iOS list 排序契约一体应用。fold 走 DuoPasteCore 单点契约,sort 本地化
    /// (Mac 跟 iOS 排序契约不同——见 `filtered` 文档)
    private static func foldAndSort(_ list: [Item]) -> [Item] {
        Item.foldByTextFull(list).sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.capturedAtNs > b.capturedAtNs
        }
    }

    /// coordinator 拉完 /search 把结果灌进来。**只在 `q` 仍匹配当前 store.query 时**
    /// 应用——拉结果回来时用户可能已经改了 query,旧响应丢弃避免闪现错的命中
    func applyServerSearch(_ r: ServerSearchResult) {
        guard r.q == query else { return }
        lastServerSearch = r
    }

    /// query 变化时调,清掉旧 server 结果让 filtered 暂时走 contains fallback——
    /// coordinator 异步拉新一轮 server 结果,中间这段时间用户不会看到上一轮的命中残影
    func clearServerSearch() {
        lastServerSearch = nil
    }

    // MARK: - 删除失败追踪

    /// 用户 `removeOptimistic` 删除但还没收到 server tombstone 的 id → 标记时间。
    /// `merge()` 看到非 tombstone 的 id 在这里 + 超过 grace 视为 server DELETE 未送达,
    /// 写 `deleteFailureMessage` 让 UI 顶部 banner 提示。tombstone 行确认删除时清掉条目
    private var pendingDeletes: [String: Date] = [:]

    /// `merge()` 检测到删除未送达时写,UI 顶部 banner 显示,5s 自动消(或用户点 ✕)。
    /// 这里只展示提示——条目本身已被 /since 重新 insert 回 `items`,无法回滚乐观删除
    /// (内容字段已丢),用户看到提示后自行决定重试或忽略
    private(set) var deleteFailureMessage: String?

    /// peer 拉到一批 item 时调。按 id 去重,tombstone (deletedAtNs 非空) 直接移除。
    /// 重排序:pinned DESC,captured_at_ns DESC。
    ///
    /// 已有 id 跟 incoming id 撞 → 用 incoming 全字段(Mac 是权威),**但 capturedAtNs
    /// 取 max(local, incoming)**——保护 iOS 本机乐观顶(bumpToFront)在 /since 拉
    /// stale Mac 行时不被覆盖回去。Mac 的 UCB 链路真 bump 了的话 Mac 那行 capturedAtNs
    /// 也是新的,max 仍是新值,两边一致;Mac 没 bump → 本机乐观值赢
    func merge(_ incoming: [Item]) {
        guard !incoming.isEmpty else { return }
        var byID: [String: Item] = [:]
        for it in items { byID[it.id] = it }
        var resurrectedCount = 0
        let now = Date()
        // 3s grace 避免 false positive:DELETE 刚发出去,前一波 in-flight /since
        // 还没回,带回 alive 行很正常——给端到端通路 3s buffer 真等不到 tombstone
        // 才算 server 没删掉
        let gracePeriod: TimeInterval = 3
        for it in incoming {
            if it.isTombstone {
                byID.removeValue(forKey: it.id)
                pendingDeletes.removeValue(forKey: it.id)  // server 确认删除成功
                continue
            }
            // 非 tombstone 行 id 在 pendingDeletes 里 + 超 grace → 真的没删掉
            if let pendingAt = pendingDeletes[it.id], now.timeIntervalSince(pendingAt) > gracePeriod {
                resurrectedCount += 1
                pendingDeletes.removeValue(forKey: it.id)
            }
            if let existing = byID[it.id], existing.capturedAtNs > it.capturedAtNs {
                var merged = it
                merged.capturedAtNs = existing.capturedAtNs
                byID[it.id] = merged
            } else {
                byID[it.id] = it
            }
        }
        items = byID.values.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.capturedAtNs > b.capturedAtNs
        }
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
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        // 已经在第一位且不 pinned 顶 → 没必要重排
        if idx == 0 && !items[idx].pinned { return }
        items[idx].capturedAtNs = nowNs
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.capturedAtNs > b.capturedAtNs
        }
    }

    /// 用户长按"删除"路径——本机乐观立即移除,server 端 DELETE /item/<id> 在 coordinator
    /// 异步发。失败的话(网络抖 / Mac 不可达)下一次 /since 拉自然 re-insert——`merge()`
    /// 通过 `pendingDeletes` 检测到 + 弹 banner 提示用户。**不**回滚乐观删除(内容字段已丢)
    func removeOptimistic(id: String) {
        items.removeAll { $0.id == id }
        let now = Date()
        pendingDeletes[id] = now
        // prune > 60s 的 entry——Mac 长时间不可达后用户已经"等够久",再回来即便看到行
        // 也不再触发 banner(假设用户已经接受这条状态)。同时防 dict 无限增长
        let cutoff = now.addingTimeInterval(-60)
        pendingDeletes = pendingDeletes.filter { $0.value > cutoff }
    }

    /// 用户点 banner ✕ 或 5s 自动消时调
    func dismissDeleteFailureMessage() {
        deleteFailureMessage = nil
    }

    /// 测试 / debug 用——把内存集合清空。
    func reset() {
        items = []
        query = ""
    }

    // MARK: - 磁盘持久化

    /// 持久化文件:Caches/HistoryStore/items.json + cursor.json。NSCachesDirectory 可被
    /// 系统在压力下回收(可接受——下次启动 from cursor=.zero 重新拉满 history)
    nonisolated static var persistenceDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("HistoryStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var itemsFile: URL { persistenceDir.appendingPathComponent("items.json") }
    nonisolated static var cursorFile: URL { persistenceDir.appendingPathComponent("cursor.json") }

    /// 限 maxItems(默 1000)防文件无限增长。debounce 在调用方控制——
    /// 每条 merge 都写盘太频繁,DuoPasteApp 控制按 scenePhase / 阶段触发
    func persist(maxItems: Int = 1000) {
        let snapshot = Array(items.prefix(maxItems))
        let url = Self.itemsFile
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                DebugLog.shared.append("HistoryStore.persist failed: \(error)")
            }
        }
    }

    /// app launch 调一次:读 items.json → 填 self.items。失败/不存在 → 留空走正常 /since 拉。
    /// **必须**在 coordinator.reconfigure 前调,否则 /since 拉的页跟磁盘已有 merge 时拿不到
    /// 旧 cursor 之前的内容(BGAppRefreshTask 写了但 coordinator 不知道,会重 pull 大量)
    func restore() {
        guard let data = try? Data(contentsOf: Self.itemsFile),
              let restored = try? JSONDecoder().decode([Item].self, from: data) else {
            DebugLog.shared.append("HistoryStore.restore: no cached items")
            return
        }
        self.items = restored
        DebugLog.shared.append("HistoryStore.restore: items=\(restored.count)")
    }
}

/// 给后台 pull task 用的"上次 sync 到哪了"持久化。背景 task 在没 PeerSyncCoordinator
/// 内存状态时也能从这恢复 cursor 继续拉,不重头 pull。
struct PersistedCursor: Codable {
    let ingestedAtNs: Int64
    let id: String
    let updatedAtUnix: Int64

    static func load() -> PersistedCursor? {
        guard let data = try? Data(contentsOf: HistoryStore.cursorFile),
              let c = try? JSONDecoder().decode(PersistedCursor.self, from: data) else {
            return nil
        }
        return c
    }

    func save() {
        let url = HistoryStore.cursorFile
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            DebugLog.shared.append("PersistedCursor.save failed: \(error)")
        }
    }
}

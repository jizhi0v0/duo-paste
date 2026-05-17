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
    /// 搜索框文本。空 → 全列表;非空 → contains 过滤(临时,等接 GRDB+FTS5 再正经)。
    var query: String = ""

    /// SwiftUI 直接绑这个——过滤后的列表。
    var filtered: [Item] {
        guard !query.isEmpty else { return items }
        let q = query.lowercased()
        return items.filter { item in
            (item.preview?.lowercased().contains(q) ?? false)
                || (item.textFull?.lowercased().contains(q) ?? false)
                || (item.extractedText?.lowercased().contains(q) ?? false)
        }
    }

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
        for it in incoming {
            if it.isTombstone {
                byID.removeValue(forKey: it.id)
                continue
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
            return
        }
        self.items = restored
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

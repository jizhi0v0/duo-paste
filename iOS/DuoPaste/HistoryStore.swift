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
    func merge(_ incoming: [Item]) {
        guard !incoming.isEmpty else { return }
        var byID: [String: Item] = [:]
        for it in items { byID[it.id] = it }
        for it in incoming {
            if it.isTombstone {
                byID.removeValue(forKey: it.id)
            } else {
                byID[it.id] = it
            }
        }
        items = byID.values.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.capturedAtNs > b.capturedAtNs
        }
    }

    /// 测试 / debug 用——把内存集合清空。
    func reset() {
        items = []
        query = ""
    }
}

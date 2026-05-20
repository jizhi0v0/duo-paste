# PR #22 review follow-up plan

Review issues 拆成三档:

| # | 级别 | 状态 |
|---|---|---|
| #1 `/search` 双跑 SQL+fold | P1 | ✅ 本 PR 已修(`SearchAPI.searchHitsAndCount` 单次 pass) |
| #2 `onBumpApplied` 复用给 DELETE 命名糊 | P3 | 不阻塞,本文档不展开 |
| #3 in-flight search 不 cancel | P2 | 留 plan(本文档 §1) |
| #4 删除失败 UX 反馈 | P2 | 留 plan(本文档 §2) |
| #5 sync `searchHits` block event loop | P3 | 不阻塞,跟 `/since` 既定模式同源 |
| Nit: doc comment 缩进 | nit | 留 follow-up |

---

## §1 P2 #3: in-flight search 自动 cancel

### 问题
`PeerSyncCoordinator.searchOnServer(q:)` 起 detached Task 不持有 handle。用户敲字快(每个 keystroke 后 250ms 触发一次 server call)→ 多个 search 并发飞向 Mac。`HistoryStore.applyServerSearch` 的 `r.q == query` 守护让 UI 不错乱,但浪费 Mac CPU + 移动带宽 + URLSession 连接池抖动。

### 修法

`PeerSyncCoordinator.swift`,跟 `currentPasteTask` 同模式:

```swift
// MARK: - 字段
private var currentSearchTask: Task<Void, Never>?

// MARK: - searchOnServer 改造
func searchOnServer(q: String) {
    guard let secret = currentSecret else { return }
    let urls: [String] = wsPool?.connectedHTTPURLsByDevice(prefer: currentEndpointURL) ?? []
    let chosen = currentEndpointURL ?? urls.first
    guard let urlString = chosen, let url = URL(string: urlString) else { return }
    // **取消上一轮**——用户敲字快时旧 Task 还在拉就废掉,只看新 q 的结果。
    // URLSession.data(for:) 支持 cancellation,Task.cancel() 会让正在跑的 HTTP 立即抛错
    currentSearchTask?.cancel()
    currentSearchTask = Task { [weak self] in
        guard let self else { return }
        let client = PeerClient(config: PeerConfig(baseURL: url, sharedSecret: secret))
        do {
            let (items, snippets, total) = try await client.searchItems(q: q, limit: 200)
            if Task.isCancelled { return }
            let result = HistoryStore.ServerSearchResult(
                q: q, items: items, snippets: snippets, totalCount: total
            )
            await MainActor.run { self.store.applyServerSearch(result) }
            DebugLog.shared.append("search ok q=\(q) hits=\(items.count) total=\(total)")
        } catch is CancellationError {
            // 用户改了 query 旧 search 被替——正常,不记日志
        } catch URLError.cancelled {
            // URLSession 抛的 cancel 同上,nop
        } catch {
            DebugLog.shared.append("search failed q=\(q): \(error.localizedDescription)")
        }
    }
}
```

### 验证
- 手工:Settings 调试区盯 DebugLog,快敲"a"→"ab"→"abc",应该只看到 "search ok q=abc" 一条(中间两条被 cancel 不记 log)
- 单测:加 `searchOnServer` 单元测试有点重(需要 mock PeerClient + WSPool),先靠 manual smoke 兜底

### 风险
- `Task.isCancelled` check 在 await 后,避免 cancel 后还写 store
- `URLError.cancelled` 不一定从所有 transport(NWHTTPTransport ponte 路径)抛出——如果 ponte 实现不响应 cancel,旧 task 会跑完但 `Task.isCancelled` 仍能挡住 applyServerSearch。可接受

---

## §2 P2 #4: 删除失败 banner

### 问题
`triggerDelete` 走 optimistic 删除:本机 `removeOptimistic` 立即消失 + 后台 fanout DELETE。**所有错都 swallow 到 DebugLog**,用户不知道删除是否真到 Mac。最坏:
- 用户删了项目
- 网络抖,fanout 全失败(非 404/410 这种幂等成功)
- 1-2s 后 /since 自然拉回这条 alive 行 → 通过 merge() 重新出现在列表
- 用户体感"删了又自己回来了什么 bug"

### 修法

#### a. HistoryStore 跟踪 pending delete

```swift
// MARK: - 字段
/// 用户 removeOptimistic 删除但还没收到 server tombstone 的 id → 标记时间。
/// merge() 时如果某个 incoming 行 id 在这里 + grace > 3s → 视为删除未送达
/// (3s grace 避免 race:DELETE 跟之前一波 /since 在 in-flight,后者带回 alive 行)
private var pendingDeletes: [String: Date] = [:]

/// merge() 检测到删除未送达时设置;UI 顶部 banner 显示,5s 自动消
private(set) var deleteFailureMessage: String?

// MARK: - removeOptimistic 改造
func removeOptimistic(id: String) {
    items.removeAll { $0.id == id }
    let now = Date()
    pendingDeletes[id] = now
    // prune > 60s 的 entry(假设那么久还没看到 tombstone 就放弃跟踪,避免无限增长)
    let cutoff = now.addingTimeInterval(-60)
    pendingDeletes = pendingDeletes.filter { $0.value > cutoff }
}

// MARK: - merge() 改造
func merge(_ incoming: [Item]) {
    guard !incoming.isEmpty else { return }
    var byID: [String: Item] = [:]
    for it in items { byID[it.id] = it }
    var resurrectedCount = 0
    let now = Date()
    let gracePeriod: TimeInterval = 3
    for it in incoming {
        if it.isTombstone {
            byID.removeValue(forKey: it.id)
            pendingDeletes.removeValue(forKey: it.id)  // 删除成功确认
            continue
        }
        // 看到非 tombstone 的 id 在 pendingDeletes 里 + 超过 grace → 真的没删掉
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

func dismissDeleteFailureMessage() {
    deleteFailureMessage = nil
}
```

#### b. HistoryView banner

```swift
var body: some View {
    NavigationStack {
        VStack(spacing: 0) {
            if let msg = store.deleteFailureMessage {
                deleteFailureBanner(message: msg)
            }
            Group {
                if store.items.isEmpty { emptyState } else { listScroll }
            }
        }
        ...
    }
}

@ViewBuilder
private func deleteFailureBanner(message: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        Text(message).font(.caption)
        Spacer()
        Button {
            store.dismissDeleteFailureMessage()
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .background(Color.orange.opacity(0.15))
    .task(id: message) {
        // 5s 自动消;期间用户点 ✕ 也会立即消
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled { store.dismissDeleteFailureMessage() }
    }
}
```

### 验证
- 手工 smoke:
  1. iOS 长按删除某条
  2. 立即 `launchctl bootout` Mac daemon(模拟 server 不可达)
  3. 等 5s+,scenePhase 走或下次 /since(BG 唤醒 / 重 active)
  4. 应该看到该条恢复 + 顶部橙色 banner
  5. 自动 5s 消 + ✕ 按钮即时消都通
- 单测:`HistoryStoreDeleteFailureTests`:
  - `removeOptimistic + merge(stale_alive_after_grace)` → message 非空
  - `removeOptimistic + merge(tombstone)` → pendingDeletes 清,message nil
  - `removeOptimistic + merge(stale_alive_within_grace)` → message nil(false positive 防护)

### 风险
- pendingDeletes 60s prune 简单粗暴——如果用户删了一条但 Mac 长时间不可达(>60s),后续 merge 看到行不会触发 banner。可接受:用户已经"等了 1 分钟",再回来不见 banner 也算合理(条目就是在那);最坏只是少一次提示
- gracePeriod=3s 是经验值:DELETE 路径 + /since 推 tombstone 端到端通常 <500ms,前一波 in-flight /since 极少超 2s。3s 给足 buffer

---

## §3 nit: doc comment 缩进

`HistoryStore.swift:46,103`、`PeerClient.swift:175-180`、`HistoryCellView.swift:341-343`:doc comment(`///`)前多了一格空格,跟周围 4-space 不一致。机械替换即可:

```sh
# 替前先 grep 看准确位置,sed 直接改可能误伤代码注释。手工 Edit 更稳
```

不阻塞任何路径,合在下一个无关 PR 顺手清理。

---

## 处理优先级建议

1. P1 #1 已修 ✅
2. 本机 install + iOS 装机 smoke 现有 3 个改动(本 PR scope)
3. 验过 merge 本 PR
4. 另开 feat 分支处理 §1 (P2 #3) + §2 (P2 #4)。两者无依赖,可并行 或 串行 都行
5. §3 nit 看心情

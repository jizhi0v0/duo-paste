# Search Panel 多选 Paste

## Context

当前 Search Panel 只支持单选——`AppState.selectedID: String?` 单 id，箭头 / 单击只改 selectedID，Enter / 双击 `pasteBack(_ item: Item)` 写一条到 NSPasteboard。

目标：加 macOS 标准的鼠标多选交互（cmd+点 toggle / shift+点 range），按选择顺序合并 paste 到一次粘贴。

**已决定的语义**（user 已拍板）：

1. **仅同 kind 多选可合并**——文本类（text/url/rtf/html）拼成单个字符串、file 类合并成多 URL；含 image 或跨 kind → 按选择顺序只 paste **首项** + 顶部 banner 提示
2. **文本拼接分隔符**：单换行 `\n`
3. **键盘只单选导航**——shift+↑/↓ 不做范围选择；多选只走鼠标 cmd/shift+点
4. NSPasteboard 单次写入只能承载"多 file URL"或"单字符串（可多 type 表示）"——没有"多 image"或"跨类型混合"语义，所以降级是必然

## 影响范围

5 个源文件 + 2 个新测试文件：

| 文件 | 改动 |
|---|---|
| `Sources/duo-pasted/AppState.swift` | selectedID → selectedIDs + anchorID;navigate/updateSelection 改写 |
| `Sources/duo-pasted/SearchView.swift` | ItemRow.isSelected 读 selectedIDs.contains;tap 闭包读 NSEvent.modifierFlags 分支 |
| `Sources/duo-pasted/SearchPanelController.swift` | onPaste 签名 `(Item)` → `([Item])`;Enter 路径传 selectedItems |
| `Sources/duo-pasted/AppDelegate.swift` | pasteBack 接 `[Item]`;canMerge 判断 + 降级 banner |
| `Sources/duo-pasted/Copyback.swift` | 新增 `writeMerged(items:blobs:)` 静态函数 |
| `Tests/DuoPastedTests/CopybackMergedTests.swift` | 新增:text 拼接顺序 / file 合并 / 行为契约 |
| `Tests/DuoPastedTests/AppStateSelectionTests.swift` | 新增:cmd+点 toggle / shift+点 range / refresh 保持选择 |

## 数据模型（AppState.swift）

```swift
/// 按选择顺序追加的选中 id 列表。空 = 没显式选中(currentItem 取 results.first 兜底)。
/// 单选 = 长度 1。多选 = 长度 N,顺序就是 paste 时的合并顺序。
var selectedIDs: [String] = []

/// shift+点的 range 锚点。
/// - 普通单击 / 箭头导航 / cmd+点(append) → 更新到当前
/// - shift+点 → 不动 anchor,只更新 selectedIDs(从 anchor 到点击位置 range)
/// - 没 anchor 时 shift+点 退化成单选
var anchorID: String?

/// 多项 paste 时按 selectedIDs 顺序拿 Item。被 filter chip 过滤掉的 id 自动跳过。
var selectedItems: [Item] {
    selectedIDs.compactMap { id in results.first { $0.id == id } }
}
```

**`selectedID` 不再保留兼容 setter——所有写入点改成操作 `selectedIDs`**。`currentItem` 改成：

```swift
var currentItem: Item? {
    if let last = selectedIDs.last, let it = results.first(where: { $0.id == last }) {
        return it
    }
    return results.first
}
```

**`navigate(by:)` 改写**——任何箭头键都重置成单选 + 重置 anchor：

```swift
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
```

**`updateSelection(forItems:queryIsEmpty:)` 改写**——refresh 后 filter 掉不在 results 里的 id：

```swift
private func updateSelection(forItems items: [Item], queryIsEmpty: Bool) {
    let available = Set(items.map { $0.id })
    let kept = selectedIDs.filter { available.contains($0) }

    if queryIsEmpty {
        // 清空搜索 → 强制单选首项(原行为),清空多选
        let first = items.first?.id
        if selectedIDs != [first].compactMap({ $0 }) {
            selectedIDs = first.map { [$0] } ?? []
            anchorID = first
            if first != nil { scrollPulse &+= 1 }
        }
    } else if !kept.isEmpty {
        // 多选至少有一项还在 → 保持顺序
        if kept != selectedIDs { selectedIDs = kept }
    } else {
        // 全被 filter 掉了 → 退化单选首项
        let first = items.first?.id
        selectedIDs = first.map { [$0] } ?? []
        anchorID = first
        if first != nil { scrollPulse &+= 1 }
    }
}
```

## 鼠标交互（SearchView.swift）

ItemRow 第 460 行 `isSelected: item.id == state.selectedID` → `state.selectedIDs.contains(item.id)`。

单击 gesture 闭包（行 474-478）改成读实时 modifier：

```swift
.simultaneousGesture(
    TapGesture(count: 1).onEnded {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            // toggle 单项,append 到末尾保持选择顺序
            if let i = state.selectedIDs.firstIndex(of: item.id) {
                state.selectedIDs.remove(at: i)
            } else {
                state.selectedIDs.append(item.id)
                state.anchorID = item.id
            }
        } else if mods.contains(.shift) {
            // anchor 到 item 的 range,按 results 列表顺序展开(不是按点击顺序)
            // 没 anchor → 退化单选
            guard let anchor = state.anchorID,
                  let from = state.results.firstIndex(where: { $0.id == anchor }),
                  let to   = state.results.firstIndex(where: { $0.id == item.id })
            else {
                state.selectedIDs = [item.id]
                state.anchorID = item.id
                return
            }
            let lo = min(from, to); let hi = max(from, to)
            state.selectedIDs = (lo...hi).map { state.results[$0].id }
            // shift+点不动 anchor (Finder 行为)
        } else {
            // 普通单击 → 单选 + 重置 anchor
            state.selectedIDs = [item.id]
            state.anchorID = item.id
        }
    }
)
```

**为什么读 `NSEvent.modifierFlags` 而不是 SwiftUI `TapGesture().modifiers(.command)`**：后者把同一 row 的 plain / cmd / shift tap 拆成多个 gesture,跟现有 `count:2` 双击 gesture 一起会让 macOS 的双击消歧时序更脆(参考 CLAUDE.md "onTapGesture(count:1) + (count:2) 的 500ms 延迟" 已经踩过的坑)。读 `NSEvent.modifierFlags` 是同步类方法,在 TapGesture.onEnded 触发时拿当前键盘 modifier 状态,准确且不破坏现有 gesture 结构。

双击 gesture（行 467-471）**不动**——双击始终 paste 双击的那一条单 item,不管 selectedIDs 是什么(跟 Spotlight 风格一致,双击 = 快捷直 paste)。

## Copyback.writeMerged（Copyback.swift 新增）

纯函数,好单测:

```swift
/// 合并写多项到 NSPasteboard 单次粘贴。调用方在外面已经判定 items 满足合并条件:
/// - 全 text/url/rtf/html → 拼成单字符串(\n 分隔)
/// - 全 file → 收集所有 NSURL writeObjects 一次
/// 返回 false = 没数据可写(textFull 全空 / file URL 全失效)
@MainActor
@discardableResult
static func writeMerged(items: [Item], blobs: BlobStore) -> Bool {
    guard !items.isEmpty else { return false }

    // image 在外面已经被判为不可合并;file / 文本类是合并入口
    let allFile = items.allSatisfy { $0.kind == .file }
    if allFile {
        var allURLs: [NSURL] = []
        for it in items {
            guard let raw = it.textFull else { continue }
            for line in raw.split(separator: "\n") {
                let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { continue }
                allURLs.append(NSURL(fileURLWithPath: path))
            }
        }
        guard !allURLs.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        _ = pb.writeObjects(allURLs)
        return true
    }

    // 文本类(text/url/rtf/html)——只取 textFull,拼 \n。
    // 多选合并丢掉 rtf/html 的富文本表示,只输出 plain(语义降级,reviewer 注意点)
    let parts = items.compactMap { $0.textFull }
    guard !parts.isEmpty else { return false }
    let joined = parts.joined(separator: "\n")
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(joined, forType: .string)
    return true
}
```

**原 `Copyback.write(item:blobs:)` 单项路径保留不动**——单选 / 降级首项走原路径,image 路径靠它处理。

## pasteBack 改造（AppDelegate.swift）

`pasteBack(_ item: Item)` → `pasteBack(_ items: [Item])`,旧调用点 (`onPaste` 单 item)统一传 `[item]`:

```swift
private func pasteBack(_ items: [Item]) {
    guard !items.isEmpty else { return }

    currentPasteTask?.cancel()
    currentPasteTask = nil
    state.pasteProgress = .idle

    // 1. 单项 → 走原 pasteBackSingle 路径(保留 image lazy 拉 blob 能力)
    if items.count == 1 {
        pasteBackSingle(items[0])
        return
    }

    // 2. 多选 → 判断 canMerge
    let kinds = Set(items.map { $0.kind })
    let canMerge = kinds.count == 1 && kinds != [.image]
    if !canMerge {
        // 跨 kind 或多 image → 按选择顺序取首项 paste,banner 提示
        let kindLabel = kinds.count > 1 ? "跨类型" : "多图片"
        state.recentNotice = "\(kindLabel)多选不可合并,已 paste 第 1 项 (共 \(items.count))"
        pasteBackSingle(items[0])
        return
    }

    // 3. 同 kind 非 image → 同步 merge 写 NSPasteboard
    watcher.flushPendingIfAny()
    let wrote = Copyback.writeMerged(items: items, blobs: deps.blobs)
    watcher.suppressUpToCurrent()
    if wrote {
        // 多项 paste 不走 PasteSuppressionSet——它是 single-item fingerprint 的去重,
        // 多项合并后写入的 string 不对应任何单条 item fingerprint,记录无意义
    } else {
        state.pasteProgress = .failed(reason: "选中项无可写入内容")
        return
    }
    panel.hide()
}

/// 原 pasteBack 行为搬来,接单项。image lazy 拉 blob / 同步快路径都在这里
private func pasteBackSingle(_ item: Item) {
    // ... 原 pasteBack 行 405-437 实现,签名改了名 ...
}
```

**为什么多项不记 PasteSuppressionSet**:`PasteSuppressionSet.fingerprint(forItem:)` 是单条 item 的指纹(text_full / blob_sha),用于"用户 Cmd+V 粘回的内容 5 分钟内不再 capture 成新条目"。多项合并后写入 pasteboard 的字符串本身不对应库里任何已有行(它是临时拼接的),做 suppression 也匹配不上。允许下次 watcher 抓回库 = 用户可以把"我刚刚合并粘贴过的串"当成一条新 clipboard 历史,行为符合直觉。**`suppressUpToCurrent()` 仍要调**(防 watcher 立刻把 self-write 那次 changeCount 当成新 capture)。

## SearchPanelController.onPaste 签名

```swift
private let onPaste: ([Item]) -> Void
```

Enter 路径 (行 91-104):

```swift
case 36, 76:
    let items = state.selectedItems.isEmpty
        ? state.currentItem.map { [$0] } ?? []  // 没显式多选 → 取 currentItem 兜底
        : state.selectedItems
    guard !items.isEmpty else { break }
    // Cmd+Return reveal 仅对单选生效(多选 reveal 语义不清)
    if isCmd && items.count == 1,
       items[0].kind == .file || items[0].kind == .image {
        self.onReveal?(items[0])
    } else {
        self.onPaste(items)
    }
```

双击 row (SearchView 行 467-471) 传 `[item]`:

```swift
.gesture(
    TapGesture(count: 2).onEnded {
        onPaste([item])  // 双击始终单条,无视 selectedIDs
    }
)
```

AppDelegate 注册回调处 (行 154-159 大概) 改成 `onPaste: { [weak self] items in self?.pasteBack(items) }`。

## 兼容性 / 已知妥协

1. **多选 rtf/html 丢富文本表示**——合并后只写 `.string`。原单选 rtf 会同时 setString `.rtf` + `.string`。reviewer 决策点:富文本场景多选拼接本来就语义模糊(多份 rtf 拼起来未必合法),plain 是安全降级
2. **togglePin (⌘P) 仍只对 currentItem 单项操作**——多选 pinned toggle 语义另议,本 plan 不动
3. **filter chip 切换不丢已选项**——`updateSelection.kept` 保留还在 results 里的 id;多选行被切走时自动从 selectedIDs 跳过(`selectedItems` compactMap 兜底)
4. **panel 关闭清空 selectedIDs**——不需要显式清,下次 show 时 SearchView 第一次 refresh 会调 updateSelection;但 anchorID 跨 show 保留(若用户重新打开 panel,上次 anchor 可能已经被 filter 掉,shift+点会退化成单选,无害)

## 关键不变量

- **selectedIDs 顺序 = paste 拼接顺序**:cmd+点 append 到末尾,shift+点按 results 列表顺序整段替换(不按点击顺序)。**单元测试钉这条**
- **anchor 跟着 cmd+点 / 普通点 / 箭头走,不跟着 shift+点走**——Finder 行为
- **多选拼接 fallback 时**(降级路径)`selectedIDs[0]` 是 paste 首项——按用户最早 cmd+点的那个 / 普通点的那个;不是 anchor

## 验证

1. `swift build && swift test --filter Copyback` — `CopybackMergedTests`:
   - text 多项拼接顺序 = items 数组顺序
   - file 多项 URLs 顺序保持 + 不存在路径过滤掉
   - 全空 textFull → 返回 false 不写 pasteboard
2. `swift test --filter AppStateSelection` — 状态机:
   - cmd+点 append + 重复 cmd+点 toggle off
   - shift+点 + 已有 anchor → range 展开 + anchor 不变
   - shift+点 没 anchor → 退化单选 + anchor 设置
   - navigate(by:) 重置多选
   - refresh 时 filter 掉不在 results 里的 id
   - filter chip 把所有选中行排除 → 退化单选 results.first
3. 装 dev 二进制 (`launchctl bootout` daemon → `./scripts/install-agent.sh`),手测:
   - 普通单击 → 单选(回归)
   - cmd+点 3 条文本 → Enter → 拼接 `\n` 粘贴到 TextEdit (3 行)
   - shift+点 range → Enter → 按列表顺序拼接
   - cmd+点 2 个文件 → Enter → Finder paste 2 个文件
   - cmd+点 1 文本 + 1 图 → Enter → banner "跨类型多选不可合并,已 paste 第 1 项" + 文本进 pasteboard
   - cmd+点 2 图 → Enter → banner "多图片多选不可合并" + 首图(走 lazy 拉 blob 路径)进 pasteboard
   - 多选 → Esc → 重开 panel → selectedIDs 自然清(因为 refresh.queryIsEmpty 强制首项)
   - 双击任一行 → 直接 paste 该行(无视当前 selectedIDs)
   - cmd+点选了 3 条 → 切 "图片" chip 过滤 → 选中态正确(只剩 chip 命中的;0 项时退化单选首项)

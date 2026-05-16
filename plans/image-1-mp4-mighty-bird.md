# 搜索面板筛选 UX 重构 Plan

## Context

当前搜索面板存在三个 UX 问题：

1. **卡片 footer 冗余**：图片/视频卡片本身就是缩略图，footer 再写"图片文件 · now"是视觉噪音
2. **chip 行塞不下**：`[文本][图片][链接][文件][富文本][HTML]` 6 个基础 + `[视频][PDF][音频][图片文件]` 4 个 sub-kind = 10 个 chip 横排，panel 收窄时只能横向滚动
3. **筛选维度不可扩展**：未来要支持 `.java/.c/.py` 这种按扩展名筛选，再加 chip 不现实

本轮改动目标：
- footer 给图片/视频卡省略 kind 字，让卡片自己说话
- chip 默认收起到 4 个高频 + "更多 ▾" Menu
- 搜索框引入 `/qualifier` 语法（slash 命令），跟 chip 双轨并存
- "图片"概念合并：原生剪贴板图片（kind=image）跟文件路径里的 .png/.jpg（file+imageFile sub-kind）对用户透明合一
- mp3/mp4/.java/.c 仍按文件名匹配（走 textFull suffix），不做 extractedText 派生抽取（留后续 plan）

---

## 1. 卡片 footer 改造

**位置**：`Sources/duo-pasted/SearchView.swift:1473-1481`（`footerMeta`）

**新规则**：

| 卡片类型 | footer 格式 |
|---|---|
| `kind=image`（原生剪贴板图片） | `尺寸 · 时间`（无文件名，省略 kind 字） |
| `kind=file` + `sub=imageFile` | `文件名 · 尺寸 · 时间`（省略 kind 字） |
| `kind=file` + `sub=video` | `文件名 · 尺寸 · 时间`（省略 kind 字） |
| `kind=file` + `sub=pdf` | `PDF · 尺寸 · 时间`（保留） |
| `kind=file` + `sub=audio` | `音频 · 尺寸 · 时间`（保留） |
| `kind=text/rtf/html/url` 等 | `kindLabel · 时间`（保留） |
| `kind=file` 无 sub-kind | `文件 · 时间`（保留） |

**实现**：

- 新增 `private var firstFileName: String?` helper：复用 `previewText` 在 `SearchView.swift:1542-1547` 处理 file kind 的逻辑（`textFull.split("\n").first → URL(fileURLWithPath:).lastPathComponent`）。CaptureService 在 `Sources/DuoPasteCore/CaptureService.swift:229-230` 写入的 textFull 就是 `\n`-join 路径串
- `footerMeta` 按上表 switch，`compactMap` 过滤 nil 后 join " · "

**风险**：低。仅改 SwiftUI 渲染逻辑，无数据层改动。

---

## 2. chip 折叠 + "更多 ▾" Menu

**位置**：`Sources/duo-pasted/SearchView.swift:505-555`（`compactFilterBar`）+ `775-782`（chip 顺序定义）

**Primary chip（默认显示，4 个 + 控件）**：
```
[文本] [图片] [链接] [PDF] [更多 ▾] [✕] [仅置顶] [时间窗 ▾]
```

**Secondary chip（"更多 ▾" Menu 内，6 个）**：
```
[富文本] [HTML] [视频] [音频] [图片文件单独*] [文件]
```
*"图片文件" 在 secondary 是因为 primary 的 [图片] 已经合并两种来源；保留独立 chip 让用户在需要时仍能精准筛"只要文件路径里的图片，不要原生截图"

**[图片] chip 的合并语义**：
- 计数：`kindCounts[.image] + fileSubKindCounts[.imageFile]`
- 选中：同时把 `.image` 加进 `selectedKinds` + 把 `.imageFile` 加进 `selectedFileSubKinds`
- 高亮：任一在并集里出现即高亮

**[更多 ▾] 实现**：SwiftUI `Menu("更多")`，菜单项 `Button` label 是 HStack `Image(systemName: 选中 ? "checkmark" : "")` + name + `Text("(N)")`。点击复用现有 `toggleKind` / `toggleFileSubKind`。menu 按钮上若 secondary 里有任一选中，按钮加个 `•` accent dot badge。

**风险**：SwiftUI `Menu` 在 nonactivating HUDPanel 内的弹出可靠性。**先 spike 一个最小 Menu 验证**，不行切 NSPopover 或 SwiftUI `.popover(isPresented:)`。

---

## 3. slash qualifier 解析器

**新建** `Sources/DuoPasteCore/QueryParser.swift`（~80 行）

```swift
public enum QueryQualifier: Equatable, Sendable {
    case kind(ItemKind)
    case fileSubKind(FileSubKind)
    case textSuffix(String)        // ".java" / ".c" / ".py" 等
    case imageMerged               // /image /png /jpg → 命中 kind=.image OR sub=.imageFile
}

public struct ParsedQuery: Equatable, Sendable {
    public let text: String                  // 剥掉 /xxx 后的搜索文本
    public let qualifiers: [QueryQualifier]  // 保留输入顺序、去重
}

public enum QueryParser {
    public static func parse(_ raw: String) -> ParsedQuery
    public static func render(text: String, qualifiers: [QueryQualifier]) -> String
    public static func suggestions(prefix: String) -> [(display: String, qualifier: QueryQualifier)]
}
```

**别名字典**（小写 key）：

| 输入 | 映射 |
|---|---|
| `/text /url /file /rtf /html` | `.kind(.text)` 等 |
| `/image /img /png /jpg /jpeg /gif /webp /heic` | `.imageMerged` |
| `/video /mp4 /m4v /mov /mkv` | `.fileSubKind(.video)` |
| `/audio /mp3 /m4a /wav /flac` | `.fileSubKind(.audio)` |
| `/pdf` | `.fileSubKind(.pdf)` |
| `/imagefile /image-file` | `.fileSubKind(.imageFile)`（精准只要文件路径图片） |
| `/java /c /cpp /py /swift /go /rs /ts /js /rb` | `.textSuffix(".java")` 等 |

**解析规则**：
1. 空白拆 token；`/xxx` 查表 → qualifier；非 `/` 开头 → text 部分
2. 未识别 `/xxx` → 保留原 token 进 text（避免输错 `/imgae` 突然没结果）
3. 大小写 → `lowercased()` 统一查表
4. 同 qualifier 重复 → 去重保留首次
5. text 部分保留 token 间单空格

---

## 4. SearchQuery 字段扩展

**位置**：`Sources/DuoPasteCore/Search.swift:4-37`

**新增字段**：
```swift
public var textFullSuffixes: [String]  // [".java", ".c"] 等，OR 关系
```

**SQL 端**（`Search.swift:309-322` `buildKindPredicate`）：跟现有 `subKindSQL` 同位置加 OR 子句：
```swift
for suffix in q.textFullSuffixes {
    args.append("%" + suffix.lowercased())
    clauses.append("LOWER(IFNULL(item.text_full,'')) LIKE ?")
}
```

**fold-after-filter**（`Search.swift:126-139`）：oversample 路径必须把 textFullSuffixes 加进后置 filter 保留逻辑：
```swift
let suffixes = q.textFullSuffixes.map { $0.lowercased() }
if !suffixes.isEmpty, let tf = item.textFull?.lowercased(),
   suffixes.contains(where: { tf.hasSuffix($0) }) { return true }
```

**`countByKind` / `countByFileSubKind`**：传入 SearchQuery 时**保留** textFullSuffixes（跟 chip 维度无关，是搜索维度）。`Search.swift:260-278` 现有 strip 逻辑只动 kinds/fileSubKinds，suffix 不动。

**理由**：`.java` 走 FTS5 不可靠（unicode61 tokenizer 吃掉 `.`），LIKE 后缀匹配跟现有 sub-kind ext 路径同构。

---

## 5. AppState 集成

**位置**：`Sources/duo-pasted/AppState.swift`

**新增字段 / 计算属性**：
```swift
var parsedQuery: ParsedQuery { QueryParser.parse(query) }
var completionMenuVisible: Bool = false
var completionHighlight: Int = 0
var completionCandidates: [(String, QueryQualifier)] = []

func isKindActive(_ k: ItemKind) -> Bool {
    selectedKinds.contains(k) || parsedQuery.qualifiers.contains { q in
        if case .kind(k) = q { return true }
        if k == .image, case .imageMerged = q { return true }
        return false
    }
}
func isFileSubKindActive(_ sub: FileSubKind) -> Bool { /* 类似 */ }
func clearAllFilters()  // 清 chip selection + 剥 query 里所有 /xxx token
```

**`refresh()` 改造**（约 `AppState.swift:280-316`）：构造 SearchQuery 时把 `parsedQuery.qualifiers` 跟 `selectedKinds`/`selectedFileSubKinds` 取**并集**：
- `.kind(k)` / `.imageMerged` → 加进 `kinds`
- `.fileSubKind(s)` / `.imageMerged` → 加进 `fileSubKinds`
- `.textSuffix(s)` → 加进新字段 `textFullSuffixes`
- text 部分用 `parsedQuery.text` 而非原 `query`

**`filterID`**（`AppState.swift:86-90`）：现有 `query` 已含 slash token，无需改。

**[图片] chip 选中逻辑**（KindChip 点击回调）：toggle 时同时操作 `selectedKinds.insert(.image)` + `selectedFileSubKinds.insert(.imageFile)`，反之同时移除。

**[图片] chip 计数**：`KindChip` count 参数特殊处理：
```swift
let imageCount = (state.kindCounts[.image] ?? 0) + (state.fileSubKindCounts[.imageFile] ?? 0)
```

---

## 6. 自动补全 UI

**位置**：`Sources/duo-pasted/SearchView.swift:676-702`（`header` 块）

**实现方式**：SwiftUI `overlay(alignment: .topLeading)` 在 TextField 下方画自定义浮层（`VStack(候选行)` + 圆角 + ultraThinMaterial 背景）。**不**用 Menu/独立 NSPanel，避免抢 TextField 焦点。

**显示触发**：`state.query` 末尾的当前 token 以 `/` 开头且未闭合（即 `query.split(by: " ").last?.hasPrefix("/") == true`）→ `state.completionMenuVisible = true` + `completionCandidates = QueryParser.suggestions(prefix: 当前 token)`

**键盘导航 / NSEvent local monitor 协作**（**关键风险点**）：

`SearchPanelController.installKeyMonitor`（约 `SearchPanelController.swift:124-234`）当前把 ↑↓/Enter/Esc 一律截走给卡片导航。补全菜单需要相同按键。

**方案**：在 keyDown switch 路由前先判 `state.completionMenuVisible`：
- 显示中 → ↑↓ 改 `completionHighlight`、Enter 替换当前 token + 关菜单、Esc 关菜单 —— **不**传给卡片导航也**不**透传 TextField
- 未显示 → 走原逻辑

**已选 qualifier 显示**：纯字符串（`/pdf hello`），不做 token chip。键盘删 `/pdf` 即撤销。

---

## 7. chip ↔ slash 双向同步策略

**单向写、双向显**：

- `selectedKinds` / `selectedFileSubKinds` 是 chip 状态 source of truth
- 用户输 `/pdf` → parser 解析 → refresh 时跟 chip selection 取并集传给 SQL
- chip 高亮判定走 `isKindActive(_:)` helper（chip selection ∪ slash qualifier）
- 用户点 chip → **只改** chip selection，**不**往 query 字符串塞 `/pdf`（避免回写导致光标跳）
- ✕ 清除按钮调 `clearAllFilters()` 同时清 chip selection + 用 `QueryParser.render(text:qualifiers:[])` 剥 query 里 slash token

---

## 8. 测试

**新增** `Tests/DuoPasteCoreTests/QueryParserTests.swift`（~120 行）：
- 基本：`"hello"` → text=hello, qualifiers=[]
- 单 qualifier：`"/pdf hello"` → text=hello, q=[.fileSubKind(.pdf)]
- 多 qualifier OR：`"/pdf /image hello world"` → text="hello world", q=[.fileSubKind(.pdf), .imageMerged]
- ext alias：`"/mp4"` → q=[.fileSubKind(.video)]，`"/jpg"` → q=[.imageMerged]
- 代码 ext：`"/java foo"` → q=[.textSuffix(".java")], text=foo
- imagefile 精准：`"/imagefile"` → q=[.fileSubKind(.imageFile)]，**不**等价 `/image`
- unknown qualifier：`"/imgae hello"` → text="/imgae hello", q=[]（fallback）
- 大小写：`"/PDF"` ≡ `"/pdf"`
- 去重：`"/pdf /pdf hello"` → q=[.fileSubKind(.pdf)]
- render round-trip 稳定

**新增** `Tests/DuoPasteCoreTests/SearchQuerySuffixTests.swift`（~80 行，依赖 in-memory Database fixture，参考现有 Tests setup）：
- 插一组 .file kind 行 textFull=`/x/y.java`、`.swift`、`.png`
- `SearchQuery(textFullSuffixes: [".java"])` 只命中 java 行
- imageMerged 等价：`SearchQuery(kinds:[.image], fileSubKinds:[.imageFile])` 命中两种存储
- count 维度：`countByKind` 在 textFullSuffixes 非空时只数后缀命中行

**UI 行为**不进 swift test（基建未就绪），手动验证见下。

---

## 9. 验证

1. `swift build && swift test` 全绿（含新增 QueryParser/SearchQuerySuffix 测试）
2. `./scripts/install-agent.sh` 装 release（先 `launchctl bootout` 旧 daemon）
3. 手动 checklist：
   - footer 文案：text/url 各一张（保留 kind）；image 一张（"442 KB · now"）；file+pdf（"PDF · 193 KB · 12m"）；file+video（"demo.mp4 · 5.2 MB · 1d"）；file+imageFile（"shot.png · 442 KB · 12m"）；file 无 sub（"文件 · 12m"）—— 截图核对
   - chip 折叠：primary 横向不溢出（4 chip + 更多 + ✕ + 仅置顶 + 时间窗）
   - "更多 ▾" Menu：点开 6 项 + count + 多选 + checkmark；选中后按钮显示 `•` badge
   - 输 `/im` → 弹补全菜单 → ↓ 选第二项 → Enter → query 变 `/imagefile`，列表立刻筛选
   - chip ↔ slash 同步：输 `/pdf` → PDF chip 高亮；点 PDF chip → query 文本不变但列表跟 slash 等效
   - [图片] chip 选中 → 同时命中 NSPasteboard 截图 + Finder 复制的 .png 文件
   - ✕ 清除：同时清 chip selection + 剥 query 里 `/xxx`
   - 输 `/java foo` → 命中 `~/proj/main.java` 路径（FTS 命中 foo + suffix 命中 .java）

4. **边界**：
   - `/` 在 text 中（`a/b`）：parser 只剥独立 `/xxx` token，含义不变
   - 空 text + 仅 qualifier：走 non-FTS path（已有支持）
   - qualifier 大小写：parser 内 lowercase 统一
   - 多个相同 qualifier：去重

---

## 10. 文件修改清单

| 文件 | 改动 | 大致行数 |
|---|---|---|
| `Sources/DuoPasteCore/QueryParser.swift` | **新建**：解析器 + 别名字典 + suggestions API | ~80 |
| `Sources/DuoPasteCore/Search.swift:4-37` | `SearchQuery` 加 `textFullSuffixes` | ~5 |
| `Sources/DuoPasteCore/Search.swift:309-322` | `buildKindPredicate` 加 suffix OR 子句 | ~6 |
| `Sources/DuoPasteCore/Search.swift:126-139` | fold 后置 filter 加 suffix 分支 | ~5 |
| `Sources/duo-pasted/AppState.swift` | `parsedQuery` / `completionMenuVisible` / `isKindActive` / `isFileSubKindActive` / `clearAllFilters` / `refresh()` 并集 | ~40 |
| `Sources/duo-pasted/SearchView.swift:1473-1481` | `footerMeta` 按 kind/sub-kind 重写 + `firstFileName` helper | ~30 |
| `Sources/duo-pasted/SearchView.swift:505-555 / 775-782` | `compactFilterBar` 拆 primary/secondary + "更多 ▾" Menu + [图片] 合并计数 | ~50 |
| `Sources/duo-pasted/SearchView.swift:676-702` | `header` 加补全 overlay + 候选浮层 view | ~70 |
| `Sources/duo-pasted/SearchPanelController.swift:124-234` | `installKeyMonitor` 加 `completionMenuVisible` 分流 | ~25 |
| `Tests/DuoPasteCoreTests/QueryParserTests.swift` | **新建** | ~120 |
| `Tests/DuoPasteCoreTests/SearchQuerySuffixTests.swift` | **新建** | ~80 |

**总计**：~511 行，2 新文件 + 5 修改文件

---

## 风险点 / Review 重点

1. **SwiftUI Menu 在 HUDPanel 弹出可靠性** —— spike 验证；不行切 `.popover(isPresented:)` 或自绘 NSPopover
2. **NSEvent local monitor 优先级** —— `installKeyMonitor` 的 switch case 顺序敏感，加新 `completionMenuVisible` 分支必须在 `interceptCodes` guard **之前**，否则补全菜单的 ↑↓ 会跟卡片导航打架
3. **`fetchHitsFolded` 三处口径一致性** —— `searchHits` / `count` / `countByKind` / `countByFileSubKind` 同源；新加 `textFullSuffixes` 必须四处都正确处理（count 系列**不**像 kinds 那样 strip suffix，因为 suffix 是搜索维度而非 chip 维度）。CLAUDE.md 的 SearchAPI 不变量"list / total / chip 三者口径一致"是硬约束
4. **[图片] chip 合并的 SQL OR 语义** —— `selectedKinds=[.image]` + `selectedFileSubKinds=[.imageFile]` 需要走 OR 拿到两种行；现有 `buildKindPredicate` 已是 OR（`Search.swift:309-322` + fold 后置 filter `:126-139`），无需新增 SQL，只需在 chip toggle 时同时操作两个 Set
5. **`.imageMerged` qualifier 跟现有 SearchQuery 字段映射** —— 解析后落地是把 `.image` 加进 `kinds` 同时把 `.imageFile` 加进 `fileSubKinds`，不是 SearchQuery 加新字段。让 SQL 端零改动（OR 已支持）

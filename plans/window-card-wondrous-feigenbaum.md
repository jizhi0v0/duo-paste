# 搜索 card 右键菜单 — Open With / 文本编辑器

> [!CAUTION]
> **已归档；不可作为部署说明。** 现行部署见 [`README.md`](../README.md) 与
> [`docs/deploy-multi-mac.md`](../docs/deploy-multi-mac.md)；未来工作只看
> [`docs/roadmap.md`](../docs/roadmap.md)。

## Context

搜索 panel 的每张 card 目前**完全没有右键菜单**（`SearchView.swift:813-849` 只有双击 paste / 单击 select / Cmd 多选 / Shift 区间选）。用户希望右键 card 能"用 XXX 打开"，类似 Finder 的 Open With。

需求拆解（已跟用户确认）：
- **按 kind 动态查 LaunchServices**——不同 kind 出不同列表（text/rtf/html → 文本编辑器优先；image → Preview/Pixelmator 等；pdf/file → UTType handler；url → 浏览器）
- **"文本编辑器"识别策略**：`urlsForApplications(toOpenContentType: .plainText)` + bundle ID 黑名单过滤掉 Word/Pages/Numbers/Preview/Adobe Reader 等 viewer/office
- **菜单末尾给 Other…**（不持久化最近选择，跟 Finder 行为对齐）

预期产出：右键 card → 二级 submenu，用户选项后系统调起目标 app 打开当前 item 内容（text/image/pdf 等先写临时文件再 open；file kind 直接 open 已有路径；url kind 走浏览器）。

---

## 关键设计点

### 1. 按 kind 路由 UTType（动态查 LaunchServices）

新模块 `Sources/DuoPasteCore/OpenWithProvider.swift`，纯函数无状态：

```swift
public enum OpenWithCategory {
    case textEditor          // text/rtf/html kind → 走 .plainText handler + 编辑器黑名单
    case browser             // url kind → 浏览器列表（urlsForApplications(toOpen: https://...)）
    case viewer(UTType)      // image/pdf/file kind → 对应 UTType handler
    case filePath(URL)       // file kind 且本机路径存在 → 用文件 URL 查（最准）
}

public struct OpenWithApp: Sendable, Hashable {
    public let bundleURL: URL
    public let bundleID: String?
    public let displayName: String
    public let isDefault: Bool       // category 的默认 handler 标 true 排首位
}

public enum OpenWithProvider {
    public static func category(for item: Item) -> OpenWithCategory { ... }
    public static func apps(for category: OpenWithCategory) -> [OpenWithApp] { ... }
    public static func textEditorBlacklist: Set<String> { ... }
}
```

**kind → category 映射**：
| Item kind | category | UTType / URL |
|---|---|---|
| `.text` | `.textEditor` | `.plainText` + 黑名单 |
| `.rtf` | `.textEditor` | `.plainText` + 黑名单（不用 `.rtf`——RTF handler 列表会带回 Word/Pages，绕了一圈） |
| `.html` | `.textEditor` | `.plainText` + 黑名单 |
| `.url` | `.browser` | `urlsForApplications(toOpen: URL(string: "https://example.com")!)` |
| `.image` | `.viewer(.image)` | 父类 `.image` 让 PNG/JPEG/HEIC 都覆盖 |
| `.file` with `blobMime="application/pdf"` 或 path 后缀 `.pdf` | `.viewer(.pdf)` | `.pdf` |
| `.file` 其他，本机路径存在 | `.filePath(url)` | 直接 `urlsForApplications(toOpen: fileURL)` 最准 |
| `.file` 其他，路径不存在但有 blob | `.viewer(...)` | 按 `blobMime` 推 UTType；推不出走 `.data` fallback |

**黑名单**（写死在 `OpenWithProvider`，~10 个 bundle ID，注释里加 # 标各自分类，便于未来增删）：
```
com.apple.Preview, com.apple.QuickLookUIService,
com.microsoft.Word, com.apple.iWork.Pages, com.apple.iWork.Numbers, com.apple.iWork.Keynote,
com.adobe.Reader, com.readdle.PDFExpert-Mac,
com.apple.Notes, com.apple.mail
```

### 2. 临时文件落地策略

新模块 `Sources/DuoPasteCore/OpenWithStaging.swift`：

- 目录：`~/Library/Application Support/duo-paste/openwith-tmp/<uuid>/`（**不用 /tmp**——sandbox 会清，且目标 app lazy 读时文件可能消失）
- 文件名：`<readable-prefix>.<ext>`——prefix 取 item.preview 前 30 字符做 sanitize（让 VS Code 标题栏显示"clip-snippet.txt"而不是 uuid），扩展名按 kind+mime 推
- 清理：daemon 启动时 (`AppDelegate.applicationDidFinishLaunching`) 扫描 openwith-tmp，删 mtime > 24h 的子目录（lazy 读窗口够大，又不会无限堆积）
- file kind 已经是真实路径 → **不复制**直接 open
- url kind → 字符串 URL 直接 `NSWorkspace.shared.open(url, configuration:withApplicationAt:)`（不写盘）

```swift
public enum OpenWithStaging {
    public static func materialize(item: Item, blobs: BlobStore) throws -> URL
    public static func cleanupOldStaging(olderThanHours: Int = 24)
}
```

text kind 写 `text_full` 的 UTF-8 字节到 `.txt`；rtf/html 同理（用 `.rtf`/`.html` 扩展名，让目标 app 自己解码）；image/pdf 从 `blobs.locate(sha256:)` 拿 blob URL → 复制到 staging（保留 `.png`/`.pdf` 扩展名，从 `blobMime` 推）。

**blob 不在本机的 case**——复用 AppDelegate 现有 `fetchBlobLazy` 路径异步拉，跟 `openBlobBackedItem` (`AppDelegate.swift:555-589`) 同模式。

### 3. UI：SwiftUI `.contextMenu` 挂在 ItemCard 上

`SearchView.swift` 第 813-849 行的 ItemCard 渲染处加 `.contextMenu` modifier（不是改 ItemCard 本体——保持 ItemCard 单一职责，菜单逻辑由外层 SearchView 注入）：

```swift
.contextMenu {
    // 主操作（跟键盘 ⌘Return / Enter 对齐）
    Button("粘贴") { onPaste([item]) }
    if item.kind == .file || item.kind == .image { Button("在 Finder 显示") { onReveal(item) } }
    Divider()
    OpenWithMenu(item: item, onOpenWith: onOpenWith)
    Divider()
    // 已有的 pin/delete 走原有 AppState method
}
```

`OpenWithMenu`：自治 SwiftUI View，`.task { apps = await OpenWithProvider.apps(...) }` 异步加载 app 列表 + icon，避免首次右键卡 main thread。loading 期间显示 progress placeholder。

**Submenu 结构**：
```
Open With ▶
  ├─ [icon] VS Code (Default)
  ├─ ────────────
  ├─ [icon] Sublime Text
  ├─ [icon] TextEdit
  ├─ [icon] BBEdit
  ├─ ────────────
  └─ Other…
```

text kind 时 submenu 标题改成 "在文本编辑器打开"；其他 kind 用 "Open With"。

**Icon**：`NSWorkspace.shared.icon(forFile: url.path)` + `size = NSSize(16,16)`，SwiftUI 里包成 `Image(nsImage:)`。icon load 走 `Task.detached`（首次 IconServices 10 个 app ~100ms），先以 systemImage placeholder 渲染，加载完 publish 替换。

**Other…**：点击 → 起 `NSOpenPanel`（`allowedContentTypes = [.application]`、`directoryURL = /Applications`），用户选完调用 `onOpenWith(item, selectedAppURL)` 走同一路径。

### 4. 回调链路（跟现有 onPaste/onReveal 同构）

```
ItemCard contextMenu OpenWithMenu pick
  ↓
SearchView.onOpenWith(item, appURL) 闭包                  [新增]
  ↓
SearchPanelController.init(onOpenWith: closure)          [新增 init 参数]
  ↓
AppDelegate.applicationDidFinishLaunching 注册
  → onOpenWith: { [weak self] item, app in self?.openWith(item, app: app) }
  ↓
AppDelegate.openWith(_ item: Item, app: URL)             [新增 method]
  ├─ materialize → URL（或 file kind 直接 item.fileURL；url kind 直接 String）
  ├─ NSWorkspace.OpenConfiguration { addsToRecentItems = false; activates = true }
  ├─ try await NSWorkspace.shared.open([fileURL], withApplicationAt: app, configuration: config)
  └─ panel.hide()  // 跟 revealInFinder 同样收尾
```

**lazy blob 路径**：openWith 内部如果 `blob` 不在本机 → 复用 `pasteBlobFetcher` 异步拉（同 `openBlobBackedItem` 模式），期间 panel.pasteProgress = `.fetching(...)`，拉完再走 NSWorkspace.open。失败 → `.failed(reason:)` banner。

**取消**：panel hide / Esc → 复用现有 `currentPasteTask?.cancel()` 路径（`AppDelegate.swift:556-558`），openWith task 注册到同一 currentPasteTask 让 panel dismiss 时同样 cancel。

### 5. 不做 / 后续

- **不做**最近用过 app 持久化（用户选 "Other..." 后不进 config，每次重新选）
- **不做**Settings UI 调整黑名单（MVP 黑名单写死，~10 个，覆盖 99% 实际场景；后续按反馈再开放）
- **不做**VS Code/Sublime 私有 URL scheme（`vscode://` `subl://`）跳过临时文件——MVP 全部走临时文件统一路径
- **不做**`.sourceCode` 交集 boost（漏 iA Writer/Bear 之类纯文本编辑器，得不偿失）

---

## 关键文件

**新增**：
- `Sources/DuoPasteCore/OpenWithProvider.swift` — kind→category 映射、`apps(for:)` 调 NSWorkspace、黑名单
- `Sources/DuoPasteCore/OpenWithStaging.swift` — materialize 写临时文件 + cleanupOldStaging
- `Sources/duo-pasted/OpenWithMenu.swift` — SwiftUI `Menu` View，异步加载 app+icon
- `Tests/DuoPasteCoreTests/OpenWithProviderTests.swift` — 验证 kind→category 映射、黑名单过滤（mock NSWorkspace 不现实，主测纯逻辑分支）

**修改**：
- `Sources/duo-pasted/SearchView.swift:809-849` — ItemCard 加 `.contextMenu { ... }` + onOpenWith 参数
- `Sources/duo-pasted/SearchPanelController.swift:14-17` — init 新增 `onOpenWith` 闭包参数，存成 property 透传给 SearchView
- `Sources/duo-pasted/AppDelegate.swift` — applicationDidFinishLaunching 注册 onOpenWith；新增 `openWith(_:app:)` method（参考 `openBlobBackedItem:555` 同模式）；launch 时调 `OpenWithStaging.cleanupOldStaging()`

**复用现成代码**（不要重写）：
- `AppDelegate.fileURLs(from:)` `:547-553` — file kind 拿真实 URL
- `AppDelegate.openBlobBackedItem` `:555-589` — lazy blob fetch + NSWorkspace.open 模式
- `AppDelegate.fetchBlobLazy` — 5s TaskGroup race timeout（lazy 拉 blob 后写 staging 完全复用）
- `BlobStore.locate(sha256:)` — 拿本机已落地 blob URL
- `ItemSubKind` (Sources/DuoPasteCore/ItemSubKind.swift) — 已有 blobMime→ pdf/video/audio/imageFile 分类，推 UTType 时复用

---

## 验证

**单测**：
```sh
swift test --filter OpenWithProviderTests
```
覆盖：
- `category(for: Item)` 6 种 kind 的映射正确（text/rtf/html → textEditor；image → viewer(.image)；file+pdf mime → viewer(.pdf)；file+其他 → filePath）
- 黑名单过滤：mock 一个含 Word/Pages 的 URL 列表，apps() 返回应不含黑名单 bundleID

**手动 E2E**（按 CLAUDE.md "开发工作流" 走）：
1. `swift build && swift test`
2. `launchctl bootout gui/$UID/io.duopaste.agent` → 跑 dev 二进制
3. 复制几条不同 kind 的内容：纯文本 / URL / 截图 / PDF 文件路径
4. 唤起搜索 panel，右键每张 card：
   - **text**：submenu 标题"在文本编辑器打开"，列表里有 VS Code/TextEdit 但**没有** Word/Pages，选 VS Code → 临时 .txt 在新 tab 打开
   - **url**：submenu 列 Safari/Chrome/Arc，选一个 → 浏览器打开 URL
   - **image**：submenu 列 Preview + 装的其他图片 app，选 Preview → 图片打开
   - **pdf file**：列 Preview / PDF Expert / Adobe Reader（如装），选一个 → PDF 打开
   - **任意 kind**：末尾 Other… → NSOpenPanel 弹出指向 /Applications，选个 app 后能 open
5. 重复打开同一 card 右键——第二次菜单出现应明显更快（LaunchServices warm cache + icon cache 生效）
6. 临时文件清理：手动 touch 一个 25h 前的 staging 目录 → 重启 daemon → 该目录消失
7. blob 不在本机 case（mesh 另一端独有的图片）：右键 → Open with Preview → pasteProgress 显示 fetching → 拉完 Preview 打开；中途 Esc panel hide → task cancel，Preview 不打开

**回归不能挂**：
- `swift test`（~270 个）全绿
- 现有 `.file/.image` 在 Finder 显示 / Preview 打开行为不变（revealInFinder 没改动，只是右键菜单多了一个并列入口）
- 双击 / 单击 / Cmd+多选 / Shift+区间选 行为不变（`.contextMenu` 是新增 modifier，跟 `.gesture` `.simultaneousGesture` 不冲突）

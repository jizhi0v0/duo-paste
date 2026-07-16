# macOS "Open With" 菜单——技术调研

> [!CAUTION]
> **已归档；不可作为部署说明。** 现行部署见 [`README.md`](../README.md) 与
> [`docs/deploy-multi-mac.md`](../docs/deploy-multi-mac.md)；未来工作只看
> [`docs/roadmap.md`](../docs/roadmap.md)。

研究范围：搜索结果右键菜单加 Finder 风格的"用 XXX 打开"。目标 macOS 14+（实际跑 macOS 26 SDK）。仅基于 Apple 公开文档 / Apple Forum (Quinn) / WWDC 资料 / 真实开源项目代码（SwiftDefaultApps、ghostty、xc）。

---

## 1. 枚举"能打开某类内容的 app 列表"

**当前唯一推荐姿态（macOS 12+）**：`NSWorkspace.shared.urlsForApplications(toOpen:)` 两个重载。

```swift
// 取 UTType（首选，cheaper，不需要真实文件）
func urlsForApplications(toOpenContentType: UTType) -> [URL]   // macOS 12+
// 取 URL（如果手上有真实文件路径走这个，会读 file 自己的 UTI / extended attrs）
func urlsForApplications(toOpen: URL) -> [URL]                 // macOS 12+
// 拿默认 app
func urlForApplication(toOpenContentType: UTType) -> URL?      // macOS 12+
func urlForApplication(toOpen: URL) -> URL?                    // macOS 12+
```

返回值已经按 LaunchServices 排序，**默认 app 在 `[0]`**（Apple Forum Quinn 回复隐含确认；ghostty / xc / Lord-Kamina 三个开源项目都按这个假设用）。剪贴板管理器场景应该传 UTType，不传 URL——我们的内容大多还在内存里没写盘。

**性能**：LaunchServices 维护进程内 + 系统级 DB，调一次基本是查 plist + 内存索引，不扫盘（eclecticlight.co 提到 macOS 用 Spotlight index 维护这个 DB，但查询本身走 LaunchServices in-memory cache）。可以每次右键现查，不需要缓存到自家 SQLite。**第一次调用** cold path 会触发 LaunchServices DB 加载，第一次有 ~50-200ms cold cost——首次打开 panel 时跑个 warm-up 异步预热即可。

**已 deprecated 不要再写新代码用**（Quinn 在 Apple Forum 749039 明确说"Use NSWorkspace 代替"）：

| 老 API | 状态 | 替换 |
|---|---|---|
| `LSCopyApplicationURLsForURL` | deprecated macOS 12 | `urlsForApplications(toOpen:)` |
| `LSCopyAllRoleHandlersForContentType` | deprecated macOS 12 | `urlsForApplications(toOpenContentType:)` |
| `LSCopyDefaultApplicationURLForContentType` | **未** deprecated，但 NSWorkspace 重载更现代 | `urlForApplication(toOpenContentType:)` |
| `LSCopyApplicationURLsForBundleIdentifier` | 仍可用 | `urlForApplication(withBundleIdentifier:)` |

**关键损失**：NSWorkspace 新 API **没有** `LSRolesMask` 等价物——`URLsForApplicationsToOpenContentType:` 内部把 mask 写死成 `.viewer | .editor`（社区从行为推断；Quinn 没明确文档）。这是后面"识别文本编辑器"会回避不掉的坑。

---

## 2. 识别"文本编辑器"——没有官方 role，要混合策略

**直接的问题**：`urlsForApplications(toOpenContentType: .plainText)` 会返回所有"声称能开 plainText"的 app——Microsoft Word / Pages / Quick Look / Preview / TextEdit / VS Code / Sublime / BBEdit / Nova / Xcode 都在里头，**没法靠 UTType 本身把 Word 拣出去**。

NSWorkspace 新 API 也**没有** editor vs viewer 的 `LSRolesMask` 旋钮，所以"只列 editor"这条路被堵死。三个可选方向，按推荐度排：

**A. 动态枚举 plainText handlers + bundle ID 黑名单**（推荐）
```
let urls = NSWorkspace.shared.urlsForApplications(toOpenContentType: .plainText)
let blacklist: Set<String> = [
  "com.apple.Preview", "com.apple.QuickLookUIService",
  "com.microsoft.Word", "com.apple.iWork.Pages", "com.apple.iWork.Numbers",
  "com.adobe.Reader", "com.readdle.PDFExpert-Mac",
  // 任何已知 viewer-only 或 office suite
]
let editors = urls.filter { url in
  guard let bid = Bundle(url: url)?.bundleIdentifier else { return true }
  return !blacklist.contains(bid)
}
```
优点：覆盖用户实际装的所有 editor（包括没听过的小众），自动包括新装的。缺点：维护黑名单。**实际工程上够用**——常见 office 套件就十来个 bundle ID。

**B. 同时查 `.sourceCode` UTType 取交集**
`sourceCode` UTI 几乎只有真正的编辑器声明能 handle（VS Code / Sublime / Nova / Xcode / BBEdit / TextEdit），Word / Pages 不会声明。但**漏 TextEdit-only 用户** + 一些非代码场景的纯文本编辑器（Bear、iA Writer）可能也不声明 sourceCode。可以作为 boost 用，不能作为唯一过滤。

**C. Hardcode 白名单**（Maccy / Paste 等剪贴板管理器实际做法）
搜遍 Maccy / Paste / PasteBot 公开资料：**它们都没有"Open With 文本编辑器" feature**。所以没有"业界惯例"参考。但 Apple Notes / Mail 等系统 app 的"Send To" 菜单都是 hardcode bundle ID 白名单 + fallback "Other..."。

**推荐方案**：A + 给用户在 Settings 里加"额外屏蔽"和"额外添加"。MVP 先 A（黑名单 8-10 个），后续按需开放。

---

## 3. 不同 kind 用不同列表

**应该按 kind 动态查**，不要 hardcode 一份大全。每个 kind 对应一个 UTType：

| kind | UTType | 备注 |
|---|---|---|
| plain text / RTF / HTML | `.plainText`（或 `.rtf`、`.html`） | 跑黑名单策略 |
| URL | 用 `LSCopyDefaultHandlerForURLScheme("http")` 等枚举浏览器，或 `urlsForApplications(toOpen:)` 传一个 `https://` URL | URL scheme handler 路径独立 |
| image (PNG/JPEG) | `.png` / `.jpeg` / `.image`（父类） | Preview / Pixelmator / Acorn / Photoshop 自动出 |
| PDF | `.pdf` | Preview / PDF Expert / Adobe Reader 自动出 |
| file path | 用真实文件 URL 调 `urlsForApplications(toOpen: fileURL)` | 直接走 LaunchServices 文件级解析，最准 |

**菜单层级建议**：右键二级 submenu `Open With ▶`，里面：
1. 第一行 default app（粗体 / 带"Default"标签），= `urlForApplication(toOpenContentType:)`
2. 分隔线
3. 其他能开的 app，按 LaunchServices 顺序
4. 分隔线
5. `Other...` → `NSOpenPanel` 让用户选 `/Applications/` 任意 app

对 text kind 还可以加二级 `Open in Text Editor ▶` 用上一节的过滤策略。

---

## 4. 执行打开

**首选 modern async API**（macOS 11+）：

```swift
let config = NSWorkspace.OpenConfiguration()
config.activates = true
config.addsToRecentItems = false  // 剪贴板内容不该污染 app 的 Recent
let runningApp = try await NSWorkspace.shared.open(
  [fileURL], withApplicationAt: appURL, configuration: config
)
```

`NSWorkspace.OpenConfiguration` 主要 knob：`activates` / `addsToRecentItems` / `hidesOthers` / `createsNewApplicationInstance` / `promptsUserIfNeeded` / `arguments` / `environment` / `architecture`（macOS 11+）。macOS 14 / 26 没新增字段。

**临时文件**：text / image / pdf 内容不在文件系统里，**必须先写临时文件**才能 open with：
- 用 `FileManager.default.temporaryDirectory` 下建子目录 `duo-paste-openwith/<uuid>/`
- 文件名带可读 prefix + 正确扩展名（`.txt` / `.png` / `.pdf`），LaunchServices 靠扩展名兜底 UTI 推断
- file kind 已经是真实路径直接 open，不需要复制
- **不要**立刻删——目标 app 可能 lazy 读（VS Code 打开后用户改了再保存依赖文件还在）。建议存到 `~/Library/Application Support/duo-paste/openwith-tmp/`，daemon 启动时清理 24h 以上的旧文件

对 plain text 还有一条**不写盘**捷径：调目标 app 的 `openURLs:withCompletionHandler:` 配 `x-source-action:` 类 URL scheme（VS Code `vscode://file/...`、Sublime `subl://`），但每个 editor 私有 scheme 不一样，复杂度高，**MVP 不做**。

---

## 5. Icon / 显示名

```swift
let icon = NSWorkspace.shared.icon(forFile: appURL.path)
icon.size = NSSize(width: 16, height: 16)  // NSMenuItem 标准尺寸

let bundle = Bundle(url: appURL)
let name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        ?? bundle?.infoDictionary?["CFBundleDisplayName"] as? String
        ?? bundle?.localizedInfoDictionary?["CFBundleName"] as? String
        ?? bundle?.infoDictionary?["CFBundleName"] as? String
        ?? FileManager.default.displayName(atPath: appURL.path)  // 兜底走 Finder 显示名
```

`icon(forFile:)` 是 NSWorkspace 文档推荐路径，**内部有 cache**——同一 path 第二次基本 O(1)。但首次仍然走 IconServices，单 app ~5-20ms。10 个 app 一起初始化 menu 可能 ~100ms 卡 main thread：**预热**或**异步加载 + placeholder icon**。我们 panel 已有 lazy paste 异步态，复用同套 progress UI。

`Bundle(url:).localizedInfoDictionary` 取的是**目标 app 自己**的本地化（比如英文系统下打开中文 app，能拿到 app 自己的中文显示名）——这正是要的。

---

## 关键不变量 / 别踩的坑

1. **不要回退到 LSCopyAllRoleHandlersForContentType / LSCopyApplicationURLsForURL**——macOS 12 起 deprecated，编译会有 warning，未来 SDK 可能直接拿掉
2. **不要假设 NSWorkspace 新 API 支持 editor-only filter**——它不支持，只能后置过滤
3. **不要在 main thread 同步算 10+ 个 icon**——批量场景走 `Task.detached` + `@MainActor` 写回
4. **不要把临时文件丢 `/tmp`**——macOS sandbox 会清；用 `~/Library/Application Support/duo-paste/openwith-tmp/` 自管 24h 清理
5. **`addsToRecentItems = false`**——剪贴板的临时内容污染 Word 的 "Recent" 列表是糟糕 UX

---

## 落地建议（不是 plan code，仅供下一步参考）

阶段 1：通用 `Open With` submenu（所有 kind 都支持）
- 写 helper `OpenWithProvider.appsToOpen(uti: UTType) -> [(url, name, icon)]`
- 写 `TempFileMaker.materialize(item: ClipItem) -> URL` 把 item 写到 openwith-tmp
- 接到 `SearchView` 右键菜单

阶段 2：text kind 专门的 `Open in Text Editor`
- 白名单 / 黑名单逻辑放 `TextEditorFilter`
- Settings UI 让用户调名单

阶段 3（可选）：URL scheme 集成
- 给 VS Code / Sublime / Cursor 走 native URL scheme 跳过临时文件

---

## Sources

- [urlsForApplications(toOpen:) | Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nsworkspace/3752999-urlsforapplications)
- [NSWorkspace | Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nsworkspace)
- [NSWorkspace.OpenConfiguration | Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration)
- [LSCopyApplicationURLsForURL | Apple Developer Documentation](https://developer.apple.com/documentation/coreservices/1445148-lscopyapplicationurlsforurl)
- [LSCopyAllRoleHandlersForContentType | Apple Developer Documentation](https://developer.apple.com/documentation/coreservices/1448020-lscopyallrolehandlersforcontentt)
- [icon(forFile:) | Apple Developer Documentation](https://developer.apple.com/documentation/appkit/nsworkspace/1528158-iconforfile)
- [Apple Developer Forums thread/749039 — Quinn: "Use NSWorkspace URLsForApplicationsToOpenContentType instead"](https://developer.apple.com/forums/thread/749039)
- [Apple Developer Forums thread/700568 — openApplicationAtURL permission caveats](https://developer.apple.com/forums/thread/700568)
- [SwiftDefaultApps/LSWrappers.swift (Lord-Kamina) — 业界最全的 role-mask wrapper 参考](https://github.com/Lord-Kamina/SwiftDefaultApps/blob/master/Sources/Common%20Sources/LSWrappers.swift)
- [ghostty NSWorkspace+Extension.swift — 真实生产代码用 LSCopyDefaultApplicationURLForContentType 取 default text editor](https://github.com/ghostty-org/ghostty/blob/main/macos/Sources/Helpers/Extensions/NSWorkspace+Extension.swift)
- [Apple — Core Foundation Keys (CFBundleDisplayName)](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html)
- [Apple — Technical Q&A QA1823: Updating the Display Name of Your App](https://developer.apple.com/library/archive/qa/qa1823/_index.html)
- [Uniform Type Identifiers — a reintroduction (Apple Tech Talks 10696)](https://developer.apple.com/videos/play/tech-talks/10696/)
- [eclecticlight.co — How does macOS recognise file types?](https://eclecticlight.co/2025/10/25/explainer-how-does-macos-recognise-file-types/)

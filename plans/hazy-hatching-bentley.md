# 多重身份分类 + OCR 前向兼容设计

## Context

截图里观察到两个分类违和：
- 浏览器选中 URL 复制 → kind=`text`（应识别为"链接"）
- PNG 截图文件路径 → kind=`file`（也是"图片"语义）

而后期还要做 image OCR 入搜索。三件事看起来分散，但都属于"一条剪贴项有多重身份"，本质是同一类问题。

数据量考量：现在 1050 条 / image 仅 20 张。schema 变更现在做最便宜 —— 这是本期把 OCR 列一起加上的核心理由。

## 设计原则

三个问题虽然外观相似，但解法应该各取最便宜。**不引入 `facets` 通用抽象** —— 等出现第 4、第 5 个多重身份需求再抽。

## 关键事实（来自 Phase 1 exploration）

1. **ItemKind 是单一 enum 互斥**（`Sources/DuoPasteCore/Item.swift:4-11`）
2. **FTS5 用 `content='item'` 模式**，索引 `text_full / preview / source_app_name`（`Database.swift:77-108`）；INSERT/UPDATE/DELETE trigger 已挂，**改 `text_full` 即自动 reindex**
3. **image kind 的 `text_full` 当前永远是 nil** —— 留给 OCR 的天然位置，搜索无需任何代码改动即可命中 OCR 文本
4. **kind 过滤分四处对称**：`fetchHits` / `fetchHitsMirror` / `fetch` / `countUnionStatic`（`Search.swift`）
5. **chip 计数走 `countByKind` 系列**，先 stripKinds 再 GROUP BY
6. **现有 string 启发降级 pattern**：`looksLikeWebViewHTML`（`WebViewHTML.swift`）
7. **migration 套路成熟**：v2-v5 都加过列/表，v6 加列零阻力

---

## 第 1 刀：URL 文本误分类 → capture 阶段修正 + 历史 backfill

### 根因

`PasteboardWatcher.extract` 第 5 步 `readObjects([NSURL.self])` 在浏览器选中 URL 文本 Cmd+C 场景抓不到（浏览器只写 `.string`），落到第 6 步 → kind=text。

### 改动

**A. capture 阶段新分类**（`Sources/DuoPasteCapture/PasteboardWatcher.swift`）
- 在第 5 步 `readObjects([NSURL.self])` 失败、第 6 步 string fallback 之间插入字符串启发分支
- 新增私有静态函数 `looksLikeURL(_ s: String) -> Bool`：
  - trim 后 `URL(string:)` 解析成功
  - `scheme` 必须严格等于 `"http"` 或 `"https"`（**用户决策：仅 http(s):// 起头**）
  - 单行（无 `\n`/`\r`）
  - host 非空
- 命中 → 返回 `CapturedPasteboard(kind: .url, text: trimmed, …)`

**B. 历史 backfill**（`Sources/DuoPasteCore/Database.swift` v6 migration）
- 一次性 SQL：
  ```sql
  UPDATE item SET kind='url'
    WHERE kind='text'
      AND text_full IS NOT NULL
      AND (text_full GLOB 'http://*' OR text_full GLOB 'https://*')
      AND text_full NOT LIKE '%' || char(10) || '%';
  UPDATE item_mirror SET kind='url'
    WHERE kind='text'
      AND text_full IS NOT NULL
      AND (text_full GLOB 'http://*' OR text_full GLOB 'https://*')
      AND text_full NOT LIKE '%' || char(10) || '%';
  ```
- 不 bump `ingested_at_ns`：mirror 上的本机改动只是分类修正，下次正常 `/since` 拉到新数据时自然同步；用户决策为接受这个权衡（chip 计数立即在本机生效即可）
- GLOB 比 LIKE 高效（无 ESCAPE 处理）；换行检测排除 raw RTF / multi-line markdown 误判

**C. 测试**
- `Tests/DuoPasteCaptureTests/PasteboardWatcherTests.swift` 新增 `extractsURLFromPlainStringWithHttpScheme` / `extractsURLFromPlainStringWithHttpsScheme` / `treatsBareHostAsTextNotURL` / `treatsHttpFTPSchemeAsTextNotURL` / `multilineHttpStringIsNotURL`
- `Tests/DuoPasteCoreTests/DatabaseMigrationTests.swift`（或就近）新增 `v6BackfillsHttpTextRowsToUrlKind`

---

## 第 2 刀：图片文件路径 → UI 层 hint badge，零 schema 改动

### 改动

**A. 纯函数**（新增 `Sources/DuoPasteCore/FileKindHint.swift`）
```swift
public func fileLooksLikeImage(path: String) -> Bool {
    // 单行 + 最后一段后缀 ∈ {png,jpg,jpeg,heic,heif,gif,webp,tiff,bmp,svg}
}
```
放 Core 模块便于 UI + 测试复用，无 DB 副作用。

**B. UI 渲染**（`Sources/duo-pasted/SearchView.swift` 列表行 subtitle）
- 现状 subtitle 是 `"文件 · 10 min. ago"`
- 改为 `kind == .file && fileLooksLikeImage(text_full first line) → "文件 · 图片 · 10 min. ago"`
- 颜色保持灰色 secondary，不加 emoji（与现有 chip 风格一致）

**C. chip 行为不变**：点"图片" chip 严格 = `kind=.image`；点"文件" chip 严格 = `kind=.file`。**不做 OR 扩展**（用户决策）。理由：`.jpg` 文本路径 ≠ 真图片，OR 扩展会让计数虚高 + 引入弱信号误判。

**D. 测试**
- `Tests/DuoPasteCoreTests/FileKindHintTests.swift`：扩展名识别准入；多行排除；大小写不敏感

---

## 第 3 刀：OCR 数据模型 → 本期落 schema，worker 留到 Phase 1

### 数据模型设计

**新列**（v6 migration 同期加，**用户决策：现在就加**）：
```sql
ALTER TABLE item ADD COLUMN ocr_state TEXT NULL;
ALTER TABLE item_mirror ADD COLUMN ocr_state TEXT NULL;
-- backfill：所有 image kind 行标 pending，让未来 worker 慢慢扫
UPDATE item SET ocr_state='pending' WHERE kind='image' AND ocr_state IS NULL;
UPDATE item_mirror SET ocr_state='pending' WHERE kind='image' AND ocr_state IS NULL;
```

**ocr_state 取值**：
- `NULL` —— 非 image kind / 不需要 OCR（默认）
- `'pending'` —— image 已捕获，待 OCR worker 处理
- `'done'` —— OCR 已完成（`text_full` 可能非空也可能为空 —— 图里就是没字）
- `'failed'` —— 尝试过但失败，等下次重试
- `'skipped'` —— 图太大 / 用户关 / 不支持格式

**为什么必须有 ocr_state，不能只看 text_full**：
- 区分"没 OCR 过"vs"OCR 过但没文字" —— 否则 worker 每次启动都要重扫全部历史 image
- 区分"失败"vs"成功无文本" —— 失败要允许重试

### 为什么 OCR 文本写 text_full 而不是新列/新表

- `text_full` 在 FTS5 索引契约里，UPDATE trigger 已挂 → 写入自动 reindex，搜索零代码改动
- 排序契约里 prefix boost 看 `preview` / `text_full`，OCR 写入后 image 行天然进 search rank
- 新表需要 JOIN + 触发器重写，没好处

### Item.swift 同步

- `Item` struct 加 `ocrState: String?` 字段（CodingKeys `ocr_state`）
- `Item.Codable` JSON 形态加同字段
- Sync wire 上 OCR state 跟 text_full 一起经 `/since` 同步（text_full 已在 payload，加 ocr_state 是新 JSON key 但 Codable optional 兼容）

### CaptureService 路径改动

`Sources/DuoPasteCore/CaptureService.swift` 处理 image kind 入库时：
- 写入 `ocr_state='pending'`（不论 config 是否开 OCR —— worker 决定要不要做；config 关时 worker 直接 mark `'skipped'`）

### 本期 **不** 实现：
- OCRWorker actor / Vision.framework 集成 / preview 更新逻辑
- Config OCR 开关字段
- "可搜文字图片" UI 标识

但 schema 已就位，未来加 worker 是新增 actor + 新增 config 字段，**不涉及 schema migration**。

### 测试
- `Tests/DuoPasteCoreTests/DatabaseMigrationTests.swift` 新增 `v6AddsOcrStateColumn` / `v6BackfillsImageRowsToPending` / `v6LeavesNonImageRowsWithNullOcrState`
- `Tests/DuoPasteCoreTests/CaptureServiceTests.swift` 新增 `ingestImageMarksOcrStatePending`

---

## v6 Migration 汇总

单次 migration 同时落三件事，顺序：
1. `ALTER TABLE item ADD COLUMN ocr_state TEXT NULL`
2. `ALTER TABLE item_mirror ADD COLUMN ocr_state TEXT NULL`
3. URL kind backfill（item + item_mirror）
4. OCR state backfill（image → pending，item + item_mirror）

放在 `Sources/DuoPasteCore/Database.swift` 的 schemaVersion case `.v6_url_and_ocr_state`（沿用 v3-v5 命名风格）。

### 关键不变量

- **不 bump `ingested_at_ns`**：本机 backfill 是"分类修正"，不是新数据。其它 mirror client 拉本机 own-origin 行时，分类已经在新写入流程修对。
- **FTS5 自动 reindex**：URL kind backfill 改的是 `kind` 列（FTS5 未索引），无需手动 rebuild；OCR backfill 改的是 `ocr_state` 列（同样未索引），无影响。
- **migration 幂等**：`ADD COLUMN` 在 SQLite 列已存在时会报错 —— 复用现有 `if alreadyAtVersion(.v6) { return }` 守门（v3/v4/v5 已有 pattern，看 Database.swift `applyMigrations`）

---

## 关键文件清单

**修改**：
- `Sources/DuoPasteCapture/PasteboardWatcher.swift:319-328` —— URL 启发分支
- `Sources/DuoPasteCore/Database.swift` —— v6 migration
- `Sources/DuoPasteCore/Item.swift` —— Item.ocrState 字段 + Codable
- `Sources/DuoPasteCore/CaptureService.swift` —— image kind 入库写 ocr_state='pending'
- `Sources/duo-pasted/SearchView.swift` —— 列表行 file→image hint badge

**新增**：
- `Sources/DuoPasteCore/FileKindHint.swift` —— `fileLooksLikeImage(path:)`
- `Tests/DuoPasteCaptureTests/PasteboardWatcherTests.swift` —— URL 启发测试（约 5 条）
- `Tests/DuoPasteCoreTests/DatabaseMigrationTests.swift` —— v6 migration 测试（约 4 条）
- `Tests/DuoPasteCoreTests/FileKindHintTests.swift` —— hint 检测测试（约 3 条）
- `Tests/DuoPasteCoreTests/CaptureServiceTests.swift` —— image 入库 ocr_state 测试（约 1 条）

---

## 验证

1. **单测**：`swift test` 全绿，覆盖 v6 migration、URL 启发、file→image hint、image 入库 ocr_state
2. **手测 URL 分类**：
   - Chrome 地址栏选中 `https://example.com` Cmd+C → SearchView 显示 kind 标签为"链接"，chip "链接" 计数 +1
   - 复制 `github.com/foo`（裸 host）→ 仍是"文本"（严格 http(s) 不接裸 host，符合用户决策）
3. **手测 file→image hint**：Finder 复制 PNG 截图 → 列表行 subtitle 显示 "文件 · 图片"；复制 .txt → subtitle 仅 "文件"
4. **手测历史 backfill**：装新版后首次启动，运行 SQL `SELECT count(*) FROM item WHERE kind='url'`，数字应大于安装前；chip "链接" 计数立即反映真实分布
5. **OCR 列就位**：`PRAGMA table_info(item)` 看到 `ocr_state` 列；`SELECT count(*) FROM item WHERE ocr_state='pending'` 应等于 image kind 行数
6. **Sync 兼容**：装新版 client + 老版 primary（或反之）跑一轮 `/since`，确认 ocr_state 字段在 Codable 上向后兼容（optional，老 primary 不发该字段时 client decode 不抛）

---

## 不做的事（重申，防 scope creep）

- 不引入 `facets` 通用抽象列 / 关联表
- 不为 file→image 弱信号做 chip OR 扩展
- 不在本期落 OCRWorker / Vision.framework 集成
- 不加 config OCR 开关 —— 等 Phase 1 worker 落地时一起
- 不为 URL 启发支持 `www.` / 裸 host —— 严格 http(s) 起头

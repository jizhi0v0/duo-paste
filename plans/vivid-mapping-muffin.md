# v9 — extracted_text 独立列 + OCR 扩 file+image-blob

## Context

**问题**：用户从 Finder / IDE / Slack 复制 `.png` 文件路径,落 `kind=.file`(PasteboardWatcher "文件 URL" 分支)。即使 PasteboardWatcher 单 `.png` 文件**额外**读了字节进 BlobStore(`Sources/DuoPasteCapture/PasteboardWatcher.swift:213`),OCRWorker `fetchPending` 严格只扫 `kind='image'`,这类 file 行从未被 OCR。`text_full` 装的是路径字符串,FTS 搜不到图里的字——存量本机 71 行(`kind='file' AND blob_mime LIKE 'image/%'`)是死索引。

**v9 同时修两个问题**:
1. **新增能力**:OCRWorker 扫描扩到 file+image-blob 行
2. **修历史不一致**:v6 当年决定让 image kind 的 `text_full` 装 OCR 文本(FTS5 trigger 复用零成本),副作用是 `text_full` 的契约变成 kind-dependent("text 装原文 / image 装 OCR / file 装 path")——为了支持未来视频字幕 / PDF 文字层 / 语音转写也走 FTS 索引,把"派生索引文本"拆成独立列 `extracted_text`,语义清晰
   - `text_full` 永远 = "原始可粘贴文本"(text/url/rtf/html 原文;file 路径列表;image 不再装)
   - `extracted_text` = "从 blob 派生的辅助索引文本"(OCR/未来字幕/PDF text/ASR)
   - `extracted_text_source` = 标这段文本是哪种 extractor 产出(`'ocr'`/未来 `'subtitle'`/`'pdf_text'`)

**FTS5 索引列**(v9 之后):`text_full + preview + source_app_name + extracted_text`

## 已落地的改动(代码已在 working tree)

### `Sources/DuoPasteCore/Database.swift` — v9 migration

新增 `v9_extracted_text` migration:
1. `ALTER TABLE item ADD COLUMN extracted_text TEXT;`
2. `ALTER TABLE item ADD COLUMN extracted_text_source TEXT;`
3. 历史 image kind 数据搬迁:`text_full` → `extracted_text`(source='ocr'),仅 `ocr_state='done'` 且 `text_full` 非空非空字符串的行参与
4. `UPDATE item SET text_full = NULL WHERE kind = 'image';` ——清掉 image kind 残留(包括未 OCR 完成行的 fileName 等)
5. file+image-blob backfill 标 `ocr_state='pending'`:`kind='file' AND blob_mime LIKE 'image/%' AND blob_sha256 IS NOT NULL AND deleted_at_ns IS NULL AND ocr_state IS NULL`
6. FTS5 整表重建:DROP 3 triggers + DROP item_fts → CREATE 新 fts 表(列签名加 extracted_text)→ `INSERT INTO item_fts(item_fts) VALUES('rebuild')` 触发 contentless-external 全量重建 → 重建 3 triggers(全部加 extracted_text 列)

### `Sources/DuoPasteCore/Item.swift`

- 新 enum `ExtractedTextSource: String, Codable, Sendable { case ocr }`——为未来 subtitle/pdf_text/asr 留扩展位
- `Item` 加 `extractedText: String?` + `extractedTextSource: ExtractedTextSource?`
- CodingKey 加 `case extractedText = "extracted_text"` + `case extractedTextSource = "extracted_text_source"`
- 默认参数 nil,兼容现有调用点

### `Sources/DuoPasteCore/OCRWorker.swift`

- `fetchPending` SQL 改成手写形式,谓词扩 OR 分支:
  ```sql
  WHERE origin_device = ? AND ocr_state = ? AND deleted_at_ns IS NULL
    AND (kind = 'image' OR
         (kind = 'file' AND blob_mime LIKE 'image/%' AND blob_sha256 IS NOT NULL))
  ```
- `markDone` SQL 改成写 `extracted_text + extracted_text_source = 'ocr'`,不动 `text_full`
- 文档注释更新(职责说明 + 不变量 + fetchPending 注释)

### `Sources/DuoPasteCore/CaptureService.swift`

- `ingestBlob` 里 `ocrState` 赋值条件扩到 file+image-blob:
  ```swift
  let isImageBlob = (c.kind == .image)
      || (c.kind == .file && (c.blobMime?.hasPrefix("image/") == true))
  let ocrState: OCRState? = isImageBlob ? .pending : nil
  ```
- 用 `blob_mime` 判别而非路径后缀(mime 是 capture 时读字节成功才设的,等价于"OCR 必需字节就绪")

### `Sources/DuoPasteSync/Server.swift`

- `itemToJSON` 输出 `extracted_text` + `extracted_text_source`

### `Sources/DuoPasteSync/PullWorker.swift`

- `applyPage` INSERT SQL 加 `extracted_text, extracted_text_source` 两列 + 绑定 `item.extractedText` / `item.extractedTextSource?.rawValue`

## 待落地的改动

### 1. CaptureService image kind textFull 一致性修正(发现的新问题)

`CaptureService.swift:218` 当前:
```swift
textFull: c.kind == .file ? (c.text ?? c.fileName) : c.fileName,
```
image kind 新 capture 时仍写 `textFull = c.fileName`,跟 v9 migration step 3 "image kind text_full 一律 NULL" 矛盾——历史行清 NULL、新行装 fileName,不一致。

**修复**:image kind textFull 改成 nil:
```swift
let resolvedTextFull: String?
switch c.kind {
case .file:
    resolvedTextFull = c.text ?? c.fileName    // path 列表(或单 fileName 兜底)
case .image:
    resolvedTextFull = nil                       // image kind 没有"原始可粘贴文本"
default:
    resolvedTextFull = c.fileName                // 其他 blob kind 用 fileName(沿用旧行为)
}
```

理由:image kind 的"可粘贴主体"是字节(Copyback.copy `.image` 分支直接 setData),fileName 装 textFull 不参与任何 paste 路径,只污染 FTS5 索引(虽然影响小)。

### 2. PasteMerge / Copyback / fileURLs 评审(verify only)

- `PasteMerge.joinTextual` 当前 image kind 走 preview 兜底分支(`PasteMerge.swift:68`)——v9 之后 image kind textFull=nil,**仍走 preview** 兜底,行为不变。**保留该分支**(注释更新:解释原因从"OCR 文本污染"改成"image 没有原始可粘贴文本")
- `Copyback.copy` `.image` 分支用 blob 字节,不读 textFull,无影响
- `AppDelegate.fileURLs` 走 `textFull ?? preview`,image kind 不调它(`.file` 才用),无影响

### 3. 测试改造

**改动**:
- `Tests/DuoPasteCoreTests/OCRWorkerTests.swift` 6 处 textFull assertion 改成 extractedText
  - L97: `after?.textFull == "hello world"` → `after?.extractedText == "hello world"`
  - L152: `after?.textFull == nil` 改 `after?.extractedText == nil`(other-origin 跳过未变)
  - L207: 空文本归一化为 nil → 改读 extractedText
  - L399: woke 测试 → extractedText
  - L440: tombstone race guard → extractedText
  - (其他 textFull 引用是注释/不直接断言的,保留)
- `Tests/DuoPasteSyncTests/OCRPhase2SyncTests.swift` 也要改(Phase 2 跨设备同步验证 textFull 写入,改成 extractedText)

**新增**:
- v9 migration 测试(`Tests/DuoPasteCoreTests/DatabaseV9MigrationTests.swift`):
  - 预置 v8 数据库快照(image done 行 text_full="OCR result"、image pending 行 text_full=fileName、file+image-blob 未标 pending)
  - 跑 migrator → 验证 image done 行 text_full=nil + extracted_text="OCR result"、file+image-blob 行 ocr_state='pending'、FTS5 表新列存在
- OCRWorker file+image-blob 命中测试(加进 `OCRWorkerTests.swift`):seed file kind + blob_mime='image/png' + blob_sha256 → tick → 验证 extracted_text 写入 + ocr_state=done

### 4. swift build && swift test

预期全绿(除已知 PullWorker / BlobLazyPull 偶发并发 flake)。

## 关键文件路径速查

| 文件 | 作用 |
|---|---|
| `Sources/DuoPasteCore/Database.swift` | v9 migration(已改) |
| `Sources/DuoPasteCore/Item.swift` | extractedText 字段 + CodingKey(已改) |
| `Sources/DuoPasteCore/OCRWorker.swift` | fetchPending + markDone(已改) |
| `Sources/DuoPasteCore/CaptureService.swift` | ocrState 赋值(已改) + image kind textFull(待改) |
| `Sources/DuoPasteCore/PasteMerge.swift` | image kind 走 preview 兜底(注释更新,逻辑不动) |
| `Sources/DuoPasteSync/Server.swift` | itemToJSON 输出新字段(已改) |
| `Sources/DuoPasteSync/PullWorker.swift` | applyPage INSERT 新字段(已改) |
| `Tests/DuoPasteCoreTests/OCRWorkerTests.swift` | textFull assertion → extractedText |
| `Tests/DuoPasteSyncTests/OCRPhase2SyncTests.swift` | textFull → extractedText |
| `Tests/DuoPasteCoreTests/DatabaseV9MigrationTests.swift` | 新增 |

## 验证

1. **swift build**——确认编译过
2. **swift test**——所有现有测试通过
3. **install-agent + 实测**:
   - `launchctl bootout` 停老 daemon
   - `./scripts/install-agent.sh` 装新版
   - `launchctl print gui/$UID/io.duopaste.agent` 确认在跑 + 日志看 "migration v9_extracted_text" 执行
   - 实操:用户已有 71 行 file+image-blob,等 OCRWorker 跑完(per-item 100ms + Vision 1-3s 单图,约 5-15 分钟)
   - 搜索"文本 折线图"等截图里的字 → 应命中 file kind 行
4. **DB 直查**:
   ```sh
   sqlite3 ~/Library/Application\ Support/duo-paste/db/main.sqlite "
     SELECT kind, ocr_state, extracted_text IS NOT NULL AS has_et, COUNT(*)
     FROM item WHERE deleted_at_ns IS NULL
     GROUP BY kind, ocr_state, has_et;
   "
   ```

## 风险 / 已知点

- **跨设备升级窗口**:新 daemon 推 extracted_text 字段给老 v8 daemon,老端 Codable 默认 ignore unknown,字段静默丢失。**两台 Mac 需要同时升 v9** 才能让对端 OCR 结果同步生效
- **migration 不可逆**:image kind text_full 搬迁后 v8 daemon 读不到 OCR。snapshot 备份(`~/Library/Application Support/duo-paste/snapshots/`)是 escape hatch
- **FTS5 重建**:库 <2K 行秒级完成,不阻塞用户感知

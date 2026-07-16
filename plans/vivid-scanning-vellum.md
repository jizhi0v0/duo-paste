# OCR Worker — 截图文字入搜索

> [!CAUTION]
> **已归档；不可作为部署说明。** 现行部署见 [`README.md`](../README.md) 与
> [`docs/deploy-multi-mac.md`](../docs/deploy-multi-mac.md)；未来工作只看
> [`docs/roadmap.md`](../docs/roadmap.md)。

## Context

`hazy-hatching-bentley.md` 第 3 刀已落 schema（PR#17）：v6 migration 加 `ocr_state` 列、`Item.ocrState` 字段、`/since` wire 透传、`CaptureService` 在 image 入库时标 `pending`、`Admin.promoteToPrimary` 搬运 ocr_state。

但实际跑 OCR 的 worker、Vision.framework 集成、Config 开关、失败重试、CLI retry 子命令——全部留到本期。这是 Phase 1 落地的工作。

**用户痛点**：复制截图（中文文档 / 网页 / 代码截图）后搜里面的字符串完全不命中。当前 image kind 的 `text_full` 永远 nil，FTS5 索引空。

**当前观测**：~1050 条 item，~20 张 image 全部 ocr_state=pending（v6 backfill 标的）。

---

## 设计原则

1. **分布式 MVP**：每台 Mac 自跑自家 `origin=self` 的 image。结果不跨设备同步——MBP 自家截图 MBP OCR，mini 自家截图 mini OCR。其它机器上拿到的 mirror 行（origin=对端）由对端自己 OCR，不重复劳动。
2. **跨设备同步留 Phase 2**：当前 push 路径 `/ingest` 是 `INSERT OR IGNORE` 不更新已有行；PullWorker 跳过 own-origin 拉到的 mirror 更新（M3 第二刀决策）。要让"A 设备 OCR 结果到 B 设备能搜"必须加 `POST /update` + PullWorker 写回本机 own-origin item.text_full 两条新路径。MVP 不做，记入 Phase 2 follow-up。
3. **仿 PushWorker 调度**：单 actor 串行 tick + `wake()` 缩短延迟 + 周期兜底。OCR 本身慢（accurate 模式单图 0.5-3s），串行处理足够；并发反而争 CPU 让用户体感卡顿。
4. **OCR 写 text_full 不另起新列**：FTS5 索引契约 + UPDATE trigger 已挂 → text_full 写入自动 reindex，搜索零代码改动。排序契约里 prefix boost 看 preview/text_full，OCR 写入后 image 行天然进 search rank。
5. **Vision.framework 抽 protocol**：测试不能 mock OS 框架；`OCRRecognizer` protocol + 生产 `VisionOCRRecognizer` impl + 测试 `StubOCRRecognizer`。

---

## 关键事实（决策依据）

1. **Schema 已就位**（PR#17）：`item.ocr_state TEXT NULL` 取值 `pending`/`done`/`failed`/`skipped`/`NULL`。v6 migration backfill 把现存 image kind 行全部标 `pending`，新捕获走 `CaptureService.swift:178-198` 标 pending。
2. **`Item.ocrState: OCRState?` + CodingKeys `ocr_state`** 已 Codable，`/since` wire 透传（`Item.swift:23-28, 50, 118`）。
3. **CaptureService 入库路径**（`CaptureService.swift:178-198`）：`c.kind == .image` 时 `ocrState = .pending`，不论 primary/client role。
4. **BlobStore 路径**：`<root>/blobs/<ab>/<cd>/<sha256>.<ext>`，`BlobStore.url(forSha256:)` 取本地路径，`BlobStore.exists(sha256:)` 短路。
5. **PushWorker 调度模式**（`PushWorker.swift`）：actor + `runTask: Task<Void, Never>?` + `currentSleep: Task<Void, Error>?` + `wake()` nonisolated 取消 sleep 提前 tick + `cancelCurrentSleep()` actor method。`runLoop` while !isCancelled → tick → 计算 sleep → 起 sleep task → 阻塞 → 下一轮。**OCRWorker 直接复制这个骨架**。
6. **写入 text_full 触发 FTS5 reindex**：v1_initial schema 注册了 `item_au` UPDATE trigger（`Database.swift:77-108`），UPDATE 任何被索引列（含 text_full）自动 delete+insert FTS shadow table。OCR 写回不需要手动 rebuild。
7. **`Database.nextIngestNs(db, now:)` 仍是 stamp ingested_at_ns 的唯一入口**（writer tx 内调），让 commit 顺序 = ns 顺序。OCR 写回 own-origin 行时也 bump，让任何监听 ingested_at_ns 的下游（audit-push 链路 / 未来 mirror 同步）能感知到更新。
8. **PullWorker 跳过 own-origin**（M3 第二刀决策）：mirror 不存自家 origin 行避免 union 重叠。本 MVP 不破这个不变量。
9. **`/update` endpoint 不存在**：当前 `Server.swift` 只有 `/health` `/ingest` `/blob` `/search` `/since`。`/ingest` 用 `INSERT OR IGNORE` 不更新。`RemoteIngester.ingest` 注释明确写"pin / 软删的跨设备同步留到 M3+ 单独走 `/update` 之类路由"。OCR result 跨设备同步是同一类需求，**MVP 不引入**。

---

## 第 1 刀：OCRRecognizer protocol + Vision 实现

### 新增 `Sources/DuoPasteCore/OCRRecognizer.swift`

```swift
public protocol OCRRecognizer: Sendable {
    func recognize(imageURL: URL, languages: [String]) async throws -> OCRResult
}

public struct OCRResult: Sendable {
    public let text: String     // 多行 join("\n")；空表示"图里没字"，仍要标 done
}

public enum OCRRecognizeError: Error, Sendable {
    case imageLoadFailed         // NSImage init 失败（损坏 / 非图片格式）→ skipped
    case unsupportedFormat       // CGImage 拿不到（如某些 PDF stub）→ skipped
    case visionTransient(Error)  // Vision API 抛错 → attempts++
    case visionPermanent(Error)  // 罕见的 NSError code 表示永久失败 → skipped
}
```

### 生产实现 `VisionOCRRecognizer`

```swift
import Vision
import AppKit

public struct VisionOCRRecognizer: OCRRecognizer {
    public let recognitionLevel: VNRequestTextRecognitionLevel  // .accurate / .fast
    public let usesLanguageCorrection: Bool                      // true
    public let log: @Sendable (String) -> Void

    public func recognize(imageURL: URL, languages: [String]) async throws -> OCRResult {
        // 1) NSImage.init(contentsOf:) — 失败 → imageLoadFailed
        // 2) image.cgImage(forProposedRect: nil, context: nil, hints: nil) — nil → unsupportedFormat
        // 3) VNImageRequestHandler(cgImage:options:[])
        // 4) VNRecognizeTextRequest:
        //    - recognitionLanguages = languages
        //    - recognitionLevel = self.recognitionLevel
        //    - usesLanguageCorrection = self.usesLanguageCorrection
        //    - automaticallyDetectsLanguage = true (>= macOS 13)
        // 5) handler.perform([req]) — 抛错 → visionTransient
        // 6) req.results.compactMap { $0.topCandidates(1).first?.string }
        //      .joined(separator: "\n")
        // 7) 返回 OCRResult(text: ...)
    }
}
```

**为什么 .accurate 不是 .fast**：用户截图大部分文字密集（代码 / 文档 / 聊天）。.fast 在中文上漏字明显。0.5-3s/张 在 utility QoS 后台跑可接受。Config 留开关让用户自己选。

**`automaticallyDetectsLanguage`**：macOS 13+ 提供，让 Vision 自动猜语言。`recognitionLanguages` 仍传，作为 hint 优先级。这两者并不冲突。

### Stub 实现（测试用）

```swift
public struct StubOCRRecognizer: OCRRecognizer {
    public let results: [String: Result<OCRResult, OCRRecognizeError>]
    public let calls: ActorCallCounter      // 记录调用顺序 / 次数

    public func recognize(imageURL: URL, languages: [String]) async throws -> OCRResult {
        await calls.record(imageURL.lastPathComponent)
        let key = imageURL.lastPathComponent
        switch results[key] {
        case .success(let r): return r
        case .failure(let e): throw e
        case nil: throw OCRRecognizeError.imageLoadFailed
        }
    }
}
```

---

## 第 2 刀：OCRWorker actor

### 新增 `Sources/DuoPasteCore/OCRWorker.swift`

```swift
public actor OCRWorker {
    public struct Config: Sendable {
        public var idleIntervalSec: TimeInterval     // 默认 300（5min 兜底）
        public var perItemPauseMs: Int               // 默认 100（让 CPU 给前台）
        public var maxAttempts: Int                  // 默认 5
        public var batchSize: Int                    // 默认 20
        public var maxBlobBytes: Int                 // 默认 16MB，超过 → skipped
        public var languages: [String]               // 默认 ["zh-Hans", "en-US"]
    }

    private let database: Database
    private let blobs: BlobStore
    private let recognizer: OCRRecognizer
    private let originDevice: String               // 只扫 origin=self 的行
    private let config: Config

    private var runTask: Task<Void, Never>?
    private var currentSleep: Task<Void, Error>?

    public func start() { /* 仿 PushWorker.start */ }
    public func stop()  { /* 仿 PushWorker.stop  */ }
    public nonisolated func wake() { /* 仿 PushWorker.wake */ }

    private func runLoop() async {
        while !Task.isCancelled {
            let drained = await tick()
            let sleep = drained.processed == 0 ? config.idleIntervalSec : 0
            // 跑完一批不立刻 sleep——如果有 pending 继续；空批进 idle
            if sleep > 0 { await sleepInterruptible(sleep) }
        }
    }

    private func tick() async -> TickResult {
        let pending = try? fetchPending()  // SELECT ... LIMIT batchSize
        guard let pending, !pending.isEmpty else { return .empty }
        for item in pending {
            if Task.isCancelled { break }
            await processOne(item)
            try? await Task.sleep(nanoseconds: UInt64(config.perItemPauseMs) * 1_000_000)
        }
        return TickResult(processed: pending.count)
    }

    private func processOne(_ item: Item) async {
        guard let sha = item.blobSha256 else {
            await markSkipped(item.id, reason: "no blob sha"); return
        }
        let url = blobs.url(forSha256: sha, ext: item.blobExt ?? "png")
        guard FileManager.default.fileExists(atPath: url.path) else {
            await markSkipped(item.id, reason: "blob missing"); return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if bytes > config.maxBlobBytes {
            await markSkipped(item.id, reason: "blob too large: \(bytes)"); return
        }
        do {
            let result = try await recognizer.recognize(imageURL: url, languages: config.languages)
            await markDone(item.id, text: result.text)
        } catch let e as OCRRecognizeError {
            switch e {
            case .imageLoadFailed, .unsupportedFormat, .visionPermanent:
                await markSkipped(item.id, reason: "\(e)")
            case .visionTransient:
                await bumpAttemptOrFail(item.id, reason: "\(e)")
            }
        } catch {
            await bumpAttemptOrFail(item.id, reason: "\(error)")
        }
    }
}
```

### `fetchPending` SQL

```sql
SELECT * FROM item
WHERE origin_device = ?
  AND kind = 'image'
  AND ocr_state = 'pending'
  AND blob_sha256 IS NOT NULL
  AND deleted_at_ns IS NULL
ORDER BY captured_at_ns ASC
LIMIT ?;
```

- `origin_device = self`：MVP 分布式契约——只扫自家行
- `deleted_at_ns IS NULL`：软删的 image 不浪费 CPU
- `ORDER BY captured_at_ns ASC`：先扫老的，让历史 backfill 慢慢清；新捕获走 `wake()` 路径，进 batch 顺序不重要

### `markDone` 写回

```swift
try await database.pool.write { db in
    let now = Database.nextIngestNs(db, now: Clock.nowNs())
    try db.execute(sql: """
        UPDATE item
        SET text_full = ?,
            ocr_state = 'done',
            ingested_at_ns = ?
        WHERE id = ?;
    """, arguments: [text.isEmpty ? nil : text, now, id])
}
```

**关键不变量**（详见下文）：
- **bump ingested_at_ns**：让 audit-push 链路 / 未来跨设备同步能 detect 更新
- **text_full 空字符串写 nil**：FTS5 zero-length match 让 snippet 接口返回奇怪结果；统一 nil 表示"无文本"
- **不动 preview**：preview 是 capture 时定的"用户视觉摘要"，OCR 文本是搜索维度，两者职责分开。preview 仍是图片 placeholder（"📷 image"）。如果未来想让 OCR 出的第一行进 preview，单独决策。

### `markSkipped` / `bumpAttemptOrFail`

```sql
-- skipped
UPDATE item SET ocr_state = 'skipped', last_push_error = ? WHERE id = ?;

-- bump attempt（复用 push_attempts? NO——OCR 重试跟 push 重试无关。
-- 加新列还是放 push_attempts? 简化方案：OCR attempts 不持久化，actor 内存计数。
-- 失败超 maxAttempts 直接 mark failed，daemon 重启从 pending 全部重来——
-- OCR 失败本身罕见，重启重试不算大代价）
```

**决策**：OCR 重试次数**只在 actor 内存里计数**，不入 DB。失败超 `maxAttempts` → DB 标 `failed`。daemon 重启时 `failed` 行不进 `fetchPending`，需要用户跑 `retry-failed-ocr` 手动重试。理由：push 重试持久化是因为网络抖动可能跨重启；OCR 失败是图本身坏 / Vision 系统 bug，跨重启重试反而消耗 CPU。

### 启动与触发

```swift
// AppDelegate.applicationDidFinishLaunching:
if cfg.ocr.enabled {
    let recognizer = VisionOCRRecognizer(
        recognitionLevel: cfg.ocr.recognitionLevel,
        usesLanguageCorrection: true,
        log: log
    )
    self.ocrWorker = OCRWorker(
        database: db, blobs: blobs,
        recognizer: recognizer,
        originDevice: deviceID,
        config: cfg.ocr.toWorkerConfig()
    )
    await ocrWorker?.start()
}

// CaptureService 在 image kind 入库成功后:
//   既要 wake PushWorker（推 primary）也要 wake OCRWorker（本地 OCR）
// AppDelegate.captureCallback 已经调 pushWorker?.wake()；
// 直接加一行 ocrWorker?.wake()
```

### 测试

`Tests/DuoPasteCoreTests/OCRWorkerTests.swift`：

- `ocrWorkerProcessesPendingOwnOriginImage`：seed image item (origin=self, ocr_state=pending)，StubOCRRecognizer 返回 "hello"，跑 tick，断言 text_full="hello"、ocr_state="done"、ingested_at_ns 已 bump
- `ocrWorkerSkipsOtherOriginImages`：seed image item (origin="other", ocr_state=pending)，stub 不应被调，行状态不变
- `ocrWorkerSkipsNonImageKind`：seed text item (origin=self, ocr_state=NULL)，不应被扫
- `ocrWorkerSkipsSoftDeleted`：seed image item (origin=self, ocr_state=pending, deleted_at_ns=now)，不被处理
- `ocrWorkerMarksDoneEvenWithEmptyText`：stub 返回 OCRResult(text: "")，断言 text_full=nil、ocr_state="done"（不再重扫）
- `ocrWorkerSkipsWhenBlobMissing`：seed image item 但 BlobStore 没文件，断言 ocr_state="skipped"
- `ocrWorkerSkipsWhenBlobTooLarge`：seed image item + 25MB blob (config.maxBlobBytes=16MB)，断言 ocr_state="skipped"
- `ocrWorkerSkipsOnImageLoadFailure`：stub 抛 imageLoadFailed，断言 ocr_state="skipped"
- `ocrWorkerSkipsOnPermanentVisionError`：stub 抛 visionPermanent，断言 skipped
- `ocrWorkerRetriesOnTransientThenFailsAfterMaxAttempts`：stub 永远抛 visionTransient，跑 maxAttempts+1 个 tick，断言最后 ocr_state="failed"
- `ocrWorkerWakesAndProcessesNewItem`：start worker → 无 pending sleep idle → INSERT 新 image item + wake() → 100ms 内 stub 被调一次
- `ocrWorkerCatchesUpOldestFirst`：seed 3 个 pending image，capturedAtNs 不同，断言处理顺序按 ASC

---

## 第 3 刀：Config OCR 段

### 改 `Sources/DuoPasteCore/Config.swift`

新增 `OCRSettings` 嵌套 struct（仿 `CaptureLimits` / `PullConfig` 形态）：

```swift
public struct OCRSettings: Codable, Sendable, Equatable {
    public var enabled: Bool                  // 默认 true
    public var languages: [String]            // 默认 ["zh-Hans", "en-US"]
    public var maxBlobMB: Int                 // 默认 16
    public var recognitionLevel: String       // "accurate" | "fast"，默认 "accurate"
    public var perItemPauseMs: Int            // 默认 100

    public static let `default` = OCRSettings(
        enabled: true,
        languages: ["zh-Hans", "en-US"],
        maxBlobMB: 16,
        recognitionLevel: "accurate",
        perItemPauseMs: 100
    )

    enum CodingKeys: String, CodingKey {
        case enabled
        case languages
        case maxBlobMB = "max_blob_mb"
        case recognitionLevel = "recognition_level"
        case perItemPauseMs = "per_item_pause_ms"
    }
}
```

`Config` 顶层加 `public var ocr: OCRSettings`，`init(from:)` 用 `decodeIfPresent ?? .default`，`Config.write` 用 nested merge 保留未知子字段（仿 `pullDict` / `captureDict` 模式 line 283-299）。

### `enabled=false` 行为

- AppDelegate 不启动 OCRWorker
- CaptureService 仍标 `ocr_state=pending`（不动数据形态）
- 启动时让 OCRWorker 自检 `cfg.ocr.enabled` 决定 `start()` 是否真启动；不启动就 no-op exit `runLoop`

理由：用户后续把 enabled 翻回 true，历史 pending 行自然被处理；不要在 capture 路径写不同 state（增加状态空间）。

### `validate()` 加项

```swift
if !["accurate", "fast"].contains(ocr.recognitionLevel) {
    throw ConfigError.invalidCombination(
        "ocr.recognition_level 必须是 'accurate' 或 'fast'：\(ocr.recognitionLevel)"
    )
}
if ocr.languages.isEmpty {
    throw ConfigError.invalidCombination("ocr.languages 不能为空")
}
if ocr.maxBlobMB < 1 {
    throw ConfigError.invalidCombination("ocr.max_blob_mb 必须 >= 1")
}
```

### 测试

`Tests/DuoPasteCoreTests/ConfigTests.swift` 加：

- `configDecodesOcrDefaults`：空 ocr 段 → 默认值
- `configRoundtripsOcrSettings`：write + load 字段保真
- `configWriteOcrPreservesUnknownNestedKeys`：原 ocr dict 含 `ocr.debug_dump=true` 未知 key → write 后仍在
- `configValidateRejectsInvalidRecognitionLevel`
- `configValidateRejectsEmptyLanguages`

---

## 第 4 刀：CLI `retry-failed-ocr`

### 新增 CLI 子命令

```sh
duo-pasted retry-failed-ocr [--all|--id <ITEM_ID>]
```

- 无 flag = `--all`：所有 `ocr_state IN ('failed', 'skipped')` 的本机 own-origin image 重置回 pending
- `--id <ID>`：单条
- 一次性 exit（仿 `retry-failed`）

### 实现 `Sources/DuoPasteCore/Admin.swift`

```swift
public func retryFailedOCR(database: Database, deviceID: String, scope: Scope) throws -> Int {
    let sql: String
    let args: StatementArguments
    switch scope {
    case .all:
        sql = """
            UPDATE item SET ocr_state = 'pending'
            WHERE origin_device = ?
              AND kind = 'image'
              AND ocr_state IN ('failed', 'skipped')
              AND deleted_at_ns IS NULL;
        """
        args = [deviceID]
    case .id(let id):
        sql = "UPDATE item SET ocr_state = 'pending' WHERE id = ? AND kind = 'image';"
        args = [id]
    }
    return try database.pool.write { db in
        try db.execute(sql: sql, arguments: args)
        return db.changesCount
    }
}
```

### `CLI.dispatchAndExitIfApplicable` 加分支

```swift
case "retry-failed-ocr":
    let scope: Admin.Scope = /* parse argv */
    let n = try Admin.retryFailedOCR(database: db, deviceID: did, scope: scope)
    print("reset \(n) item(s) to ocr_state=pending")
    exit(0)
```

### 测试

- `retryFailedOCRResetsFailedAndSkipped`：seed failed + skipped + done + pending，跑 --all，断言只有 failed/skipped 变 pending（done 不动）
- `retryFailedOCRByIDOnly`：跑 --id 指定 done 行 → ok 变 pending（手动 override 不查 state 黑名单）
- `retryFailedOCRSkipsOtherOriginByDefault`：--all 不动 origin != self 的行

---

## 关键不变量（不要回退）

1. **MVP 分布式**：OCRWorker 只扫 `origin_device = self` 的行。**不要**让 worker 跨 origin 扫——会跟"PullWorker 跳过 own-origin"决策起冲突，导致 client 处理别人的行后 own-origin 同 id 行永远拿不到结果。Phase 2 加 `/update` 协议时一起改。

2. **bump ingested_at_ns**：OCR 写回 own-origin 行时 `ingested_at_ns = Database.nextIngestNs(db, now: ...)`。原因：让 audit-push 链路（基于 ingested_at_ns 比对）看到本机行有更新；让未来跨设备同步路径不用先改写入约定。**不**修 `captured_at_ns`（capture 时间是真相，OCR 不是新 capture）。

3. **text_full 空字符串 → nil**：FTS5 对空字符串的匹配/snippet 行为有 corner case，统一 nil 表示"无文本"。`UPDATE ... SET text_full = ? ...` 绑定 `text.isEmpty ? nil : text`。

4. **不动 preview**：preview 是用户视觉摘要（image kind 当前是 placeholder 或 nil）。OCR 文本进 search rank 但不进 preview。Phase 2 可加 `if preview == nil && !ocrText.isEmpty { preview = firstLine(ocrText, max: 80) }`，要单独决策。

5. **markDone 即便 text 为空**：OCR 跑过但图里没字 → 也要标 done，否则 worker 每个 tick 重扫这条永不收敛。state 取值已经支持这个语义（`done` 不蕴含 "text_full 非空"）。

6. **`failed` 不自动重试**：actor 内存 attempts 计数到 `maxAttempts` 就 mark failed，daemon 重启不再扫 failed 行——需要用户跑 `retry-failed-ocr` 显式触发。理由见上文"OCR 重试不持久化"。

7. **OCRWorker 跟 PushWorker / PullWorker 解耦启动**：只依赖 `cfg.ocr.enabled`。primary / client / standalone 三种 role 都启动 OCRWorker（如果 enabled）。这跟 BlobFetcher 解耦的精神一致（P1 review fix in blob 懒拉）。

8. **enabled=false 时 capture 路径不变**：仍标 `ocr_state=pending`。理由：避免状态机里多一条 "pending vs no_ocr"，让"开关随用随开"更便宜。

9. **maxBlobBytes 守门在 worker 不在 capture**：capture 端 cap 是字节守门防意外巨物入库（CLAUDE.md 设计决策段）；OCR 端 cap 是"OCR 慢 / 内存峰值大"的另一类守门。两个 cap 独立。

---

## 关键文件清单

**修改**：
- `Sources/DuoPasteCore/Config.swift` —— 加 `OCRSettings` + 顶层 `ocr` 字段 + `validate()` + `write()` nested merge
- `Sources/DuoPasteCore/Admin.swift` —— 加 `retryFailedOCR(database:deviceID:scope:)` 函数
- `Sources/duo-pasted/CLI.swift` —— 加 `retry-failed-ocr` 子命令分支
- `Sources/duo-pasted/AppDelegate.swift` —— `applicationDidFinishLaunching` 启动 OCRWorker；image capture 后 `ocrWorker?.wake()`
- `Sources/duo-pasted/AppDependencies.swift`（如有）—— OCRWorker 注入

**新增**：
- `Sources/DuoPasteCore/OCRRecognizer.swift` —— protocol + `OCRResult` + `OCRRecognizeError`
- `Sources/DuoPasteCore/VisionOCRRecognizer.swift` —— 生产 impl（import Vision）
- `Sources/DuoPasteCore/OCRWorker.swift` —— actor 调度
- `Tests/DuoPasteCoreTests/OCRWorkerTests.swift` —— ~11 条覆盖（见第 2 刀测试段）
- `Tests/DuoPasteCoreTests/OCRRecognizerStub.swift` —— StubOCRRecognizer（也供未来 BlobLazyPull / PullWorker 测试复用，独立文件方便）

**不动**：
- `Sources/DuoPasteCore/Database.swift` —— v6 migration 已就位
- `Sources/DuoPasteCore/Item.swift` —— OCRState / ocrState 字段已就位
- `Sources/DuoPasteCore/CaptureService.swift` —— `ocr_state=pending` 标记已就位
- `Sources/DuoPasteSync/Server.swift` —— **MVP 不加新 endpoint**
- `Sources/DuoPasteSync/RemoteIngester.swift` —— 不动
- `Sources/DuoPasteSync/PullWorker.swift` —— 不动

---

## 验证

1. **单测**：`swift test` 全绿；新增 `OCRWorker` ~11 条 + `Config` OCR 5 条 + `Admin.retryFailedOCR` 3 条
2. **手测中文截图**：
   - 截一张中文文档/聊天的图，Cmd+Shift+4 区域截图 → Cmd+V 复制到剪贴板（或者直接 Cmd+Shift+Ctrl+4 截到剪贴板）
   - 等 5s 让 OCRWorker tick（捕获时 wake，应该 ~1-3s 内完成 OCR）
   - 搜索图里出现的中文字符串 → 该 image item 应命中
   - SQL 验证：`SELECT id, ocr_state, length(text_full) FROM item WHERE kind='image' ORDER BY captured_at_ns DESC LIMIT 5;` 看 ocr_state=done + text_full 长度
3. **手测英文截图**：同上换英文 / 代码截图
4. **手测无文字图**：复制一张纯色 / 风景照 → ocr_state=done + text_full=NULL
5. **手测 catch-up**：daemon 启动后扫 v6 backfill 历史 image（~20 张）→ 几分钟内所有 pending 变 done/skipped
6. **手测 enabled=false**：改 `config.json` ocr.enabled=false → 重启 daemon → 新 image 入库 ocr_state=pending 但不被处理；翻回 true → 自然处理
7. **手测 retry**：人为 UPDATE 一条到 ocr_state=failed → `duo-pasted retry-failed-ocr` → 该条变 pending → OCRWorker 重新处理
8. **资源检查**：跑 OCR 期间 `top -pid $(pgrep duo-pasted)` 看 CPU；accurate 模式单图峰值 ~50-100% 单核 1-3s，间歇 100ms。前台用户感知应该不卡
9. **断电/中断鲁棒性**：OCR 跑到一半 `kill -9` daemon → DB 行 ocr_state 仍是 pending（writer tx 没 commit）→ 重启后自然重试

---

## 不做的事（防 scope creep）

**留 Phase 2 follow-up**：

- **跨设备 OCR result 同步**：
  - 新协议 `POST /update`，client 把 own-origin 行的 text_full + ocr_state 推给 primary
  - PullWorker 扫到 own-origin 行的 text_full 更新时回写本机 item 表（破现有"跳过 own-origin"的细化逻辑）
  - primary 也跑 OCR 处理 origin != self 的行（双管，先到先得，重复劳动可接受）
- **iOS client OCR**：iOS 没 Vision 桌面版（有 VNRecognizeTextRequest 但 API surface 略不同）—— iOS M5 阶段单独考虑
- **OCR 结果进 preview**：让 OCR 第一行变 image 行的 preview。当前 preview=nil，UI 显示 "📷 image"——OCR 后能不能改成显示 "「图里第一行文字」" 让列表行信息密度更高？留单独决策（涉及 UI + 用户偏好）
- **UI "可搜文字图片" 标识**：image 行右下角加个小 "Aa" 角标表示"此图已 OCR / 含文字"。Nice-to-have
- **`config.ocr.custom_words`**：Vision API 支持 `customWords` 提高术语 / 专名识别——等用户报"我的代码缩写老 OCR 错"再考虑
- **失败原因结构化**：当前 `last_push_error` 列被 OCR / push 共享（沿用 push 列名），未来如果想区分原因加 `last_ocr_error` 单独列
- **手动 OCR 单图 CLI**：`duo-pasted ocr <ITEM_ID>` 立刻同步跑一张并打印结果，调试用

**明确不做**：

- 不用 Tesseract / PaddleOCR 等第三方 OCR——Vision 在 Apple 平台准确度 + 性能 + 包大小最好，无理由换
- 不在 OCRWorker 里搞跨进程缓存 / 共享内存——单 daemon 单 actor 足够
- 不做 OCR-on-demand（"用户搜中文截图时 lazy 跑 OCR"）—— 让搜索 latency 不可预测，体感差；preflight 全部跑完再搜的体验明确

---

## 上下文给新 session 的关键索引

- **CLAUDE.md** 项目状态段已写明：M3 完成、blob 懒拉就位、OCR schema 预埋（PR#17）；本期是 OCR worker phase 1 落地
- **`hazy-hatching-bentley.md`** 第 3 刀：OCR schema 设计原文（已实现，背景参考）
- **`Database.swift:264-279`**：v6 migration 当前内容（ocr_state 列已加）
- **`Item.swift:23-28, 50, 118`**：OCRState enum + 字段 + CodingKeys
- **`CaptureService.swift:178-198`**：image 入库标 pending 的位置
- **`Admin.swift:202-225`**：promoteToPrimary 搬运 ocr_state 的语法
- **`PushWorker.swift`** 完整文件：actor 调度模式参考（OCRWorker 复用骨架）
- **`Config.swift:144-164`**：PullConfig 嵌套 struct 模式（OCRSettings 仿写）
- **`Config.swift:262-314`**：write() nested merge 模式（OCR dict 也要这样保留未知字段）
- **CLAUDE.md "关键设计决策"段**：bump ingested_at_ns 在 writer tx 内的原因；FTS5 trigger 行为；NSPasteboard 自写回环防御等——OCR worker 不直接相关但写入 own item 的 invariant 必须知道

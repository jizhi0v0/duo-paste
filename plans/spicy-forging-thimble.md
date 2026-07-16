# 文本 dedup：合并而非堆积重复行

> [!CAUTION]
> **已归档；不可作为部署说明。** 现行部署见 [`README.md`](../README.md) 与
> [`docs/deploy-multi-mac.md`](../docs/deploy-multi-mac.md)；未来工作只看
> [`docs/roadmap.md`](../docs/roadmap.md)。

## Context

当前 duo-paste 对**重复文本**有两种"漏网"路径，造成搜索结果里同字面值出现多条，挤压剪贴板列表心智：

1. **本机长间隔重复 copy**：CaptureService 已有 merge 逻辑（`Sources/DuoPasteCore/CaptureService.swift:92-117`），但被 `mergeWindowNs`（默认 300s）卡住——同一段文本超过 5 分钟再次 copy 就插新行。
2. **跨设备 ToDesk/远程桌面同步**：ToDesk 把 mini pasteboard 字节同步到 MBP，两台 watcher 各自 200ms 独立抓 → 两条 own-origin 行（一台在 item 表本机、一台经 mirror pull 进 item_mirror）。RemoteIngester 的 Continuity dedup（`Sources/DuoPasteSync/RemoteIngester.swift:69-81`）只在 primary 端 ±300s 窗内 reject，且只影响 primary 的 item 表——MBP 本地 own 行仍然存在，搜索 UI 还是两条。

用户想要的体感：**重复文本不像 image 需要 sha 抽象，字节相等即同**，只保留最新一条让它浮顶。

设计基线（用户已确认）：
- 文本永久窗口（不再 5 分钟限制）；image/file 走的 blob 路径**不动**——重复贴同一张图允许时间线上多次出现
- 双层防御：(a) 本机 capture 时永久 dedup + (b) searchUnion 跨表/跨设备 fold
- fold winner：`captured_at_ns` 最大者赢；pinned 通过 OR 聚合（任一条 pinned → fold 结果 pinned=true）
- RemoteIngester Continuity dedup **不动**——它管的是 primary push 接收侧 reject 语义，会牵动 push_state / audit-push 桶定义，单独议题

无 schema 变更。

## 修改点

### 1. `Sources/DuoPasteCore/Config.swift`：新增 text 专属窗口字段

`Config.CaptureLimits` 现有 `mergeWindowSec: Int = 300`（line 72/80/89/98/105），保留作为 **blob** 路径专用。

新增 `textMergeWindowSec: Int?`（nil = 永久 dedup；0 = 不 dedup；N = N 秒内 dedup），JSON key `text_merge_window_sec`：
- `init(...)` / `Codable` 编码解码 / `validate()` 添加 `>= 0 or nil` 校验
- 缺省值：`nil`（永久窗口，文本 dedup 总是合并）
- `Config.write` 的 captureDict 序列化路径（line 360 附近）补写新 key

### 2. `Sources/DuoPasteCore/CaptureService.swift`：拆分 text/blob 窗口计算

- `init` 新增 `textMergeWindowNs: Int64?`（nil 表示永久），从 `limits.textMergeWindowSec` 推导：`nil → nil; N → Int64(N) * 1_000_000_000`
- `ingestText`（line 84-140）改 mergeFloor 计算：`textMergeWindowNs` 为 nil 时**去掉** `captured_at_ns >= mergeFloor` filter，等价"任意时间内同 kind+同 text_full 未删行视为重复"。其余 merge 行为保持（bump capturedAtNs / source app fill / 客户端 reset push_state / primary bump ingested_at_ns）
- `ingestBlob`（line 142-203）**完全不动**——继续走 `mergeWindowNs`（300s）窗口

测试构造器路径：保留显式 `mergeWindowNs` 注入便于覆盖 blob；为 text 添加 `textMergeWindowNs` 注入。

### 3. `Sources/DuoPasteCore/Search.swift`：fetchUnion 增加文本 fold 层

`fetchUnion`（line 74-161）当前按 id 跨表 dedup。在 id-dedup 之后、kind/pinned filter 之前，**对 text/url/file kind**（即所有 `text_full` 非 nil 且 `blob_sha256` IS NULL 的行）按 `text_full` 二次 fold：

```swift
// id-dedup 之后 → 文本 fold
// blob kind 不参与（同字节图片可能是用户故意多次复制）
var byText: [String: (Item, String?)] = [:]
var nonText: [(Item, String?)] = []
for hit in byID.values {
    let item = hit.0
    if item.blobSha256 == nil, let text = item.textFull, !text.isEmpty {
        if let existing = byText[text] {
            // winner = captured_at_ns 大；pinned OR 聚合
            let winner = item.capturedAtNs > existing.0.capturedAtNs ? hit : existing
            var w = winner.0
            w.pinned = item.pinned || existing.0.pinned
            byText[text] = (w, winner.1)
        } else {
            byText[text] = hit
        }
    } else {
        nonText.append(hit)
    }
}
var deduped = Array(byText.values) + nonText
```

注意:
- fold 必须在 kind/pinned 后置 filter **之前**（line 128-134）——pinned 聚合后 winner 的 pinned 字段才是正确的过滤依据，符合现有"按 winner 行字段后置过滤"不变量（line 75-84 注释）
- prefixScore 计算（line 142-149）天然用 winner 行的 preview/text_full，无需改
- 排序契约保持 `(pinned DESC, prefixScore DESC, capturedAtNs DESC)` 不变

`fetchHits` / `fetchHitsMirror` 单表查询路径**不引入** SQL 端 text fold——原因：
- 单表内同 text_full 重复在新本机 dedup 后基本不存在（capture 时已合并）
- 跨表/跨设备的重复只在 `fetchUnion` 路径出现
- 在 SQL 端 fold 需要重写 ORDER BY + LIMIT 一刀流（line 92-96 已注释这是已知 tradeoff），收益不抵成本

### 4. `Sources/DuoPasteCore/Search.swift`：count 函数同步

`countByKindUnion` / `countUnion`（SQL CTE + ROW_NUMBER 选 winner）当前与 fetchUnion 口径一致。引入 fold 后，**count 与 list 口径必须仍一致**，否则 chip 数字、count、list 三者分裂。

方案：让 count 函数从 `fetchUnion(oversample, limit=Int.max, offset=0)` 走同源 Swift 路径计算（直接取 deduped count / 按 kind 分桶），抛弃 SQL CTE 路径。规模上剪贴板 item+mirror 万级，fold 几毫秒可接受；与 fetchUnion 文件内注释（line 91-96）说的 tradeoff 一致。

如果性能确认有问题，备选：保留 SQL CTE 但在外层 wrap Swift 端 text fold 计数——更复杂。**先走简单方案**，性能测有问题再优化。

### 5. 测试

新增 / 修改：

- `Tests/DuoPasteCoreTests/CaptureMergeWindowTests.swift`（新建或合到 `CaptureLimitsTests.swift`）
  - `textPermanentDedupBumpsAcrossLongGap`：textMergeWindowSec=nil，2 小时间隔 copy 同文本 → 第二次 outcome=.mergedWithPrevious，capturedAtNs 推进
  - `textZeroWindowDisablesMerge`：textMergeWindowSec=0 → 永远不合并
  - `textFixedWindowStillWorks`：textMergeWindowSec=60 → 60s 内合，超出不合
  - `blobDedupUnaffectedByTextWindowChange`：textMergeWindowSec=nil 不影响图片 300s 窗口

- `Tests/DuoPasteCoreTests/SearchUnionTests.swift`
  - `unionFoldsSameTextAcrossOwnAndMirror`：插 own=text "X" capturedAt=T2，mirror=text "X" capturedAt=T1<T2 → searchUnion 返回 1 条，行为 own（最新）
  - `unionFoldPreservesPinnedViaOR`：mirror pinned=true / own pinned=false 同 text → fold 结果 pinned=true，排序时排在前
  - `unionDoesNotFoldBlobsByPath`：两条 image 同 blob_sha256 → 不 fold，保持 2 行（image kind 不参与 text fold）
  - `unionFoldRespectsKindFilter`：fold 后 winner 是 text kind，q.kinds=[image] 应过滤掉

- `Tests/DuoPasteCoreTests/SearchPrefixBoostTests.swift`
  - 既有 case 通过即可——fold 不应破坏排序契约。如果 4 条现有用例的数据准备意外触发 fold，需补 distinct text 让 fold 不命中

### 6. CLAUDE.md "关键设计决策" 段更新

`### 搜索排序契约` 段下方新增 `### 文本永久 dedup` 小节：

> 文本 kind（text/url/file，即 `blob_sha256 IS NULL`）走永久 dedup：
> - capture 时 `config.capture.text_merge_window_sec=null` 默认无窗口，同字节文本合并 bump capturedAtNs
> - searchUnion 二次 fold 按 text_full 聚合跨表/跨设备重复，winner = max(capturedAtNs)，pinned OR 聚合
> - blob kind 不参与——同图片多次复制可能是用户故意，保持各自时间线
> - **不要回退到固定窗口**：用户心智是"剪贴板重复就该收起"，5 分钟窗口在 ToDesk/远程桌面场景下两端时间错位常超窗，回退会再现 issue

## 验证

```sh
swift build && swift test
# 期望全绿；PullWorker HTTP 偶发 flake 不算
swift test --filter SearchUnionTests
swift test --filter CaptureMergeWindowTests
swift test --filter SearchPrefixBoostTests
```

端到端手测：
1. 主 Mac 上 release 装好，`launchctl kickstart` 重启 daemon 加载新 config 默认（永久窗口）
2. Cmd+C 同一段文本两次（间隔几秒/几小时都行），⌥⌘V 打开搜索 → 期望只有 1 条
3. 让 mini 跟 MBP 各自捕获同文本（手工 echo X | pbcopy on each），MBP 搜索 → 期望只 1 条，winner 是后捕获那台
4. pin 某行后，再次复制同文本 → fold 应保留 pinned=true，排在置顶区

回归项：
- 同 sha 图片多次复制仍出 N 条（blob 不 fold）
- text vs file kind 内容字面相同时按 kind 分隔（merge 早在 SQL 端 `kind == c.kind` filter 防混）
- audit-push 桶定义不变（不动 RemoteIngester）

## 关键文件

- `Sources/DuoPasteCore/Config.swift:72,80,89,98,105,360,442` — CaptureLimits 加字段
- `Sources/DuoPasteCore/CaptureService.swift:84-140` — ingestText 拆窗口
- `Sources/DuoPasteCore/Search.swift:74-161` — fetchUnion 加文本 fold
- `Sources/DuoPasteCore/Search.swift:countByKindUnion / countUnion` — 与 fetchUnion 同源
- `Sources/DuoPasteSync/RemoteIngester.swift` — **不动**
- `Tests/DuoPasteCoreTests/{CaptureMergeWindowTests,SearchUnionTests,SearchPrefixBoostTests}.swift`
- `CLAUDE.md` — 文本永久 dedup 小节

## Non-goals

- 不动 RemoteIngester Continuity dedup（独立议题）
- 不引入 schema 变更（无 dedup_key 列、无 unique 约束）
- 不改 PushWorker / push_state 语义
- 不动 blob 路径合并窗口
- 不做"在 DB 物理层合并跨设备同文本行"（保持双行各自存在，UI 层 fold 即可——保留 audit / 历史溯源能力）

# 三端删除一致性 — 7 步实施版

> 执行版 of `plans/plan-hashed-allen.md`。每步独立 commit + 测试通过才走下一步。代码位置已对照当前 HEAD 验证。

## Context

duo-paste 初始设计意图是"多端一致"，现状有三处破坏：

1. iOS 单边引入 `HTTP DELETE /item/<id>`，Mac UI 没删除入口；`softDelete` 全代码库唯一调用方就是 iOS
2. `PullWorker.crossDeviceDedupWindowNs=5s` 默认值让 cross-device 副本不入 mirror，两台 Mac 行集合**从一开始就不对称**，UI 靠 `Item.foldByTextFull` 兜底
3. `PullWorker.applyPage` 的 own-origin guard (`PullWorker.swift:474`) 无差别 `continue`，让"绕回家"的 tombstone 永远到不了自家 own 行

具体孤儿可复现：iOS 配对 mini 后删 "118"，mini own tombstone 同步到 MBP（mirror 删了），MBP own 行（`019e546b-a09c-7f7b-9e9a-764fcceceb32`）永远删不掉 —— mini 没这条 mirror，cascade 找不到 sibling，PullWorker 拉不到 tombstone。

目标：删除做成 mesh first-class 操作，三端显示完全一致；分阶段、加 feature flag、回滚 < 10min。

## 验证基线（已对照 HEAD 核实）

- `MeshConfig` (`Sources/DuoPasteCore/Config.swift:311-379`) 当前**不含** `crossDeviceDedupWindowNs` / `deleteCascadeEnabled`，需要新增
- `PullWorker.Config` (`Sources/DuoPasteSync/PullWorker.swift:19-50`) 已含 `crossDeviceDedupWindowNs`，default `5_000_000_000`，**default 要改 0**
- daemon 构造 `PullWorker.Config` **唯一点**：`Sources/duo-pasted/AppDelegate.swift:479-482`（仅传 intervalSec + storageMode）
- `Database.softDelete` (`Sources/DuoPasteCore/Database.swift:754-770`) 当前 `→ Int64`（单 id），要改 `→ [(id, ingestedAtNs)]`
- `BumpError.alreadyDeleted` (`Database.swift:900-905`) 已存在
- `PullWorker.applyPage` own-origin guard：`Sources/DuoPasteSync/PullWorker.swift:474`
- `Server.swift:431-470` DELETE handler 调 `softDelete:448` + `broadcastCursorAdvanced:450-456`
- `AppState.togglePin` (`Sources/duo-pasted/AppState.swift:423-463`) — Step 5 copy pattern
- `AppState.postNotice` (`AppState.swift:469-478`) — 3s banner，复用
- `SearchView.swift:1114-1128` — contextMenu 现有 6 项（粘贴/Finder/Divider/OpenWith/Divider/Pin），加"删除"
- `SearchPanelController.swift:316-324` — chip-pop 确实没看 isCmd（plan §Step 4 bug 属实）
- `Auth.swift:42` `HMACAuth.sign` 签名正确
- `Tests/DuoPasteCoreTests/SoftDeleteTests.swift` 已存在 4 个测试，Step 2 cascade 测试**新建** `SoftDeleteCascadeTests.swift`（不混进原文件）

---

## Step 1 — feature flag 落地 + default 翻转

**改动**：

1. `Sources/DuoPasteCore/Config.swift` `MeshConfig` 加：
   ```swift
   public var crossDeviceDedupWindowNs: Int64 = 0
   public var deleteCascadeEnabled: Bool = true
   ```
   配套 Codable key + `CodingKeys` 加新 case + `init(from decoder:)` decodeIfPresent fallback default
2. `Sources/DuoPasteSync/PullWorker.swift:19-50` `Config.crossDeviceDedupWindowNs` default 从 `5_000_000_000` 改 `0`
3. `Sources/duo-pasted/AppDelegate.swift:479-482` 构造 `PullWorker.Config` 时显式拷贝（参照现有 `intervalSec` 下沉路径）：
   ```swift
   pullWorkerConfig: PullWorker.Config(
       intervalSec: TimeInterval(intervalSec),
       crossDeviceDedupWindowNs: cfg.mesh.crossDeviceDedupWindowNs,
       storageMode: cfg.mesh.storageMode
   ),
   ```

**测试**：新建 `Tests/DuoPasteCoreTests/MeshConfigDefaultsTests.swift` 锁定两个字段默认值 + 老 config.json（无新字段）decode 后 fallback 到 default。

**Commit**：`feat(config): MeshConfig 新增 crossDeviceDedupWindowNs/deleteCascadeEnabled——为后续 cascade 删除 + dedup 回滚口落地 flag`

**验证**：`swift test --filter MeshConfigDefaultsTests` 绿 + `swift build` 通过。

---

## Step 2 — `Database.softDelete` cascade 改造

**改动** `Sources/DuoPasteCore/Database.swift:754`：

```swift
public func softDelete(
    id: String,
    now: Int64,
    cascade: Bool = true
) async throws -> [(id: String, ingestedAtNs: Int64)]
```

writer tx 内逻辑：

1. 读目标行 → 不存在 throw `BumpError.notFound`，已 tombstone throw `BumpError.alreadyDeleted`
2. cascade=true 且目标 text-kind (`blob_sha256 IS NULL` 且 `text_full` 非空) → `SELECT id, text_full FROM item WHERE text_full = ? AND blob_sha256 IS NULL AND deleted_at_ns IS NULL`（含目标自己）
3. cascade=false / 目标 blob-kind → 集合只含目标 id
4. **explicit assertion**：每个 sibling 必须 `blob_sha256 IS NULL` + `text_full == target.text_full`（不等则 stderr warn 并跳过该 sibling，留 blob fold 未来的逃生口）
5. 逐个 `Self.nextIngestNs(db, now:)` 单增分配 + UPDATE
6. 返回 `[(id, newIngest)]`

**调用方更新**：
- `Sources/DuoPasteSync/Server.swift:448` DELETE handler 改：拿 results 取 `max(ingestedAtNs)` 喂 broadcaster，response payload `{ok, ingested_at_ns}` 仍返 max（保持线协议向前兼容，iOS 老版本无 schema 改动）

**测试**：新建 `Tests/DuoPasteCoreTests/SoftDeleteCascadeTests.swift`，5 个 case：
- cascade=false 只删单 id
- cascade=true 多 sibling 全部 tombstone + ingested 严格单增
- 已 tombstone sibling 跳过（不重写 deleted_at_ns）
- blob-kind 即便 cascade=true 也不 cascade（只删单 id）
- 在测试 hook 里注入 text_full 不等的 sibling → assertion warn + 跳过（不抛）

**Commit**：`feat(delete): softDelete cascade 同 text_full 全部 sibling——三端删除一致性 §C`

**验证**：`swift test --filter SoftDeleteTests --filter SoftDeleteCascadeTests` 绿 + `swift build`。

---

## Step 3 — `PullWorker.applyPage` own-origin tombstone 例外

**改动** `Sources/DuoPasteSync/PullWorker.swift:474`，把无脑 `continue` 拆成：

```swift
if item.originDevice == device {
    // 例外：自家 origin 的 tombstone 可回写本机 own 行（cascade 绕回家的场景）
    // 仅 incoming=tombstone + local=active + ingested 严格单增 才 UPDATE
    guard let deletedAt = item.deletedAtNs else { continue }
    guard let local = try Item.filter(Column("id") == item.id).fetchOne(db),
          local.deletedAtNs == nil,
          item.ingestedAtNs > local.ingestedAtNs else { continue }
    try db.execute(sql: """
        UPDATE item SET deleted_at_ns = ?, ingested_at_ns = ?
        WHERE id = ?
    """, arguments: [deletedAt, item.ingestedAtNs, item.id])
    continue  // 不进 INSERT OR REPLACE 主路径，captured_at_ns / 内容字段全部不动
}
```

**B 不加 feature flag** —— 纯防御性接收。没 cascade 的情况下 own tombstone 根本不会出现在 /since（mini 上没这条 row）。

**测试**：新建 `Tests/DuoPasteSyncTests/PullWorkerOwnTombstoneTests.swift`（避开 `PullWorkerTests` 已知偶发 flake，单跑 `--filter`），5 个 case：
1. incoming own tombstone + local active + ingested 更新 → UPDATE 应用
2. incoming own tombstone + local 已 tombstone → no-op
3. incoming own tombstone + local ingested 反而更大 → no-op（单增护栏）
4. incoming own active（非 tombstone）→ 仍 continue（旧 own-origin guard 语义保留）
5. mock 老 textFull 在 incoming 里 → 验证不回写 captured_at_ns / textFull

**Commit**：`feat(sync): PullWorker 例外接收自家 origin tombstone——三端删除一致性 §B`

**验证**：`swift test --filter PullWorkerOwnTombstoneTests` 绿 + `swift build`。

---

## Step 4 — `SearchPanelController` chip-pop bug 修复（Step 5 先决条件）

**改动** `Sources/duo-pasted/SearchPanelController.swift:316`：

```swift
if keyCode == 51 && !isCmd {  // 加 !isCmd 让 ⌘Backspace 透传给后续删除分支
    if !self.state.completionMenuVisible
        && self.state.query.isEmpty
        && !self.state.activeQualifiers.isEmpty {
        self.state.popLastQualifier()
        return true
    }
    return false
}
```

**测试**：本步是 1 行 fix，验证靠 Step 5 的 ⌘Backspace 端到端测试覆盖。如需独立测试可在 `Tests/duo-pastedTests/` 加一条 key monitor 路由用例，但**不强制**。

**Commit**：`fix(panel): chip-pop 仅在无 cmd 时触发——给 ⌘Backspace 让路`

**验证**：`swift build` 通过。

---

## Step 5 — Mac UI 删除入口

**改动**：

1. `Sources/duo-pasted/AppState.swift` 复用 `togglePin:423-463` pattern 加：
   ```swift
   func deleteItem(_ item: Item) {
       Task { @MainActor [weak self] in
           guard let self = self else { return }
           do {
               let results = try await self.deps.database.softDelete(id: item.id, now: Clock.nowNs())
               let maxIngest = results.map(\.ingestedAtNs).max() ?? 0
               let broadcaster = self.deps.wsBroadcaster
               let deviceID = self.deps.deviceID
               Task { await broadcaster.broadcastCursorAdvanced(deviceID: deviceID, latestIngestedAtNs: maxIngest) }
               await self.refresh()
               self.postNotice("已删除 \(results.count) 条")
           } catch BumpError.alreadyDeleted {
               await self.refresh()  // 幂等成功，刷新 UI
           } catch BumpError.notFound {
               self.postNotice("删除失败：项已不存在")
           } catch {
               self.postNotice("删除失败：\(error)")
           }
       }
   }
   ```
2. `Sources/duo-pasted/SearchView.swift:1114-1128` contextMenu 末尾追加：
   ```swift
   Divider()
   Button("删除", role: .destructive) { state.deleteItem(item) }
       .keyboardShortcut(.delete, modifiers: .command)
   ```
3. `Sources/duo-pasted/SearchPanelController.swift` `installKeyMonitor` 的 switch 之前加：
   ```swift
   if keyCode == 51 && isCmd {
       if let item = self.state.selectedItem { self.state.deleteItem(item) }
       return true
   }
   ```

**测试**：UI 改动，靠 Step 7 端到端 manual 验证；如有时间可加 `AppState.deleteItem` 单测（mock database 验证 broadcaster 被 fire-and-forget 调用 + postNotice 触发）。

**Commit**：`feat(ui): Mac contextMenu + ⌘Backspace 删除——三端删除一致性 §E`

**验证**：`swift build` 通过；`./scripts/install-agent.sh` 装一台 → Settings 看到删除按钮 + ⌘Backspace 能删（手动）。

---

## Step 6 — CLI `admin-soft-delete` 子命令

**改动**：

1. `Sources/DuoPasteCore/Admin.swift` 加 public static func：
   ```swift
   public static func softDelete(
       id: String,
       sharedSecret: Data,
       baseURL: URL,
       dbPath: String,
       forceDirect: Bool = false
   ) async throws -> AdminSoftDeleteResult
   ```
   优先走 HTTP localhost（复用 `HMACAuth.sign:42` + URLSession DELETE）；`URLError.cannotConnectToHost` 或 `forceDirect=true` → 降级直 DB（`DatabasePool` + `Database.softDelete`，broadcaster 不发，warn "peer 看到 tombstone 要等 PullWorker tick（默 30s）"）。
2. `Sources/duo-pasted/CLI.swift:15` switch 加 `case "admin-soft-delete": runAdminSoftDelete(args: rest)`；参数 `<id>` 必填 + 可选 `--direct`。secret 加载复用 `CLI.swift:438` 同款 `SharedSecret.load(from: paths.sharedSecretFile)` pattern。

**测试**：新建 `Tests/DuoPasteCoreTests/AdminSoftDeleteTests.swift`（仿 `AdminTests.swift` 现有 pattern），两条路径：
- HTTP 路径：mock URLSession 返 200 + 校验 HMAC header 格式
- 降级路径：HTTP throw `URLError.cannotConnectToHost` 时 fallback 直 DB（在 tmp 路径起 DatabasePool 验证 tombstone 写入）

**Commit**：`feat(cli): admin-soft-delete 子命令——清存量孤儿 + daemon offline 降级`

**验证**：`swift test --filter AdminSoftDeleteTests` 绿 + `swift build`。

---

## Step 7 — 全量验证 + 清孤儿 `019e546b-a09c-7f7b-9e9a-764fcceceb32`

按以下顺序：

1. **全量测试**：
   ```sh
   swift test
   # PullWorker / BlobLazyPull 已知偶发并发 flake，单跑：
   swift test --filter PullWorkerTests
   swift test --filter BlobLazyPullTests
   swift test --filter PullWorkerOwnTombstoneTests
   swift test --filter SoftDeleteCascadeTests
   swift test --filter MeshConfigDefaultsTests
   swift test --filter AdminSoftDeleteTests
   ```

2. **装两台 daemon**（MBP + mini）：
   ```sh
   ./scripts/install-agent.sh
   ```

3. **清孤儿**（MBP 上跑，因为 own 行在 MBP）：
   ```sh
   ~/Applications/duo-paste/duo-pasted admin-soft-delete 019e546b-a09c-7f7b-9e9a-764fcceceb32
   ```
   预期：HTTP localhost 路径成功，broadcaster fan-out，mini 通过 PullWorker 看到 own tombstone（Step 3 例外接收）→ mini own 行也 tombstone → iOS /since 看到 tombstone → 三端不显示。

4. **三端一致性验证**：
   ```sh
   # MBP
   sqlite3 ~/Library/Application\ Support/duo-paste/db/main.sqlite \
     "SELECT id, origin_device, deleted_at_ns FROM item WHERE text_full='118' OR id LIKE '019e546b%'"
   # mini 同样查
   # iOS UI 翻历史确认 "118" 不显示
   ```
   预期：MBP own + mini own + 双向 mirror 全部 `deleted_at_ns` 非空。

5. **正向端到端 manual**：
   - iOS 删一条同时存在三端的内容 → 三端不显示
   - MBP ⌘Backspace 删一条 → mini + iOS 不显示 + 3s banner
   - re-capture：MBP 删 "test123" 后再 cmd+C "test123" → 新行进 own + UI 显示（CaptureService merge 过滤 deleted_at_ns IS NULL，新 id 不在 cascade 范围）

6. **回滚演练**：`config.json` `mesh.delete_cascade_enabled=false` + `launchctl kickstart -k gui/$UID/io.duopaste.agent` → 新删除退化为单 id（不 cascade）。

**Commit**：无代码改动，本步是 release 验证 + 清孤儿。如发现 bug 退回对应 Step 修复。

---

## 关键不变量（任何 step 不要破坏）

- **B + C + D 渐进可关**：D 改 `crossDeviceDedupWindowNs` 不影响 B/C；C 由 `deleteCascadeEnabled` flag 控；B 是纯防御无 flag（没 cascade 时 own tombstone 根本不出现在 /since）
- **re-capture 是新 id 不在 B 覆盖范围**：`CaptureService.swift:135` merge 过滤 `deleted_at_ns IS NULL`，删后再 copy 走 INSERT 新 id（这是正确语义，不要被 review 误改）
- **broadcaster 不在 CLI 进程**：CLI 走 HTTP localhost 让 daemon 自己 fan-out；降级直 DB 路径**不**发 broadcaster，peers 等下次 PullWorker tick 兜底
- **softDelete cascade explicit assertion 不抛**：text_full 不等的 sibling 只 stderr warn 并跳过，给未来 blob fold 留逃生口
- **line protocol 兼容**：Server.swift DELETE handler response payload schema 不变（`{ok, ingested_at_ns}`，多行 cascade 取 max），iOS 不需要改

## 关键文件清单（按 Step 顺序）

| Step | 文件 | 行号（验证后） | 改动 |
|---|---|---|---|
| 1 | `Sources/DuoPasteCore/Config.swift` | 311-379 | MeshConfig 加 2 字段 |
| 1 | `Sources/DuoPasteSync/PullWorker.swift` | 19-50 | Config.crossDeviceDedupWindowNs default 改 0 |
| 1 | `Sources/duo-pasted/AppDelegate.swift` | 479-482 | PullWorker.Config 构造点显式拷贝 |
| 2 | `Sources/DuoPasteCore/Database.swift` | 754 | softDelete 改签名 + cascade |
| 2 | `Sources/DuoPasteSync/Server.swift` | 448-456 | DELETE handler 适配 max(ingested) |
| 3 | `Sources/DuoPasteSync/PullWorker.swift` | 474 | own-origin tombstone 例外 UPDATE |
| 4 | `Sources/duo-pasted/SearchPanelController.swift` | 316 | chip-pop 加 !isCmd |
| 5 | `Sources/duo-pasted/AppState.swift` | 423-463 后 | deleteItem 函数 |
| 5 | `Sources/duo-pasted/SearchView.swift` | 1114-1128 | contextMenu 加"删除" |
| 5 | `Sources/duo-pasted/SearchPanelController.swift` | installKeyMonitor | ⌘Backspace 路由 |
| 6 | `Sources/DuoPasteCore/Admin.swift` | 末尾 | softDelete func |
| 6 | `Sources/duo-pasted/CLI.swift` | :15 switch | admin-soft-delete dispatcher |

复用现有：`HMACAuth.sign` (`Auth.swift:42`) / `SharedSecret.load` (`CLI.swift:438` pattern) / `Item.foldByTextFull` (`Item.swift:178`) / `Database.nextIngestNs` / `AppState.postNotice` (`AppState.swift:469-478` 3s banner)。

## 测试新增清单

- `Tests/DuoPasteCoreTests/MeshConfigDefaultsTests.swift`（Step 1）
- `Tests/DuoPasteCoreTests/SoftDeleteCascadeTests.swift`（Step 2，不混进现有 `SoftDeleteTests.swift`）
- `Tests/DuoPasteSyncTests/PullWorkerOwnTombstoneTests.swift`（Step 3，避开 `PullWorkerTests` 偶发 flake）
- `Tests/DuoPasteCoreTests/AdminSoftDeleteTests.swift`（Step 6，仿 `AdminTests.swift`）

## 风险监控（部署后头几天）

- daemon stderr：`tail -f ~/Library/Logs/duo-paste/duo-pasted.err.log | grep -E "cascade|own-tombstone|softDelete"` 看 cascade 命中 row 数
- 如果出现 cascade 范围异常（误删用户故意保留的副本）→ 立刻 `config.json` 改 `mesh.delete_cascade_enabled=false` + `launchctl kickstart -k` 回退到单 id 删除模式（< 10min 回滚）

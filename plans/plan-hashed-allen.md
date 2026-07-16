# 三端删除一致性架构对齐

> [!CAUTION]
> **已归档；不可作为部署说明。** 现行部署见 [`README.md`](../README.md) 与
> [`docs/deploy-multi-mac.md`](../docs/deploy-multi-mac.md)；未来工作只看
> [`docs/roadmap.md`](../docs/roadmap.md)。

## Context

duo-paste 初始设计意图是"多端数据一致性"，但实际现状破坏了这个意图：

1. **iOS 单边引入了删除功能**（`HTTP DELETE /item/<id>` → `Database.softDelete`），Mac UI 没有删除入口。`softDelete` 全代码库唯一调用方是 iOS 长按删除
2. **PullWorker `crossDeviceDedupWindowNs=5s` 隐性破坏对称性**：本机 own 同内容 ±5s 内还活着时 mirror skip 不入库（`Sources/DuoPasteSync/PullWorker.swift:499-516`）。结果两台 Mac 的 row 集合从一开始就不对称，但 `Item.foldByTextFull` 在 UI 层把不对称藏起来了
3. **PullWorker own-origin guard 无差别拦截**：`if item.originDevice == device { continue }` (`PullWorker.swift:474`) 让"绕回家"的元数据更新（包括 tombstone）永远到不了自家 own 行

后果（已有具体孤儿可复现）：iOS 配对 mini 后删 "118"，mini own 行 tombstone 正确同步到 MBP（mirror 删了），但 MBP own 行（id=`019e546b-a09c-7f7b-9e9a-764fcceceb32`）永远删不掉——mini 上根本没这条的 mirror，cascade 找不到 sibling，PullWorker 也拉不到 tombstone。三端显示不一致。

目标：把"删除"做成 mesh first-class 操作，三端（MBP + mini + iOS）显示完全一致。立场是用户的"对齐三端、稳定成熟、慢慢来"——分阶段、加 feature flag、回滚成本 < 10min。

## 整体策略

五个独立可验证组件：

| 组件 | 改动位置 | 作用 |
|---|---|---|
| **B**: PullWorker own-origin tombstone 例外接收 | `PullWorker.applyPage` | 让自家 own 行的 tombstone 能通过 /since 回到本机 |
| **C**: `softDelete` cascade sibling | `Database.softDelete` | 删一条就把同 text_full 所有 active sibling 一并 tombstone |
| **D**: 关闭 dedup（默认 0） + config 暴露 | `MeshConfig` + `PullWorker.Config` | 让 cross-device 副本老实进 mirror；config 保留紧急回滚口 |
| **E**: Mac UI 加删除入口 | `AppState` + `SearchView` + `SearchPanelController` | contextMenu "删除" + ⌘Backspace 快捷键 |
| **F**: CLI `admin-soft-delete` 子命令 | `Admin` + `CLI` | 清存量孤儿，HTTP localhost 优先 + daemon offline 降级直 DB |

## 分阶段实施（按依赖顺序）

### Step 1: MeshConfig 加 feature flag

`Sources/DuoPasteCore/Config.swift` 的 `MeshConfig`（围绕 `mesh.enabled` / `pull_interval_sec` / `ws_enabled`）加两个字段：

```swift
// 默 0 = 关 dedup（让 cross-device 副本进 mirror，靠 UI fold 折叠）
// 设 5_000_000_000 恢复历史行为（单台机器临时回退用）
public var crossDeviceDedupWindowNs: Int64 = 0

// 默 true = softDelete 自动 cascade 同 text_full 所有 active sibling
// 设 false 退化为只删单 id（紧急回滚用）
public var deleteCascadeEnabled: Bool = true
```

下沉到 `PullWorker.Config.crossDeviceDedupWindowNs`（现存字段，default 改 0）+ `Database.softDelete` 新增 `cascade: Bool` 参数。

回归测试：写 `MeshConfigDefaultsTests` 锁定两个字段默认值（防未来误改）。

### Step 2: `Database.softDelete` cascade

`Sources/DuoPasteCore/Database.swift:754` 改签名：

```swift
public func softDelete(
    id: String,
    now: Int64,
    cascade: Bool = true
) async throws -> [(id: String, ingestedAtNs: Int64)]
```

writer tx 内：

1. 查目标 row 存在 + 未 tombstone + 拿 `text_full` / `blob_sha256`
2. cascade=true 且目标是 text-kind（`blob_sha256 IS NULL` 且 `text_full` 非空）→ `SELECT id FROM item WHERE text_full = ? AND blob_sha256 IS NULL AND deleted_at_ns IS NULL`（包含目标自己）
3. cascade=false 或目标是 blob-kind → 集合只含目标 id
4. **explicit assertion**：每个 sibling 必须 `blob_sha256 IS NULL` + `text_full == target.text_full`（给未来加 blob fold 留逃生口）
5. 逐个 `Self.nextIngestNs(db, now:)` 单增分配 + UPDATE tombstone
6. 返回 [(id, newIngest)] 列表

调用方更新：
- `Server.swift:431` DELETE handler：用 `max(ingestedAtNs)` 调 `broadcaster.broadcastCursorAdvanced` 一次；response payload 仍返 `{ok, ingested_at_ns}`（取 max）保持线协议兼容
- `Admin.softDelete` 新增（Step 6 用）

回归测试 `SoftDeleteCascadeTests.swift`：
- 单 id（cascade=false 或无 sibling）
- 多 sibling fold group 全部 tombstone + ingested 单增
- 已 tombstone sibling 跳过（不重写 deleted_at_ns）
- blob-kind 不 cascade（即便 cascade=true）
- explicit assertion 触发 log（mock 一行 text_full 不等的 sibling 进集合）

### Step 3: `PullWorker.applyPage` own-origin tombstone 例外

`Sources/DuoPasteSync/PullWorker.swift:474` 拆分：

```swift
if item.originDevice == device {
    // 例外：自家 origin 的 tombstone 可以回写本机 own 行（cascade 绕回来的场景）
    // 仅 incoming 是 tombstone + local 未 tombstone + incoming 比 local 新（ingested 单增护栏）
    guard let deletedAt = item.deletedAtNs else { continue }
    let local = try Item.filter(Column("id") == item.id).fetchOne(db)
    guard let local = local,
          local.deletedAtNs == nil,
          item.ingestedAtNs > local.ingestedAtNs else { continue }
    try db.execute(sql: """
        UPDATE item
        SET deleted_at_ns = ?, ingested_at_ns = ?
        WHERE id = ?
    """, arguments: [deletedAt, item.ingestedAtNs, item.id])
    continue  // 不进 INSERT OR REPLACE 主路径，不动 captured_at_ns / 内容字段
}
```

**B 不加 feature flag**——纯防御性接收，没 cascade 的情况下 own tombstone 根本不会出现在 /since（mini 上没这条 row），B 是空跑无副作用。

回归测试 `PullWorkerOwnTombstoneTests.swift`（已知 PullWorkerTests 偶发并发 flake，新文件单独 `--filter` 跑）：
- incoming own tombstone + local active + ingested 更新 → UPDATE 应用
- incoming own tombstone + local 已 tombstone → no-op
- incoming own tombstone + local ingested 更新（merge bump 已发生）→ no-op（ingested 单增护栏）
- incoming own active（非 tombstone）→ 仍 continue（旧 own-origin guard 语义保留）
- 不动 captured_at_ns 内容字段（mock 老 textFull 不应该回写）

### Step 4: 修 `SearchPanelController` chip-pop 隐藏 bug

`Sources/duo-pasted/SearchPanelController.swift:316` 附近的 chip-pop 分支当前没看 `isCmd`，会吞 ⌘Backspace。修法：

```swift
if keyCode == 51 && !isCmd {  // 加 !isCmd
    if !completionMenuVisible && query.isEmpty && !activeQualifiers.isEmpty {
        popLastQualifier()
        return true
    }
    return false
}
```

这是先决条件，否则 Step 5 的 ⌘Backspace 永远到不了删除分支。

### Step 5: Mac UI 加删除入口

复用 `AppState.togglePin` (`Sources/duo-pasted/AppState.swift:423-463`) 同款 pattern：

```swift
func deleteItem(_ item: Item) {
    Task {
        do {
            let results = try await self.deps.database.softDelete(id: item.id, now: Clock.nowNs())
            let maxIngest = results.map(\.ingestedAtNs).max() ?? 0
            let broadcaster = self.deps.wsBroadcaster
            Task { await broadcaster.broadcastCursorAdvanced(deviceID: deviceID, latestIngestedAtNs: maxIngest) }
            await self.refresh()
            // 3s banner 反馈（softDelete 不可逆，跟 pin 切换性质不同）
            self.postNotice("已删除 \(results.count) 条")
        } catch BumpError.alreadyDeleted { /* 幂等成功 */ }
        catch { self.postNotice("删除失败：\(error)") }
    }
}
```

挂接：
- `SearchView.swift:1114` contextMenu：在最后 Divider 后加 `Button("删除", role: .destructive) { state.deleteItem(item) }`，role: .destructive 让 SwiftUI 自动红字
- `SearchPanelController.installKeyMonitor` 在 switch 之前加：`if keyCode == 51 && isCmd { if let item = selectedItem { state.deleteItem(item) }; return true }`

3s banner 反馈复用 `AppState.postNotice`（已有 pin/paste 反馈机制）。

**不做二次确认 alert**——剪贴板心智里删除高频；3s banner 已经足够"我做了删除"反馈，硬要 undo 走 admin-undelete CLI（未来加）。

### Step 6: CLI `admin-soft-delete` 子命令

`Sources/DuoPasteCore/Admin.swift` 加：

```swift
public static func softDelete(
    id: String,
    sharedSecret: Data,
    baseURL: URL,
    dbPath: String
) async throws -> AdminSoftDeleteResult {
    // 优先 HTTP localhost：复用 HMACAuth.sign + URLSession DELETE
    // 走完整 softDelete + cascade + broadcaster fan-out
    do {
        let result = try await deleteViaHTTP(id: id, secret: sharedSecret, baseURL: baseURL)
        return .viaHTTP(result)
    } catch HTTPDeleteError.daemonOffline {
        // 降级：直接 Database.softDelete，broadcaster 不发，next PullWorker tick 兜底
        let pool = try DatabasePool(path: dbPath)
        let db = try DuoPasteCore.Database(pool: pool)
        let results = try await db.softDelete(id: id, now: Clock.nowNs())
        return .directDB(results: results, warn: "daemon offline, broadcaster skipped; peers 看到 tombstone 要等 PullWorker 下次 tick（默 30s）")
    }
}
```

`Sources/duo-pasted/CLI.swift:12` switch 加 `case "admin-soft-delete": runAdminSoftDelete(args: rest)`。参数：`<id>`（必填）+ 可选 `--direct` 强制走直 DB 跳过 HTTP。

HMAC 签名复用 `Sources/DuoPasteCore/Auth.swift:42` `HMACAuth.sign`；secret 加载复用 `SharedSecret.load(from: paths.sharedSecretFile)`（参考 `CLI.swift:438` 现成 pattern）。

回归测试：跟随 `AdminTests.swift` 现有 pattern 加 `AdminSoftDeleteTests.swift`，mock URLSession 测两条路径。

### Step 7: 全量验证 + 清当前孤儿

1. `swift test` 全跑（PullWorker / BlobLazyPull 已知偶发 flake，单跑 `--filter` 验绿）
2. `./scripts/install-agent.sh` 装新 daemon 两台
3. 清当前孤儿："118" id=`019e546b-a09c-7f7b-9e9a-764fcceceb32`：
   ```sh
   ~/Applications/duo-paste/duo-pasted admin-soft-delete 019e546b-a09c-7f7b-9e9a-764fcceceb32
   ```
4. 验证：MBP / mini sqlite 都看到 tombstone；iOS 不显示

## 关键不变量

- **B + C + D 是渐进可关的**：D 改 `crossDeviceDedupWindowNs` 不影响 B/C；C 改 `cascade: Bool` 退化为单 id 删；B 是纯防御无副作用。三层独立 flag 让回滚 < 10min（改 config + `launchctl kickstart -k`）
- **re-capture 是新 id 不在 B 覆盖范围**：CaptureService merge 过滤 `deleted_at_ns IS NULL`（`CaptureService.swift:135`），用户在 own 行 tombstone 后再次复制 → INSERT 新 id 走 capture 主路径，不会被旧 tombstone 抹掉。这是正确语义，plan 文档要写明避免被 review 误改
- **broadcaster 不在 CLI 进程**：`AppDependencies.wsBroadcaster` 是 daemon 单例。CLI 走 HTTP localhost 让 daemon 自己 fan-out 是唯一干净路径
- **softDelete 不可逆**（除非加 admin-undelete）：3s banner 反馈是用户唯一感知，UI 不弹 alert（剪贴板心智）

## 关键文件

- `Sources/DuoPasteCore/Config.swift` — MeshConfig 加 2 个字段
- `Sources/DuoPasteCore/Database.swift:754` — softDelete cascade 改造
- `Sources/DuoPasteSync/PullWorker.swift:474` — own-origin tombstone 例外
- `Sources/DuoPasteSync/Server.swift:431` — DELETE handler 适配新签名
- `Sources/duo-pasted/AppState.swift:423` — deleteItem 仿 togglePin pattern
- `Sources/duo-pasted/SearchView.swift:1114` — contextMenu "删除" 按钮
- `Sources/duo-pasted/SearchPanelController.swift:316` — chip-pop bug fix + ⌘Backspace 路由
- `Sources/DuoPasteCore/Admin.swift` — softDelete 函数（HTTP 优先 + DB 降级）
- `Sources/duo-pasted/CLI.swift:12` — admin-soft-delete dispatcher

复用现有：
- `HMACAuth.sign` (`Sources/DuoPasteCore/Auth.swift:42`)
- `SharedSecret.load` (CLI.swift:438 pattern)
- `Item.foldByTextFull` (`Sources/DuoPasteCore/Item.swift:178`) — cascade 范围跟 fold 契约同源
- `Database.nextIngestNs` — cascade 内多 row tombstone 单增分配
- `AppState.postNotice` — Mac UI 3s banner 反馈

## 验证

### 单元测试

- `SoftDeleteCascadeTests.swift`（新）：cascade 范围、explicit assertion、ingested 单增、blob-kind 不 cascade
- `PullWorkerOwnTombstoneTests.swift`（新）：B 的 5 个边界（incoming 新/旧、local 状态、不动内容字段）
- `MeshConfigDefaultsTests.swift`（新）：锁定 `crossDeviceDedupWindowNs=0` + `deleteCascadeEnabled=true` 默认值
- `AdminSoftDeleteTests.swift`（新）：HTTP 路径 + daemon offline 降级路径

### 端到端 manual 测试

1. **正向**：iOS 删一条同时存在于 MBP + mini 的内容 → 验证 MBP / mini sqlite 三条相关 row（MBP own + mini own + mirror）全部 `deleted_at_ns` 非空；iOS UI 不显示
2. **Mac UI 入口**：MBP 上 ⌘Backspace 删一条 → 验证 mini + iOS 同样不显示；3s banner 反馈
3. **CLI 孤儿清理**：手动跑 `admin-soft-delete <id>` → 验证三端一致
4. **re-capture 语义**：删 "test123"，再 cmd+C "test123" → 验证新行进 own + UI 显示
5. **回滚演练**：`config.json` 改 `mesh.delete_cascade_enabled=false` → `launchctl kickstart -k` → 验证新删除退化为单 id（不 cascade）

### 风险监控

- 部署后头几天观察 daemon stderr 日志：搜 `cascade` / `own-tombstone` 关键字记录的 row 数，确认行为符合预期
- 如果出现 cascade 范围异常（误删用户故意保留的副本），立刻改 config flag 关 cascade 回退到单 id 删除模式

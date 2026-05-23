# iOS 删除路径 fold-aware 对齐

## Context

PR #32（已合并 `2f538ec`）让 server side `DELETE /item/<id>` cascade 同 `text_full` 所有 active sibling（跨 origin）。iOS 端已经在 UI 层 `Item.foldByTextFull` 折叠（见 `iOS/DuoPaste/HistoryStore.swift:54`），但 `removeOptimistic(id:)`（同 file:180）只按单 id 移除——同 text_full 的 sibling 仍在 `items` 里，fold 会立刻 elect 另一条当代表 → 用户视感"卡片好像没删掉，几秒后才真消失"（等 `/since` 把 cascade tombstones 拉回 iOS）。

非 PR #32 引入的回归（旧 iOS 单 id DELETE 也有这个症状，只是 server 不 cascade 时 siblings 永远不被 tombstone，glitch 更隐蔽）。但 PR #32 之后这条路径变成"server 端正确 cascade + iOS 端短暂闪回"，肉眼可察。

## 目标

- 用户长按 iOS 上的 fold 卡片 → **即刻**彻底消失（不闪一下又回来一条同内容）
- 网络失败兜底逻辑（`pendingDeletes` / banner / 60s prune）语义不变
- 不需要 wire schema 改动 / server 改动

## Non-Goals

- iOS 客户端做 server-side cascade（已由 PR #32 在 Mac 端 cascade，iOS 仍只发单 id DELETE）
- iOS 端 GRDB mirror / 搜索切到 SearchAPI（属另一项工作 — 现有 `plan-hashed-allen` 之外的 follow-up）
- 改 `Item.foldByTextFull` 折叠契约本身

## 改动（3 个文件）

### 1. `iOS/DuoPaste/HistoryStore.swift`

**(a)** `removeOptimistic(id:)` → `removeOptimistic(item:)`，按 `item.textFull` 把 `items` 里所有同 `text_full` 行一并 remove（cascade in optimistic 层）。img / blob kind 不参与 cascade（保留单 id 语义，跟 server `softDelete` cascade 范围一致——后者也只对 text kind cascade）。

**(b)** `pendingDeletes` 字段语义保留 key=id（兼容现有 banner 逻辑），同时新增 `pendingDeleteTextFulls: [String: Date]` key=text_full —— `merge()` 在 `it.isTombstone == false` 分支检查 `it.textFull` 是否在 pending text 集里，命中且未超 grace 则 skip 入库（防 in-flight `/since` 把同 text_full sibling 带回引发闪回）。tombstone 行到达时清对应 text_full entry。同样 60s prune。

**(c)** `merge` 内 resurrected banner 触发逻辑：原来按 id 命中 pendingDeletes 算 resurrected，现在补一层"text_full 命中且 grace 已过"也算 — 让 cascade 失败场景也能弹 banner。

### 2. `iOS/DuoPaste/HistoryCellView.swift`

`coordinator.deleteItemOnServer(id: item.id)` 之前的 `store.removeOptimistic(id:)` 调用点改成 `store.removeOptimistic(item:)`。`deleteItemOnServer` 本身不变（server 端 cascade）。

### 3. `iOS/DuoPasteTests/HistoryStoreOptimisticDeleteTests.swift`（新文件）

5 条契约：
- 删 fold 代表 → `items` 里同 text_full 多行（不同 id / origin）全部 remove
- pendingDeleteTextFulls 命中 → 后续 merge 把同 text_full sibling 进来时 skip
- tombstone 行到达 → 清 pendingDeleteTextFulls 对应 entry
- text kind 才 cascade，img / blob kind 仍按 id 单删
- 60s prune 不残留

## 不变量

- `byID` 仍按 id 去重避免列表重复
- `pendingDeleteTextFulls` 只在 grace 窗口（3s）内压住 sibling re-insert；超 grace 视为 server 没删，让行进 items 触发 banner
- `removeOptimistic` 同 text_full 多行 remove 时全部进入 pending（id 一份 + text_full 一份）
- banner 文案不变（"N 条删除未送达 Mac"）

## 回滚口

无需 feature flag — `removeOptimistic` 改造在 client 侧，行为差仅是"立即移除多行 vs 单行"。出错时 revert PR → 回退到"短暂闪回再消失"的 PR #32 现状（数据一致性不受影响）。

## 部署

iOS rebuild 安装到测试机（`devicectl` / xcodebuild）。server / Mac daemon 不需重启。

## 验证

- [ ] 单测全过（含新 `HistoryStoreOptimisticDeleteTests`）
- [ ] 端到端：mini copy 一段 → iOS 看到 fold 卡（mini own + MBP mirror 同 text）→ 长按删除 → 卡片**即刻**消失 + Mac/MBP DB 双 tombstone（sqlite 验）
- [ ] 网络中断场景：iOS 飞行模式删 → 乐观移除 + 60s 后真复活 → 顶部 banner 显示

## Follow-ups（不属本 PR）

- iOS 端 GRDB mirror（让搜索走 SearchAPI 跟 Mac 同口径，eliminate 客户端 fold 的边界 case）
- pendingDeletes / pendingDeleteTextFulls 合并成单 `PendingDelete` 结构（如果未来再叠维度可考虑）

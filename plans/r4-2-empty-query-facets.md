# R4.2 空查询与类型计数优化

状态：✅ 完成（2026-07-17）

完成记录：v16 `search_fold` projection + dirty group trigger 已上线，`SearchProvider` 每次刷新只调一次 `searchSummary`。文本/blob/pin/qualifier/suffix/time fallback 等价测试全绿，真实 v15 百万行库迁移后 `integrity_check=ok`；日用库迁移后 item=19,413、fold=15,493、dirty=0、`quick_check=ok`。M3 Max / 36GiB、100 万行 / 8GiB sparse、20 samples 的最终 p95：empty page 1.57ms、完整 summary 49.15ms、qualifier 6.57ms、offset 100k 38.26ms、first-screen data 16.64ms、真实 keypress-to-render 95.28ms。完整 894 tests、macOS Release、iOS Simulator Release 与 Developer ID daily-driver 部署均通过；17 Pro 当时显示 unavailable，未做真机安装。

## 目标

把 `SearchProvider` 每次刷新对同一结果集执行的 list / total / kind / file-sub-kind 四次 fold 收敛成一次 summary；为空查询建立可增量维护的 fold projection，让百万行库的最近页、总数和类型计数不再解码并 fold 全表。

必须保持现有展示契约：文本按 byte-equal `text_full` 永久跨 origin fold，winner 取最新 capture、pin 做 OR；blob 仅折叠 15 秒内不同 origin 的同 SHA，代表行/排序时间保持不变；qualifier 在 fold 后按 winner 字段过滤。

## 设计

- 新增 `SearchAPI.searchSummary`，一次返回 hits/snippets、total、kind counts 和 file-sub-kind counts。
- 非空搜索与自定义时间范围复用一份无 qualifier 的 fold 结果，在 Swift 端派生 list/total/facets，避免四次重复 fold。
- v16 增加 `search_fold` projection、dirty-key 队列和 item 触发器。空搜索且无时间范围时：先在 writer transaction 内精确刷新 dirty group，再用 projection 的索引/聚合查询 list 与 counts。
- projection 只存 fold 后展示行的索引字段并回连 canonical `item`；不复制 blob，不进入 wire/sync。文本、blob、passthrough group 仍调用 `Item.foldByTextFull`，避免维护第二份 fold 语义。
- dirty key 少时只重算受影响 group；批量导入/迁移后超过阈值则流式全量重建，避免百万个逐 key query。
- 回滚可删除 v16 projection 表/trigger 并让调用方退回既有 fold 路径；`item` wire 和 mesh 协议不变。

## 性能门

- 复用 R4.1 的 100 万行 / 8 GiB sparse 数据集和 release runner。
- `count_by_kind` p95 从 25.69s 降到 `<150ms`。
- 新增/记录空查询完整 summary（最近 200 + total + facets）p95 `<150ms`，同时保留 R4.1 warm FTS 与真实首屏既有 gate。
- 增量单 group refresh 不触发全量 projection rebuild；测试通过 dirty row 数与查询结果共同约束。

## 测试矩阵

- [x] `searchSummary` 与原四条 API 在文本 fold、blob cluster、pin OR、分页和 qualifier OR 上严格等价。
- [x] suffix chip scope、pinned-only、自定义时间范围与非空 FTS/snippet 等价。
- [x] insert/update/pin/delete 后只刷新 dirty group，结果立即精确；daemon 重启后 projection 可复用。
- [x] v16 从旧库迁移、空库、批量 benchmark rebuild 均通过 `integrity_check`。
- [x] benchmark runner 使用生产 `searchSummary`，不再维护“四段查询”代理路径。
- [x] 百万行 release 性能门、完整测试、macOS Release、iOS Simulator Release 全绿。

## 完成条件

- [x] 上述测试矩阵与性能门逐项验证后打勾。
- [x] `CLAUDE.md` 写入 projection/dirty refresh 与 fallback 不变量。
- [x] `docs/roadmap.md` 的 R4.2 标记完成并同步实测数字。

## 验证记录

- 红测先行：`SearchAPI.searchSummary` / v16 schema 尚不存在时，新测试按预期编译失败；实现后 3 项 summary/projection 测试转绿，并纳入完整测试。
- 语义：覆盖文本跨 origin winner + pin OR、blob 15s cluster 与同 origin timeline、kind/file-sub-kind/suffix OR、literal `%` suffix、pinned-only、分页、FTS snippet、自定义时间范围 fallback、UPSERT trigger 冲突和 reopen。
- 迁移：R4.1 的真实 v15 百万行库原地升 v16，`item=1,000,000`、`search_fold=801,994`、`dirty=0`、`PRAGMA integrity_check=ok`；DB 主文件从基线 481MiB 增至 735MiB（projection 的明确磁盘成本）。最终 report 会重读测量时 DB 大小，避免 `--reuse` 沿用旧 manifest 数字。
- 性能：[`benchmarks/results/r4-2-20260717-m3-max.json`](../benchmarks/results/r4-2-20260717-m3-max.json)，20/20 samples；summary gate `49.15ms <150ms`、warm FTS `8.75ms <100ms`、真实 render `95.28ms <150ms`。
- 相对 R4.1：count/facets 25,694.79→49.15ms（约 523×），qualifier 11,103.87→6.57ms（约 1,690×），deep pagination 2,283.55→38.26ms（约 60×），empty recent page 54.16→1.57ms（约 34×）。
- 完整 `swift test`：DuoPasteSync 254 + DuoPasteCore 629 + DuoPasteCapture 11 = 894，0 failure；macOS Release、iOS Simulator Release、`git diff --check` 全绿。
- Developer ID bundle 最终重装后 launchd PID 34714；日用 DB `v16_search_fold_projection`、item 19,413 / fold 15,493 / dirty 0、`quick_check=ok`。

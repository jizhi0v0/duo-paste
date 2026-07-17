# R4.1 8GB / 百万行基准

状态：✅ 完成（2026-07-17）

## 范围

建立一个不会接触日用数据库、不会随普通 `swift test` 执行的可重复大库基准：100 万条 metadata、混合 kind/OCR、8 GiB 逻辑 blob 仓库。保存机器/工具链/数据集/指标和 gate 结果，先量出 fold、count、qualifier、分页与首屏的真实瓶颈，再决定是否优化生产搜索路径。

## 安全与可重复性

- benchmark 必须显式接收独立 `--workspace`；拒绝默认 Application Support 根目录及其父/子目录。
- workspace 带版本化 marker 与 dataset manifest；`--rebuild` 只允许删除拥有正确 marker 的目录。
- 数据由固定 schema version + seed 生成：100 万行包含 text/url/rtf/html/image/file、OCR done/pending、置顶、软删、多 origin 与少量跨 origin fold sibling。
- blob 默认创建 APFS sparse placeholder：逻辑大小精确 8 GiB，同时报告 allocated bytes，避免每次 nightly 真实写 8 GiB；`--materialize-blobs` 才物理写满。placeholder 只测 metadata/blob 目录规模，不供内容读取或 SHA 校验。
- bulk load 后重建生产 `item_fts` 并恢复 trigger，最终数据库继续通过 migration 与 `PRAGMA integrity_check`。

## 指标定义

每项先 warm-up，再记录逐次 wall-clock、p50/p95/max 与进程 peak physical footprint：

- `cold_fts`：每次新建 `Database`/SQLite connection 后执行中等选择性 FTS；不清 macOS page cache，报告里明确标记 `connection_cold_os_cache_uncontrolled`。
- `warm_fts`：复用同一 `SearchAPI` 的中等选择性 FTS page。
- `empty_query`：空 query 最近 200 条。
- `qualifier`：无文本、单一 kind qualifier 最近 200 条。
- `count_by_kind`：生产 `countByKind` + `countByFileSubKind` 路径。
- `deep_pagination`：空 query、offset 100,000、limit 200。
- `first_screen_data`：跟 `SearchProvider` 相同的单次 `searchSummary` 生产查询（R4.2 前基线为四段查询）。
- `first_screen_render`：从按键开始，包含生产 `SearchView.searchDebounceNanoseconds`、上述四段查询，并在 macOS 主线程把 outcome 写入真实 `AppState`，驱动真实 `SearchView` 的 `NSHostingView` layout；总耗时到 layout 完成。

初始硬 gate 只钉 roadmap 明确目标：Apple Silicon release build 的 `warm_fts.p95 < 100 ms`、`first_screen_render.p95 < 150 ms`。其它指标先存 baseline，不用宽松阈值制造“全绿”假象。若硬 gate 失败，优先改 fold oversample/count/分页；任何优化必须保持 list/total/chip fold 口径测试全绿。

## CLI / 报告

```sh
swift run -c release duo-pasted benchmark-library \
  --workspace .benchmark/r4-1 \
  --rows 1000000 --blob-gib 8 --samples 20 --rebuild
```

- 默认把 JSON 写到 `benchmarks/results/r4-1-<timestamp>.json`，同时 stdout 打紧凑表格；结果文件可由 `--output` 覆盖。
- `--reuse` 复用 manifest 完全匹配的数据集；不匹配直接拒绝，不能在半旧数据上跑。
- 小规模 smoke 使用同一入口，只覆盖 rows/blob bytes/samples；不会另维护一套测试实现。

## Schema / API / 回滚

- 生产 DB schema、wire API、同步协议不变。
- 新增纯 benchmark support 与 CLI 子命令；daemon 无参启动不走任何生成/测量代码。
- 回滚删除 benchmark support/CLI/结果文件即可；独立 workspace 可直接删除，不需迁移生产数据。

## 测试矩阵

- [x] 分位数使用 nearest-rank，空样本拒绝；p50/p95/max 与 gate 判定固定。
- [x] 固定 seed 的小数据集 kind/OCR/pin/delete/fold 分布、搜索 token 与 manifest 可重复。
- [x] sparse blob 的 logical/allocated bytes 分开报告，目录满足 BlobStore 两级内容寻址布局。
- [x] 默认 Application Support 与无 marker `--rebuild` 均被拒绝。
- [x] JSON report round-trip 保留 schema、环境、dataset、逐指标样本和 gate。
- [x] 普通 `swift test` 不再生成 10 万/100 万行；大库只由显式 CLI 触发。
- [x] 小规模 release smoke 通过并产出完整报告。
- [x] 100 万行 / 8 GiB 逻辑 blob release 基线完成，DB `integrity_check=ok`。
- [x] `warm_fts.p95 < 100 ms`、`first_screen_render.p95 < 150 ms`；若失败，优化后重跑。
- [x] 完整 `swift test`、macOS debug/release 与 iOS Simulator build 全绿。

## 完成条件

- [x] 上述测试矩阵逐项验证并打勾。
- [x] 基线 JSON 入库；文档写清 sparse/cold/render 的口径，不能把代理指标冒充真实指标。
- [x] 新的不变量移入 `CLAUDE.md`。
- [x] `docs/roadmap.md` 的 R4.1 标记完成并写入完成记录。

## 验证记录

- 红测先行：`LibraryBenchmark` 缺失时 6 组支持层契约按预期编译失败；core runner/UI CLI 未接线时 2 组 smoke/render 契约按预期失败，实现后 8/8 全绿。
- release 小规模 smoke：10,000 行、64MiB logical sparse blob、3 samples；warm FTS p95 0.26ms，search+layout p95 17.78ms，报告 schema/gate/路径全链路通过。随后口径审计发现探针未包含生产 180ms debounce，新增共用常量与 render-only 红测后改为本地搜索 60ms，正式 gate 重测包含该延迟。
- release 正式基线：Mac15,11 / Apple M3 Max / 36GiB，1,000,000 行、8GiB logical sparse blob、每指标 2 warm-up + 20 measured samples；DB 481MiB，`PRAGMA integrity_check=ok`，6 kind、50,000 OCR done + 50,000 pending、50,000 fold sibling 均与 manifest 一致。
- 正式 p95：connection-cold FTS 17.84ms、warm FTS 15.00ms、empty query 54.16ms、qualifier 11,103.87ms、count by kind 25,694.79ms、deep pagination 2,283.55ms、first-screen data 64.52ms、真实 keypress-to-first-screen（含 60ms production debounce）137.36ms。
- hard gates：warm FTS `<100ms` 与真实 first-screen render `<150ms` 均通过；未触发本切片的生产 SearchAPI 优化条件。线性 qualifier/count/offset 热点保留在 baseline，供后续独立、可回滚且保持 fold 口径的优化使用。
- 完整 `swift test`：DuoPasteSync 254 + DuoPasteCore 617 + DuoPasteCapture 11，合计 882，0 failure。
- `swift build`、`swift build -c release`、iOS Simulator Release、baseline JSON 20 样本完整性、SQLite integrity 与 `git diff --check` 全部通过。

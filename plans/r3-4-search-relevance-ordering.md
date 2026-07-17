# R3.4 搜索相关性排序

状态：✅ 完成（2026-07-17）

## 目标

让搜索结果符合用户心智：先展示从内容开头匹配的结果，再展示其余包含命中；每个相关性
分组内部按最新到最旧排列。置顶只影响空查询首页，不压过非空搜索的相关性。

## 排序契约

- 非空 query：`prefix_match DESC, captured_at_ns DESC`
  - `preview` 或 `text_full` 任一以完整 query 开始即属于 prefix group。
  - 其余 FTS 命中属于 contains group。
  - pin 不参与排序，prefix 不设年龄窗口，两个字段的 prefix 不再分 2/1 tier。
- 空 query：`pinned DESC, captured_at_ns DESC`。
- qualifier、pinned-only、time range、content fold 与 snippet 语义保持不变。

## 实现

- [x] 先把旧的 pinned-first、24h window、preview/text_full 分级行为改成失败测试。
- [x] 同步修改 `fetchHitsRaw` SQL、公开 `SearchAPI.fetch` 与 fold 后 Swift 排序。
- [x] fold 后对每条 item 只计算一次 prefix membership，避免 comparator 内 O(n log n)
  重复 lowercase。
- [x] 更新 `CLAUDE.md`、roadmap、Core/iOS dispatch 注释，移除现行文档中的旧契约。

## 验证

- [x] 8 项排序测试：prefix 胜 pinned contains、老 prefix 仍优先、contains 组时间倒序、
  prefix 组时间倒序、preview/text_full 同 tier、空查询 pin-first、fold 后一致、
  direct/folded API parity。
- [x] `swift test`：254 Sync + 626 Core + 11 Capture = 891/891。
- [x] `swift build -c release`。
- [x] iOS Simulator Release build。
- [x] 百万行 / 8GiB render-only benchmark：优化后两轮 p95 142.32ms、139.82ms，
  均通过 `<150ms` gate。
- [x] `git diff --check`。

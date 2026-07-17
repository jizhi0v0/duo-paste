# R3.1 自定义起止时间筛选

状态：✅ 完成（2026-07-17）

## 范围

在 macOS 搜索面板现有“全部时间 / 最近 24 小时 / 最近 7 天 / 最近 30 天”菜单中加入自定义日期范围。复用 `SearchQuery.fromNs/toNs`，不改 schema、同步协议或远端 API。

## 设计

- 在 `DuoPasteCore` 增加可单测的 `SearchTimeRange` / `SearchTimeBounds` 值模型。
- 预设窗口保持现有滚动时长语义；自定义范围按当前 `Calendar` 和时区解释。
- 自定义起点为较早选中日期的本地 00:00；终点为较晚选中日期的下一本地 00:00 减 1ns，SQL 继续使用现有的 inclusive `>= fromNs` / `<= toNs`。
- 搜索列表、真实总数、kind chip 和 file sub-kind chip 继续共用同一个 `SearchQuery`，因此必须同时透传 `fromNs/toNs`。
- UI 使用两个只选日期的 `DatePicker`；无效的倒序选择禁止应用，提供显式“清除”回到全部时间。

## Schema / API / 回滚

- Schema：无迁移。
- API：不增加网络接口；仅新增 Core 值模型并消费已有 `SearchQuery.fromNs/toNs`。
- 回滚：删除 Core 值模型与 DatePicker UI，恢复四个预设选项；数据库与同步数据无需回滚。

## 测试矩阵

- [x] 全部时间不产生边界；24h/7d/30d 保持滚动窗口语义。
- [x] 注入明确时区验证本地日界线，并覆盖 DST 的 23 小时日期。
- [x] 跨日范围包含起始日与结束日全部内容。
- [x] 清除筛选恢复无 `fromNs/toNs` 查询。
- [x] 边界内外混合数据下，列表、总数和 chip count 口径一致。
- [x] macOS DatePicker 可应用、可清除，当前范围标签清晰可见（UI source contract + release build）。
- [x] 定向测试、完整 `swift test`、debug/release build 全绿。

## 完成条件

- [x] 上述测试矩阵全部验证并打勾。
- [x] `docs/roadmap.md` 的 R3.1 标记为完成并写入完成记录。

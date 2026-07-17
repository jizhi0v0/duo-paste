# R3.2 保存搜索视图

状态：✅ 完成（2026-07-17）

## 范围

把 macOS 搜索面板当前的 query、slash qualifier、kind/file sub-kind、时间窗和 pinned-only 保存为本机命名视图，并从搜索面板或菜单栏快速应用。第一版不进入数据库、mesh `/since` 或 iOS。

## 持久化设计

- 使用 `~/Library/Application Support/duo-paste/saved-search-views.json`，顶层含 `version` 与 `views`。
- 独立于 `config.json`：SettingsModel 会长期持有 Config 快照；若保存视图也塞进 Config，之后应用一个旧 Settings 快照可能把新视图覆盖。独立文件从根上消除这条信息丢失路径。
- 文件 atomic write + 0600；缺文件等于空库；不支持的未来版本拒绝加载，避免旧 daemon 静默降级覆盖。
- 同名（忽略大小写）保存视为更新，保留稳定 ID；名称 trim、非空、最多 60 字符；最多 50 个视图。

## UI / 生命周期

- 搜索面板增加“保存的视图”菜单：应用、保存当前、删除。
- 保存弹层输入名称；应用时一次性恢复所有筛选维度并触发现有 `filterID` refresh。
- 菜单栏增加“保存的视图”子菜单，选择后先应用再打开搜索面板。
- AppState 为内存单一真相；成功写盘后才发布新数组并通知 StatusBarController，写盘失败不改变 UI 状态。

## Schema / API / 回滚

- DB/schema 与网络 API：无变化。
- 新本机文件 schema version = 1；Core 提供 Codable filter/view/library 与文件 store。
- 回滚：旧版本忽略独立文件；删除 UI/Store 即可，剪贴板数据不受影响。

## 测试矩阵

- [x] 所有 qualifier case、自定义时间窗与全部筛选字段 Codable round-trip。
- [x] 缺文件为空；保存/重开保持内容与顺序；文件权限为 0600。
- [x] 同名更新保留 ID，名称校验/50 项上限/删除行为稳定。
- [x] 不支持的未来 schema version 明确失败，不静默覆盖。
- [x] AppState 保存失败不发布内存变化；应用恢复所有筛选维度。
- [x] SearchView 暴露保存/应用/删除；菜单栏可按稳定 ID 快速打开。
- [x] 定向测试、完整 `swift test`、debug/release build 全绿。

## 完成条件

- [x] 上述测试矩阵全部验证并打勾。
- [x] 新的本机单一真相与原子发布不变量写入 `CLAUDE.md`。
- [x] `docs/roadmap.md` 的 R3.2 标记完成并写入完成记录。

# R2.1 iOS 本地 SQLite/FTS mirror

> [!IMPORTANT]
> 当前 backlog 与最终验收状态只以
> [`docs/roadmap.md`](../docs/roadmap.md) 为准。本文件只记录 R2.1 的测试先行实施过程；
> 全部验证通过后归档。

状态：已完成并归档（2026-07-17，含 v15 同步缺口真机复验）

完成记录：完整 841 tests、10 万条性能门、Mac release 与 iOS simulator 全绿，最终 server
已部署双 Mac。2026-07-17 最终 v15 client 覆盖安装到 iPhone 17 Pro，原 app container、历史
与配对数据均保留；SQLite `integrity_check=ok`，20,436 条 metadata/FTS 的 ID 集精确等于
mini ∪ MBP，双向缺失 0；相对两台 Mac 最新 revision 的旧版本数与用户可见关键字段不一致
数均为 0。当前 source ledger 19,350 条，精确等于 MBP `/since.total_count=19,350`。

## 不变量

- SQLite 保存完整元数据历史；SwiftUI 只加载有限的最近展示页，不能再用 1000 条 JSON
  上限当作同步边界。
- 每一页 `/since` 的 item 写入和 `(ingested_at_ns, id)` cursor 推进必须在同一个 writer
  transaction 内；前台 WS 唤醒 pull 与 BGAppRefreshTask 共用这一条写入路径。
- cursor 只允许按二元组单调前进。前后台重复拉同一页是幂等的，晚到的旧页不能让 cursor
  回退。
- source 若在 client cursor 之后补入更老 `ingested_at_ns` 的行，单靠 `> cursor` 无法发现；
  `/since.(source_device_id,total_count)` 必须与本地 `(source,id)` ledger 精确核对并在不等时
  触发 zero-cursor 非破坏 backfill，不能用多 peer union 总数代替，且持久化 cursor 不回退。
- iOS 本地搜索直接复用 `DuoPasteCore.SearchAPI`，包括 FTS5、跨 origin fold、qualifier OR
  和排序语义；mirror 可用后不再请求 Mac `/search`。
- 首次升级导入旧 `items.json` 后才删除旧文件。旧 `cursor.json` **不能迁移**：它可能对应
  已被 1000 条截断丢掉的历史，必须从 zero 全量重拉，防止永久缺口。
- blob 字节仍由现有 500MB `BlobCache` 管理，本项只迁移 metadata。

## 测试先行

- [x] 分页写入失败时 item/cursor 一起回滚；重复页幂等，旧 cursor 不回退。
- [x] 超过 1000 条的旧历史仍能在离线本地 FTS 中命中，重启后数据和 cursor 均保留。
- [x] 旧 JSON 只做 `INSERT OR IGNORE` 一次性导入，不覆盖新 SQLite 行，也不沿用旧 cursor。
- [x] 本地 mirror 与直接 `SearchAPI` 对同一 query/qualifier 的 fold 后 ID、pin 聚合一致。
- [x] 10 万条 metadata 的冷启动最近页加载与 FTS 搜索达到可交互门槛。
- [x] 迟到旧行先让普通增量 cursor 到顶，且本地 union 额外行掩盖 raw count 差异；per-source
  ledger 仍触发 zero-cursor backfill，缺行补齐且已有行不清空、cursor 不回退。

## 实现

- [x] Core 增加可测试的 `MetadataMirrorStore`：SQLite 生命周期、原子 page apply、单调 cursor、
  legacy import、最近页和本地搜索。
- [x] `HistoryStore` 启动时打开 mirror、迁移/校验/删除旧 JSON，并以有限最近页驱动 UI。
- [x] 前台 `PeerSyncCoordinator.runPull` 和 `BackgroundPullService` 统一调用 mirror page apply。
- [x] 前台与后台统一调用 Core `synchronize`；incremental 后按 per-source membership ledger
  与 server raw count 自动决定是否做非破坏 backfill。
- [x] HistoryView 的 debounce 改为本地 SQLite 搜索；删除远端 `/search` 调用与 contains
  fallback 依赖。
- [x] 乐观 bump/pin/delete 在本地搜索结果和后续 canonical page 回放期间不闪回。
- [x] README、CLAUDE 与 roadmap 状态同步，旧 JSON/cursor 契约不留陈旧说明。

## 验证

- [x] 定向 mirror tests 先红后绿；完整 Swift tests 全绿。
- [x] macOS debug/release 与 iOS simulator build 通过。
- [x] iPhone 17 Pro build/install/launch 通过，保留现有 app data。
- [x] iPhone 17 Pro 实库验证覆盖 mini ∪ MBP 全部 20,436 个 ID；缺失、旧 revision 与用户
  可见关键字段不一致均为 0，SQLite/FTS integrity 正常。
- [x] 最终 v15 client 覆盖安装后，真机 `mirror_source_item` 对当前 source 的 19,350 条
  membership 与 `/since.total_count=19,350` 精确一致。
- [x] 在断网/不可达 peer 条件下，本地 FTS 可查询完整已同步历史，且静态检查确认搜索不发
  `/search`。
- [x] roadmap R2.1 验收逐项勾选，本计划完成并归档。

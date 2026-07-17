# R2.2 iOS 首次同步进度与离线状态

> [!IMPORTANT]
> 当前 backlog 与最终验收状态只以
> [`docs/roadmap.md`](../docs/roadmap.md) 为准。本文件记录 R2.2 的测试先行实施过程；
> 全部验证通过后才归档并在 roadmap 打勾。

状态：已完成并归档（2026-07-17）

完成记录：完整 Swift tests 848/848、Mac release、iOS simulator 与 iPhone 17 Pro 签名
build/install/launch 全绿。真机保留原 app container，状态卡显示 20,449 条、当前 peer 覆盖
19,363/19,363 并“已严格追平”；Application Support checkpoint 的 local/source/server 数字
与 UI 一致。最终门额外修掉 PullWorker 测试固定 sleep 长尾，相关 36 项连续 10 轮 360/360。

## 不变量

- “本地有结果”和“已严格追平”是两个状态。首次同步、backfill、cache 重建、暂停或失败时，
  已落盘的局部结果可以搜索，但 UI 必须明确说明它不是全集。
- 每个 `/since` page 的 item、source ledger 与 cursor 仍在同一 SQLite writer transaction
  内提交；进度只在提交后发布。取消不能清库或回退 cursor，恢复必须从持久化 cursor 继续。
- 严格完成证明必须在 `has_more=false` 且 source count audit 通过后写入，并放在
  Application Support；mirror SQLite 留在可被系统清理的 Caches。证明存在但 mirror 缺失或
  落后时，启动状态必须是“正在重建”。
- 用户主动暂停同时约束前台自动 pull 与 BGAppRefreshTask，不能由 WS/route change 或后台任务
  偷偷恢复。用户点“继续同步”或“立即刷新”才清除暂停。

## 测试先行

- [x] Core progress callback 覆盖 incremental/backfill，并只报告 post-commit count/cursor。
- [x] 首次同步在第一页提交后取消，重开 store 后从该 cursor 恢复且最终严格追平。
- [x] completion checkpoint 可原子 round-trip；有 checkpoint 但 mirror 被清理/回退时分类为
  rebuilding，而不是 ready。
- [x] iOS source contract 覆盖状态卡、严格性、peer、最后成功、取消/恢复、立即刷新、后台
  checkpoint 与持久暂停。

## 实现

- [x] `MetadataMirrorStore.synchronize` 发布逐页 exact progress，区分 incremental/backfill。
- [x] `HistoryStore` 建模 initial/verifying/rebuilding/ready 与 idle/syncing/paused/failed，持久化
  strict checkpoint，并把网络/认证/count/cursor 错误翻译成可读文案。
- [x] `PeerSyncCoordinator` 提供取消、继续与立即刷新；generation token 阻止旧 route 的取消
  cleanup 覆盖新 pull 状态。
- [x] `HistoryView` 常驻展示本机条数、peer 覆盖、当前 peer、最后成功、严格追平状态与进度；
  重建/首次同步明确标注局部结果不是全集。
- [x] `BackgroundPullService` 遵守用户暂停，并在后台完整追平后更新同一 durable checkpoint。

## 验证

- [x] 定向测试先红后绿；完整 Swift tests 848/848 全绿。
- [x] macOS release build 与 iOS simulator build 通过。
- [x] iPhone 17 Pro 签名 build/install/launch；保留原 app container，并从真实 mirror 写出 strict
  checkpoint。
- [x] roadmap R2.2 验收逐项勾选，本计划完成并归档。

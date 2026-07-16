# R0.3 可验证的 snapshot / mesh 恢复流程

> [!CAUTION]
> **已归档；不可作为部署说明。** 现行部署见 [`README.md`](../README.md) 与
> [`docs/deploy-multi-mac.md`](../docs/deploy-multi-mac.md)；未来工作只看
> [`docs/roadmap.md`](../docs/roadmap.md)。

状态：✅ 完成（2026-07-16）

## 目标与安全边界

把“已有 snapshot 文件”变成可审计、可 dry-run、失败不破坏当前 DB 的恢复流程。

- 普通 `PullWorker` 的 own-origin active row guard 保持原样；只在一次性恢复器中显式允许
  从健康 peer 找回本机 origin 行。
- snapshot 和 peer 数据先写到独立 staging root。完整 `integrity_check`、migration、peer
  catch-up 与 blob 校验都成功后，才提交到 live 路径。
- live daemon 未 bootout 时拒绝真实 restore；`--dry-run` 只操作 staging，不替换 live DB。
- live DB 目录在提交前复制为 recovery safety backup；最终 DB 目录使用同卷原子 swap，
  提交后再次校验，失败立即 swap 回原目录。
- blob 是 content-addressed，只把 staging 中已校验的 sha 合并到 live BlobStore；DB 永远
  在 blob 合并成功之后才换入。

## CLI 与报告

- `snapshot-list`：列出 snapshot 的时间、大小、item/tombstone/blob 引用与完整性。
- `snapshot-verify [PATH|latest]`：只读跑 `PRAGMA integrity_check`，并报告 active item、
  tombstone、distinct active blob、缺失 blob。
- `snapshot-restore <PATH|latest> [--peer URL] [--expected-device-id ID] [--dry-run]`：
  准备候选库、跑 migration；可选从一个健康 peer 从 cursor zero 全量回填（包含 own-origin），
  拉取缺失 blob；输出恢复前、snapshot、peer refill 与最终统计。无 `--peer` 时只恢复 snapshot。

## 恢复算法

1. 只读验证 source snapshot；复制到 staging DB，再用现行 `Database` 跑 migration。
2. 如指定 peer：先 `/health` 校验 device ID，再从 `/since` cursor zero 拉到 `has_more=false`。
3. 对每行按 `(ingested_at_ns, id)` canonical cursor 比较：缺行插入、较新行覆盖、相同或
   较旧行跳过。此恢复器不跳过 `origin_device == self`，也不写正常 `pull_cursor`。
4. 活跃 image/file sha 优先复用 live BlobStore；缺失时从指定 peer 拉到 staging BlobStore，
   sha 校验失败或网络失败中止候选流程。
5. 再跑完整性与 item/tombstone/blob 统计。dry-run 到此清理 staging 并退出。
6. 真实提交前确认 daemon stopped，复制 live DB 目录到 safety backup；先合并 staging blob，
   再原子 swap staging/live DB 目录。换入后重开 `Database`（migration + integrity）验证。

## 回滚

- 提交前任一步失败：删除 staging，live DB 字节不变。
- 原子 swap 后验证失败：原子 swap 回旧 DB。
- 成功提交仍保留 `snapshots/recovery-safety-*/db`，需要人工回退时可把该目录换回。
- 不新增 schema；老客户端和 `Item` wire 不变。

## 测试矩阵

- [x] list/verify：健康、损坏、missing blob、latest/path 选择。
- [x] restore dry-run：跑 migration 和报告，但 live DB/hash 不变。
- [x] daemon-running guard 与 source/peer/integrity 失败都保留 live DB。
- [x] 临时目录端到端：损坏 live DB → snapshot staging → 真 HTTP peer 补 own-origin +
  tombstone + blob → 原子提交 → `Database` 重开。
- [x] 重复 peer refill / 重复完整恢复不产生重复行，item/tombstone/blob 数稳定。
- [x] 普通 PullWorker active own-origin guard 回归测试继续通过。
- [x] 全量 `swift test` 与 `swift build` 通过。

## 完成条件

- [x] roadmap R0.3 三条验收全部有自动化证据。
- [x] 恢复命令、原子提交与 DR-only own-origin 不变量写入 `CLAUDE.md`。
- [x] `docs/roadmap.md` 与本计划状态同步改为完成。

## 验证记录

- `swift test --filter SnapshotRecoveryTests`：3/3 通过，覆盖 list/verify、dry-run、daemon guard、损坏 DB 原子恢复与 safety copy。
- `swift test --filter DisasterRecoveryTests`：2/2 通过，覆盖真 HTTP own-origin/tombstone/blob 回填、重复幂等与 peer failure 原库不变。
- `swift test --filter ownActiveIncomingStillSkipped`：通过，普通 PullWorker active own-origin guard 未放宽。
- 灾后端到端主用例连续 10/10 通过；完整 `swift test` 三个 runner 共 248 + 548 + 9 条通过。
- `swift build` 与 `.build/debug/duo-pasted --help` CLI smoke 通过。

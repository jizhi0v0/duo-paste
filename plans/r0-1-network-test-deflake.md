# R0.1 网络集成测试去 flake

> [!CAUTION]
> **已归档；不可作为部署说明。** 现行部署见 [`README.md`](../README.md) 与
> [`docs/deploy-multi-mac.md`](../docs/deploy-multi-mac.md)；未来工作只看
> [`docs/roadmap.md`](../docs/roadmap.md)。

状态：✅ 完成（2026-07-16）。

## 范围

- `SyncServer` 支持 `port: 0` 并从 Hummingbird channel 回传真实监听端口。
- HTTP route 测试统一使用 `TestSyncServerFixture`：独立临时 DB/blob、真实 readiness、请求上下文、graceful shutdown。
- 删除测试里的随机/固定端口和用 sleep 猜 readiness 的逻辑。

## 验证

- [x] 定向运行 `DuoPasteSyncTests`。
- [x] `MeshSupervisorReconcileTests.reconcileURLChangeRebuildsAffectedPeerOnly` 50/50 全绿。
- [x] `swift test` 连续 20 次全绿。
- [x] `rg` 确认测试目录不再分配随机/固定监听端口或 readiness sleep。

## 回滚

只涉及测试 harness 与 `SyncServer.run` 的兼容扩展；生产调用仍可无参数 `run()`，可独立回滚。

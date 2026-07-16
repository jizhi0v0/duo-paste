# R0.2 跨 origin 置顶最终一致

> [!CAUTION]
> **已归档；不可作为部署说明。** 现行部署见 [`README.md`](../README.md) 与
> [`docs/deploy-multi-mac.md`](../docs/deploy-multi-mac.md)；未来工作只看
> [`docs/roadmap.md`](../docs/roadmap.md)。

状态：✅ 完成（2026-07-16）

## 问题与不变量

`item.origin_device` 仍是单一归属。非 owner 设备不能再把修改后的 mirror 整行当成
canonical 更新传播；pin/unpin 必须变成发给 owner 的绝对值命令。

- 命令携带稳定 `operation_id`，重试只返回第一次执行的 receipt，不再次翻转。
- owner 是唯一会为 pin 修改 `item.pinned` 并 bump `ingested_at_ns` 的设备。
- 非 owner 先做本地乐观显示，但把意图持久化；owner 不在线时 daemon 重启也不丢队列。
- 不用 wall-clock LWW；不做会吞掉 unpin 的 OR merge。
- 普通 `/since` wire 仍只传 `Item`，旧客户端可继续 decode。

## Schema（v13）

新增 `pin_operation`：每个 item 最多一条本机 active intent，记录 pending / awaiting replay、
owner 回执 cursor、attempt 和 last_error。新意图替换同 item 的旧意图，保证快速连续操作以
最后一次绝对值为准。

新增 `pin_operation_receipt`：owner 按 `operation_id` 记执行结果。相同 ID + 相同 payload
直接返回原 receipt；相同 ID + 不同 payload 拒绝，防 ID 被错误复用。

回滚：升级前由现有 snapshot 流程保留 pre-v13 DB；回退旧二进制前恢复该 snapshot。
两张新表不改变 `item` 列，导出和旧客户端读取不受影响。

## API 与执行链

继续使用 `POST /pin/:id?pinned=0|1`，增加可选 `operation_id`：

- 旧客户端不传：server 生成 UUID，仍可工作。
- 请求落在 owner：原子执行并返回 `state=applied`、`ingested_at_ns`；首次绝对值命令即使
  当前值相同也 bump 一次，确保 requester 一定能从 `/since` 观察到 canonical replay。
- 请求落在非 owner：本地乐观更新 + 持久化队列，返回 `202 state=pending`。
- PullWorker 已经绑定一个 peer；每次 health 成功后只投递 `origin_device == peer_device_id`
  的 pending operation。成功后进入 awaiting replay；收到匹配 receipt cursor 的 owner 行
  后才标 converged，避免中间旧整行覆盖乐观状态。

Mac 进程内 UI 和 iOS 都生成 operation ID。iOS 对多个已连接 Mac fan-out 同一个 ID；
非 owner 重复转发到 owner 时由 receipt 去重。

## UI

- Mac：active operation 对应卡片显示“等待同步”，本地 pin 状态立即更新；队列收敛后消失。
- iOS：server 返回 pending 时保留 pending 标记并用同一 operation ID 重试；任一路由返回
  applied 或后续 server 数据确认目标状态后清除。

## 测试矩阵

- [x] v13 fresh migration、已有 DB migration、operation/receipt 约束。
- [x] owner 首次执行、相同 ID 重试不二次 bump、ID/payload 冲突拒绝。
- [x] B mirror 乐观更新、离线保留 pending、恢复后 PullWorker 投递并等待 canonical replay。
- [x] A bump / OCR 更新 / daemon reopen 后 pinned 不丢。
- [x] A、B、iOS 模拟链路 pin 与 unpin 最终三端一致，快速反向操作以最后意图为准。
- [x] 旧 HTTP 调用（无 operation_id）仍成功，`Item` wire 无新增必填字段。
- [x] 全量 `swift test` 通过；关键 owner-routing 测试重复运行无 flake。

## 完成条件

- [x] roadmap R0.2 四条验收全部有自动化证据。
- [x] 新 owner/pending/receipt 不变量写入 `CLAUDE.md`。
- [x] `docs/roadmap.md` 状态和本计划状态同步改为完成。

## 验证记录

- `swift test --filter PinOperation`：Core operation + 真实 HTTP owner/mirror 收敛通过。
- `swift test --filter PinHTTP`：8/8 通过，覆盖旧调用、pending、receipt 与错误边界。
- owner-routing 收敛用例重复运行无失败；完整 `swift test` 三个 runner 共 246 + 544 + 9 条通过。
- iOS simulator `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`：`BUILD SUCCEEDED`。

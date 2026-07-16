# R1.1 按 app 排除捕获 + 临时暂停

> [!IMPORTANT]
> **完成后归档。** 本文件记录实现与验证证据；当前 backlog 以
> [`docs/roadmap.md`](../docs/roadmap.md) 为准。

状态：✅ 已完成并归档（2026-07-16）

## 不变量

- `capture.excluded_bundle_ids` 是 per-device 配置，匹配时在 watcher 读取正文/输出诊断前
  直接跳过；CaptureService 再做第二道守门，防未来调用方绕过 watcher。
- 暂停状态只存在于当前 daemon 进程：支持 5 分钟、30 分钟、直到手动恢复；定时暂停到期
  自动恢复，daemon 重启也恢复捕获，不能因 stale 持久化状态意外长期漏记。
- 跳过只影响 duo-paste：不清空、不改写 NSPasteboard，用户 Cmd+V 始终正常。
- 被排除/暂停的内容不写 item/blob，不触发 OCR wake 或 cursor broadcast，因此不会进入 mesh。
- Settings 修改排除列表热加载；capture 的字节上限等其他字段仍按既有规则提示重启。

## 测试先行

- [x] Config 默认/JSON round-trip 覆盖 `excluded_bundle_ids`。
- [x] CapturePolicy 覆盖 bundle ID trim/case、nil source、有限期暂停边界与手动暂停。
- [x] CaptureService 用临时 DB/blob 验证 excluded text/blob 与 paused capture 均为零写入。
- [x] 定向测试先红，完成实现后转绿。

## 实现

- [x] Core：CapturePause、CapturePolicy、Config schema 与 CaptureService 二次守门。
- [x] Watcher：在 pasteboard extract / 可疑正文日志之前调用动态 gate。
- [x] Runtime：AppState 管 pause timer、自动恢复与 excluded policy 热更新。
- [x] UI：菜单栏三种暂停 + 恢复、暂停图标/状态；搜索面板 persistent banner。
- [x] Settings：运行中 app 选择、bundle ID 手填、已排除列表删除与立即应用。
- [x] 文档：README/CLAUDE/roadmap 同步现行字段、行为与验证计数。

## 验证

- [x] 定向 Core/Capture 测试。
- [x] `swift build`、`swift test`、iOS simulator build、`git diff --check`。
- [x] roadmap R1.1 验收逐项打勾，本计划标为完成并归档。

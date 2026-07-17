# R3.3 纯文本粘贴动作

状态：✅ 完成（2026-07-17）

## 范围

为 macOS 搜索面板里的 text/rtf/html 项增加“粘贴为纯文本”右键动作和 `⇧⌘V` 快捷键。URL、图片、文件不暴露该动作；不改 schema、同步协议或 iOS。

## 设计

- `DuoPasteCore` 提供可单测的 kind eligibility 与纯文本解析路由；text 原样返回，rtf/html 必须由对应 decoder 成功转换，绝不把原始 markup 当纯文本兜底。
- AppKit 层用 `NSAttributedString` 解码 RTF/HTML；pasteboard 只写一个 `.string` representation，再沿用普通 `Cmd+V` 注入目标 app，避免依赖各目标 app 对 `⇧⌘V` 的不同解释。
- 右键菜单只在单张 text/rtf/html 卡片显示。快捷键使用 `⇧⌘V`；多选时只有全部选中项都符合资格才执行，并按选择顺序以换行拼接。
- 写回必须经过 `PasteboardWatcher.pasteBack` actor barrier，让 `isPasteBackInFlight` 和 `suppressUpToCurrent()` 覆盖自写 changeCount；写成功后按实际纯文本记录 `PasteSuppressionSet` 指纹，继续抑制 Universal Clipboard 跨设备 echo。
- 成功后复用现有 panel 同步隐藏、目标 app 激活、`PasteInjector.injectCmdV` 和 used-item bump；转换失败时保留 panel 并显示错误。

## Schema / API / 回滚

- DB/schema 与网络 API：无变化。
- Core 只新增纯函数 helper；macOS executable 新增回调与 paste 路径。
- 回滚删除 helper、菜单、快捷键与回调即可；历史数据和 pasteboard 内容不需迁移。

## 测试矩阵

- [x] text 原样输出；rtf/html 分别调用正确 decoder，转换失败不泄漏 raw markup。
- [x] url/image/file 全部不符合资格；混合多选全量拒绝，不静默跳过不支持项。
- [x] 纯文本多选保持选择顺序并以换行拼接。
- [x] SearchView 只为 text/rtf/html 显示“粘贴为纯文本”，并标注 `⇧⌘V`。
- [x] SearchPanelController 把 `⇧⌘V` 路由到独立回调，普通 `V`、图片/文件和无效混合多选不误触发。
- [x] AppDelegate 的纯文本写回经过 watcher pasteBack barrier，并按实际输出记录跨设备 echo 指纹。
- [x] pasteboard 只有 `.string` representation；成功后仍隐藏 panel、注入 `Cmd+V` 并 bump 全部使用项。
- [x] 定向测试、完整 `swift test`、debug/release build 全绿。

## 完成条件

- [x] 上述测试矩阵全部验证并打勾。
- [x] 新的不变量写入 `CLAUDE.md`。
- [x] `docs/roadmap.md` 的 R3.3 标记完成并写入完成记录。

## 验证记录

- 红测先行：缺少 `PlainTextPaste` 与 UI 接线时定向测试按预期失败；实现后 9 项 R3.3 Core/UI 契约全绿。
- 真实 named pasteboard 以 10ms watcher 轮询运行，`pasteBack` self-write 0 次 capture；AppKit RTF/HTML 实际解码 smoke 通过。
- 完整 `swift test`：DuoPasteSync 254 + DuoPasteCore 610 + DuoPasteCapture 11，合计 875，0 failure。
- `swift build`、`swift build -c release`、iOS Simulator release build 与 `git diff --check` 通过。
- Developer ID bundle 签名通过；LaunchAgent 从 PID 55782 切换到新 PID 3701 并稳定 running。

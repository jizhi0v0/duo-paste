# duo-paste

自托管的 Apple-only 剪贴板管理器。Mac 原生，本地 SQLite/FTS5 全文搜索，多 Mac 间走 Tailscale 同步。

## 为什么不用 Paste.app

替换 Paste 的几个明确痛点：

- 8GB 历史下搜索体验差，没有独立搜索窗，不支持按时间筛选
- **刚复制的内容不在最前面**——应用层排序 bug
- 偶发丢数据
- 数据被锁死，不支持导出

duo-paste 的回应：捕获**同步**落盘后才更新 UI、严格按 `captured_at_ns` 排序、FTS5 + 类型/时间索引、一键导出 JSON / Markdown / 原始 SQLite。

## 当前状态

- **M1 完成**：捕获 + SQLite/FTS5 + 内容寻址 blob + SwiftUI 搜索窗 + ⌥⌘V 全局快捷键 + 菜单栏 + LaunchAgent + 小时级 snapshot，主 Mac daily-driver 中
- **测试**：13/13 通过（`swift test`）
- **下一站 M2**：Mac mini 作 primary 跑 Hummingbird 2 ingest/search API，主 Mac / MBP 作 client 推送，走 Tailscale，单一归属避免冲突

详细架构计划见 [`plans/https-pasteapp-io-macos-ios-paste-moonlit-wave.md`](plans/https-pasteapp-io-macos-ios-paste-moonlit-wave.md)，开发坑和设计决策见 [`CLAUDE.md`](CLAUDE.md)。

## 核心特性（M1 已实现）

- NSPasteboard 200ms 轮询捕获，类型优先级 `file > image > rtf > html > url > string`
- concealed/transient 类型自动跳过（密码管理器约定）
- SQLite + FTS5（`unicode61 remove_diacritics 2`）全文搜索
- 内容寻址 blob 存储（SHA256 两级分桶）
- 全局快捷键 ⌥⌘V 唤出 NSPanel 风格搜索窗
- LaunchAgent 常驻、崩溃自动重启
- 每小时 `VACUUM INTO` snapshot
- 一键导出 JSON / Markdown / 原始 SQLite

## 安装与使用

```sh
git clone git@github.com:jizhi0v0/duo-paste.git
cd duo-paste
./scripts/install-agent.sh
```

脚本幂等：build release → 拷到 `~/Applications/duo-paste/` → 写 `~/Library/LaunchAgents/io.duopaste.agent.plist` → `launchctl bootstrap`。

日常使用：

| 按键 | 行为 |
|---|---|
| ⌥⌘V | 唤出搜索面板 |
| ↑ / ↓ | 在结果间移动 |
| Enter | 把选中项粘回到当前 app |
| Esc | 关闭面板 |

卸载：`./scripts/uninstall-agent.sh`（不动数据）。

## 架构概览

M1 是单机：所有数据走本地 SQLite + blob 目录，UI 直接读本地库。

M2 起拓扑变成 primary/client：

- **Mac mini** 永久在家，作 primary，聚合所有设备历史，跑 ingest/search API
- **主 Mac / MBP** 作 client，本地完整捕获，异步推送到 mini；离线时本地降级搜索
- **单一归属**：每条剪贴项归属捕获它的设备，primary 只是聚合，从根上消除同步冲突
- **传输**：Tailscale P2P 隧道 + shared-secret HMAC，不走公网

详细数据模型、API 草案、关键流程见 [`plans/https-pasteapp-io-macos-ios-paste-moonlit-wave.md`](plans/https-pasteapp-io-macos-ios-paste-moonlit-wave.md)。

## 路线图

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M1 | 单机捕获 + FTS5 + 搜索窗 + LaunchAgent + 导出 | done |
| M2 | Mac mini primary + Hummingbird 2 ingest/search API + Tailscale 推送 | next |
| M3 | MBP 离线韧性、push 重试、snapshot 保留策略 | planned |
| M4 | 导出 UI、类型/时间筛选、pinned、UX 打磨 | planned |
| M5 | iOS 只读客户端 | later |

明确 Non-Goals：双向同步、跨设备 blob 去重、iCloud 加密备份、富文本编辑。

## 项目结构

```
Sources/
  DuoPasteCore/        # 跨端共享核心
    Database.swift         # GRDB 接入 + migration
    Item.swift             # 剪贴项模型
    BlobStore.swift        # SHA256 两级分桶
    Search.swift           # FTS5 查询
    Snapshot.swift         # VACUUM INTO
    Export.swift           # JSON / Markdown / SQLite 导出
    CaptureService.swift   # 捕获写入流水
    CapturedPasteboard.swift
    Paths.swift            # ~/Library/Application Support/duo-paste 路径
    DeviceID.swift         # 本机稳定 UUID
    UUIDv7.swift           # 时间序主键
    Clock.swift
  DuoPasteCapture/     # macOS 剪贴板捕获
    PasteboardWatcher.swift
  duo-pasted/          # 可执行 target（daemon + UI）
    App.swift / AppDelegate.swift
    AppDependencies.swift / AppState.swift
    SearchPanelController.swift / SearchView.swift   # NSPanel + SwiftUI
    GlobalHotKey.swift                               # ⌥⌘V
    Copyback.swift                                   # 粘回 + 自写回环抑制
    SnapshotScheduler.swift
    StatusBarController.swift
scripts/install-agent.sh / uninstall-agent.sh
plans/                  # 架构计划
```

依赖：[GRDB.swift](https://github.com/groue/GRDB.swift) 7.10.0（SwiftPM 远程）。

## 开发

```sh
swift build              # debug
swift test               # 13 个测试
swift build -c release   # install 脚本会自动跑这个
```

改完代码 → `./scripts/install-agent.sh` 重装（脚本幂等）。注意 LaunchAgent 装着时**不要**直接 `swift run`——双进程会重复捕获、抢全局快捷键、SQLite WAL 多写者竞争；先 `launchctl bootout gui/$UID/io.duopaste.agent` 再跑 dev 二进制。

常见环境坑（GRDB.swift SwiftPM 弱网克隆断、Swift Testing 在 macOS 26 SDK 上的"假错"、NSPasteboard 自写回环防御、SwiftUI TextField 抢焦点导致箭头键不响应等）全部记录在 [`CLAUDE.md`](CLAUDE.md)，动核心模块前先看一眼。

## 关键路径

| 内容 | 路径 |
|---|---|
| 主 DB（含 FTS5） | `~/Library/Application Support/duo-paste/db/main.sqlite` |
| 内容寻址 blob | `~/Library/Application Support/duo-paste/blobs/<ab>/<cd>/<sha256>.<ext>` |
| 小时级 snapshot | `~/Library/Application Support/duo-paste/snapshots/duo-paste-YYYYMMDD-HHmmss.sqlite` |
| 本机稳定 UUID | `~/Library/Application Support/duo-paste/device-id` |
| Release 二进制 | `~/Applications/duo-paste/duo-pasted` |
| LaunchAgent plist | `~/Library/LaunchAgents/io.duopaste.agent.plist` |
| 日志 | `~/Library/Logs/duo-paste/duo-pasted.{out,err}.log` |

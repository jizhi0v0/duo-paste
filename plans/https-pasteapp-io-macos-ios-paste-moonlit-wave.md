# duo-paste：自托管多 Mac 剪贴板历史

## Context

替换 Paste.app。当前痛点：
- 8GB 数据下搜索体验差、没有独立搜索窗、不支持按时间检索
- **刚复制的内容没出现在最前面**（应用层排序 bug 或者索引延迟）
- 偶发丢数据
- 不支持导出，数据被锁死

目标：在自己的 Apple 设备之间做一个 Paste 替代品，**Mac 优先**，iOS 推后。隐私通过 Tailscale / Surge Ponte 等 P2P 隧道保障，不依赖公共云。

拓扑：
- **Mac mini**（家里，常开，不动）→ 作为权威 primary
- **主 Mac**（常开）→ 客户端，本地完整捕获，异步推送到 mini
- **MBP**（偶发离线）→ 客户端，离线时本地缓冲，重连后追推
- iOS → 后期再说，MVP 不实现

## Goals / Non-Goals

**Goals**
- 本地 FTS 搜索 + 时间范围筛选 + 类型筛选（文本/图片/文件/URL）
- 跨多 Mac 的统一搜索（在任意一台 Mac 上能搜到所有 Mac 的历史）
- "刚复制即最新"——捕获时间戳权威，UI 严格按它排序
- 一键导出 JSON / Markdown / 原始 SQLite
- 不丢数据：本地捕获即落盘 → WAL → 异步推送，任一环节崩溃不丢
- 不依赖公共服务器，只走 Tailscale

**Non-Goals (MVP)**
- iOS 客户端
- 端到端冲突解决（每条剪贴项归属单一设备，天然无冲突）
- 跨设备图片/blob 去重（仅做单机内 content-addressed 去重）
- 富文本编辑 / 收藏夹分类树等高级组织功能（先做基本 pin）
- iCloud 加密备份（用户明确不要）

## 架构总览

```
                    ┌─────────────────────────────┐
                    │   Mac mini  (Primary)       │
                    │   ┌─────────────────────┐   │
                    │   │ capture daemon      │   │
                    │   │ + ingest API        │   │
                    │   │ + search API        │   │
                    │   │ + SQLite/FTS5       │   │
                    │   │ + blob store        │   │
                    │   │ + snapshot worker   │   │
                    │   └─────────────────────┘   │
                    └────────────▲────────────────┘
                                 │  HTTPS over Tailscale
                  ┌──────────────┼──────────────┐
                  │              │              │
        ┌─────────┴────────┐     │     ┌────────┴─────────┐
        │  主 Mac (Client) │     │     │  MBP (Client)    │
        │  capture daemon  │     │     │  capture daemon  │
        │  + local SQLite  │     │     │  + local SQLite  │
        │  + outbox + push │     │     │  + outbox + push │
        │  + 搜索 UI       │     │     │  + 搜索 UI       │
        └──────────────────┘     │     └──────────────────┘
                                 │
                  (iOS 后期再接入；行为类似客户端但只读)
```

**核心原则**
1. 每条剪贴项**单一归属**——由捕获它的那台 Mac 拥有。Primary 只是聚合视图，不是真理唯一来源。这消除了所有同步冲突。
2. 每台 Mac 都有**本地完整副本**（仅自己的历史）。Primary 上额外有其他设备 ingest 进来的副本。
3. 搜索默认打 primary（看到全局）；primary 不可达时本地降级（看到本机历史）。
4. 推送是 **at-least-once**，靠主键去重幂等。

## 数据模型

主要表（primary 和各客户端 schema 一致，便于代码复用）：

```sql
-- 剪贴项元数据
CREATE TABLE item (
    id              TEXT PRIMARY KEY,        -- UUIDv7（含时间序）
    origin_device   TEXT NOT NULL,           -- 捕获设备 stable id
    captured_at_ns  INTEGER NOT NULL,        -- 捕获时刻纳秒（设备本地时钟，权威排序键）
    ingested_at_ns  INTEGER,                 -- primary 收到时刻（仅 primary 填）
    kind            TEXT NOT NULL,           -- text | rtf | html | image | file | url
    source_app      TEXT,                    -- bundle id, 如 com.apple.dt.Xcode
    source_app_name TEXT,
    preview         TEXT,                    -- 文本前 N 字符或图片 alt 描述
    text_full       TEXT,                    -- kind=text/rtf/html/url 时存全文
    blob_sha256     TEXT,                    -- kind=image/file 时存 blob 引用
    blob_size       INTEGER,
    blob_mime       TEXT,
    pinned          INTEGER NOT NULL DEFAULT 0,
    deleted_at_ns   INTEGER,                 -- 软删，便于撤销 + 同步
    -- 客户端独有：
    push_state      TEXT NOT NULL DEFAULT 'pending',  -- pending | acked | failed
    push_attempts   INTEGER NOT NULL DEFAULT 0,
    last_push_error TEXT
);

CREATE INDEX idx_item_captured ON item(captured_at_ns DESC) WHERE deleted_at_ns IS NULL;
CREATE INDEX idx_item_pinned ON item(pinned, captured_at_ns DESC) WHERE deleted_at_ns IS NULL;
CREATE INDEX idx_item_kind ON item(kind, captured_at_ns DESC);
CREATE INDEX idx_item_push ON item(push_state) WHERE push_state != 'acked';

-- 全文索引（外置内容表，避免冗余）
CREATE VIRTUAL TABLE item_fts USING fts5(
    text_full, preview, source_app_name,
    content='item', content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
);

-- 触发器维护 fts（insert/update/delete）
```

**Blob 存储**（content-addressed）：
```
~/Library/Application Support/duo-paste/blobs/
  ab/                            ← SHA256 前两字符分桶
    cd/                          ← 接下来两字符
      abcdef0123...png           ← 完整 hash + 原扩展名
  thumbs/                        ← 360px 缩略图（图片专用）
    ab/cd/abcdef0123...jpg
```

**主键策略**：UUIDv7 包含时间高位，跨设备插入到 primary 时也大致有序，对 B-tree 友好；同时全局唯一，免冲突。

## 关键流程

### 1) 本地捕获（所有 Mac）

```
NSPasteboard.changeCount 变化  (轮询 200ms)
  ↓
读取 types（按优先级：file > image > rtf > html > url > string）
  ↓
过滤：concealedType 标记的（密码工具）直接丢弃；与上一条同 hash 且 < 2s 的合并
  ↓
事务写入本地 SQLite（同步 commit）+ 写 blob 到 blob/ 目录
  ↓
push_state = pending，唤醒 push worker
  ↓
返回 UI 显示
```

落盘**同步**，UI 显示在落盘之后——这是"丢数据"的第一道防线。

### 2) 推送到 primary（客户端 → mini）

Push worker：
- 监听 `push_state='pending'` 队列
- 每条 POST `/ingest`，body 含 item 元数据；blob 用 multipart 或单独 `PUT /blob/{sha256}` 上传（已存在则跳过）
- Primary 返回 ack → 客户端置 `push_state='acked'`
- 网络错误 → 指数退避；超过阈值置 `failed`，UI 上能看到，用户可手动重试
- Primary 的 `/ingest` 用 `INSERT ... ON CONFLICT(id) DO UPDATE` 实现幂等

MBP 离线：消息堆积在本地 `pending`，**本地搜索和粘贴完全不受影响**；重连后自动补推。

### 3) 搜索（任意 Mac UI）

```
用户输入 query
  ↓
判断 primary 可达性（最近 5s 内健康探活成功）
  ├─ 可达 → GET /search?q=...&from=...&to=...&kind=...
  │            返回聚合结果（含其他 Mac 的历史）
  └─ 不可达 → 本地 SQLite FTS 查询（仅本机历史），UI 顶部显示 "primary 离线，仅本机结果"
```

排序：永远按 `captured_at_ns DESC`（pinned 项独占顶部分区）。**绝不**按 `ingested_at_ns` 排序——那会复现 Paste 的"老历史浮上来"bug。

### 4) Snapshot 备份（仅 primary）

- 默认每小时一次 `VACUUM INTO ~/Library/Application Support/duo-paste/snapshots/duo-paste-YYYYMMDD-HH.sqlite`
- 保留策略：最近 24 小时全保留，最近 30 天每天 1 份，更老每月 1 份
- Blob 目录靠 Time Machine 兜底（用户已表示够了）

### 5) 一键导出

UI 菜单 → 选格式 → 选时间范围/过滤 → 生成：

- **JSON**：`{ items: [...], blobs_dir: "./blobs" }`，blob 单独 sidecar；可选 `--inline-base64` 把图片塞进 JSON
- **Markdown**：每条一行（文本）或一节（带图片，图片相对路径引用），按日期分组
- **原始 SQLite**：WAL checkpoint 后直接拷 `.sqlite` + `blobs/` 目录

## 传输与认证

- 走 **Tailscale**（用户自有），primary 监听 `100.x.x.x:8443`
- 客户端通过 Tailscale MagicDNS 解析 `duo-paste-primary.tailXXXX.ts.net`
- TLS：用 `tailscale cert` 签发的证书；客户端固定信任这个证书
- 应用层认证：一个 32 字节 shared secret，写在每台设备的 keychain，每次请求带 HMAC 签名 header
  - Tailscale ACL 已经把可达性限制到了自己的 tailnet，shared secret 是纵深防御

## Tech stack

| 部件 | 选择 | 理由 |
|---|---|---|
| 语言 | Swift 6 | macOS 原生 API、SwiftUI、单一代码库 |
| UI | SwiftUI + AppKit 桥（NSPanel for spotlight 风格搜索窗） | SwiftUI 主流，搜索窗需要 AppKit 控制激活行为 |
| SQLite 封装 | GRDB.swift | 成熟、type-safe、内建 FTS5、observation API |
| HTTP server | Hummingbird 2 | Swift 原生轻量，足够 |
| HTTP client | URLSession + 自实现 backoff | 不引入第三方 |
| 启动 | LaunchAgent (`~/Library/LaunchAgents/io.duopaste.agent.plist`) | 用户态后台，崩溃自动重启 |
| 全局快捷键 | `HotKey` package 或 Carbon API 直接 | 调出搜索窗 |
| 图标 / 状态栏 | NSStatusBar | 标准菜单栏入口 |

**单一 binary 双模式**：同一 app 通过配置（`role: primary | client`）决定是否启动 ingest server。所有 Mac 都跑同一个 .app。

## 关键文件结构（实施时）

```
duo-paste/
  Package.swift
  Sources/
    DuoPasteCore/         # 跨端共享：DB、blob、model、search
      Database.swift
      Item.swift
      BlobStore.swift
      Search.swift
      Snapshot.swift
      Export.swift
    DuoPasteCapture/      # 剪贴板捕获（macOS 专属）
      PasteboardWatcher.swift
      Capture.swift
    DuoPasteSync/         # primary/client 通信
      Client.swift        # push worker + remote search
      Server.swift        # ingest + search API（primary only）
      Auth.swift          # HMAC
    DuoPasteApp/          # SwiftUI app target
      App.swift
      SearchWindow.swift
      MenuBar.swift
      Settings.swift
  Tests/
    ...
  plans/
    ...                   # 当前文件
```

## 阶段拆分

**M1：单机 MVP（不涉及多 Mac）**
- 在一台 Mac 上跑：捕获 → SQLite/FTS5 → 搜索窗 → 一键导出
- 验证：捕获完整性、搜索体验、排序正确性
- 关键交付：能彻底替换 Paste 的单机使用

**M2：Primary + Client 通信**
- 拆出 client/server 配置；Hummingbird server + push worker
- Tailscale 部署文档；shared secret 通过 keychain
- 验证：在 mini 上跑 primary，主 Mac 跑 client，搜索能看到双方历史

**M3：离线韧性 + Snapshot**
- MBP 接入；离线缓冲与降级搜索；hourly snapshot
- 验证：拔网线、kill 进程、重启，无数据丢失

**M4：导出 + UX 打磨**
- Markdown / JSON 导出 UI；类型/时间筛选；pinned；快捷键

**M5 (后期)：iOS**
- 只读 SwiftUI app；Tailscale on iOS；NWConnection over MagicDNS

## 用户原始痛点 ↔ 设计对应

| 痛点 | 设计中的对应 |
|---|---|
| 搜索不新鲜，刚复制的没在最前面 | 严格按 `captured_at_ns` 排序；捕获**同步**落盘后才更新 UI |
| 偶发丢数据 | 同步 WAL commit + push 是后台异步独立任务；hourly VACUUM INTO snapshot |
| 8GB 搜索慢 | FTS5 + 三个时间/类型/pinned 索引；blob 不进 FTS |
| 没有独立搜索窗 | 全局快捷键唤出 NSPanel 风格 spotlight 搜索 |
| 不支持时间筛选 | `from`/`to` 时间区间参数贯穿到 UI |
| 无法导出 | M4 一键导出 JSON/Markdown/原始 SQLite |
| 同步复杂 | 不做双向同步；单向 push + 单一归属，从根上消除冲突 |

## Verification

每个里程碑结束后端到端验证：

**M1 验证**
- 捕获 1000 条混合内容（文本 + 图片 + 文件路径），全部入库
- 关闭再开 app，历史完整存在
- 搜索几个关键词命中正确，新内容立即出现在第一行
- 一键导出 JSON / Markdown / SQLite，外部工具读取无误
- `kill -9` 进程后重启，数据完整（WAL 恢复）

**M2 验证**
- mini 跑 primary，主 Mac 跑 client；在两边各复制一些内容
- 在任一台 Mac 上搜索能看到双方的内容
- 关掉 mini 的 server 进程后，client UI 提示 primary 离线，本地搜索仍可用

**M3 验证**
- MBP 断网状态下捕获 100 条；恢复网络后全部出现在 primary
- 在捕获过程中 kill primary 进程，重启后无丢失，push worker 自动重试
- 模拟 primary 磁盘满，client 推送失败应有清晰错误反馈

**M4 验证**
- 8GB 级别 DB 上 FTS 查询 < 100ms
- 导出 30 天数据耗时可接受，文件可被 `jq` / 文本编辑器打开

## 未决问题（实施时再定）

- 全局快捷键默认值（候选：⌘⇧V，会与 macOS 原生 paste-history 冲突，需选别的，比如 ⌥⌘V）
- 主键究竟用 UUIDv7 还是 ULID（功能等价，看 Swift 生态哪个库稳定）
- Snapshot 在 mini 上的清理策略具体阈值
- Source app 信息怎么拿（NSPasteboard 不直接给 owner app，需要 `NSWorkspace.frontmostApplication` 在捕获瞬间快照）

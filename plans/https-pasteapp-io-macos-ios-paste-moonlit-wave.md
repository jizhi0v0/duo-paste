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
- **优雅退化到单机**：无 primary 配置即纯本地模式（= M1），M2+ 完全向后兼容
- **Mirror 模式（opt-in）**：client 可选周期 pull primary 到本地 `item_mirror`，换来 DR + 离线全集搜索 + 零停机 promote follower

**Non-Goals (MVP)**
- iOS 客户端
- 端到端冲突解决 / 双向同步（每条剪贴项归属单一设备，天然无冲突）
- 自动 leader election / 共识算法（Mac 数量个位数，promote 走手动子命令足够）
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
                    │   │ + /since (pull API) │   │
                    │   │ + SQLite/FTS5       │   │
                    │   │ + blob store        │   │
                    │   │ + snapshot worker   │   │
                    │   └─────────────────────┘   │
                    └────────────▲────────────────┘
                            push │ pull   HTTPS over Tailscale
                  ┌──────────────┼──────────────┐
                  │              │              │
        ┌─────────┴──────────┐   │   ┌──────────┴──────────┐
        │  主 Mac (Client)   │   │   │  MBP (Client)       │
        │  capture daemon    │   │   │  capture daemon     │
        │  + local SQLite    │   │   │  + local SQLite     │
        │  + outbox + push   │   │   │  + outbox + push    │
        │  + pull → mirror ✓ │   │   │  + pull → mirror ?  │
        │  + 搜索 UI         │   │   │  + 搜索 UI          │
        └────────────────────┘   │   └─────────────────────┘
                                 │
                  (iOS 后期再接入；行为类似客户端但只读)

  Mirror 是 opt-in：主 Mac 桌面盘大、常开 → 开 mirror 当热备；
                   MBP 磁盘紧 / 经常出门 → 可以不开
```

**写 / 读分离的心智模型（重要）**

不是纯 Kafka leader/follower——**写是分布式的，读才聚合**：
- 每台设备是自己 origin 条目的 master，本地 commit 后再异步推到 primary（primary 离线时捕获完全不受影响）
- Primary 的工作是**聚合 + 转发**，不是写入裁决；它不需要 Raft / 共识，因为没有"两台机器对同一条 item 争所有权"的情况——`origin_device` 列从数据模型层消除冲突
- Mirror client 是 **pull-based** follower（watermark cursor，client 自己控制进度），存在的唯一目的是 DR + 离线全集搜索

**核心原则**
1. 每条剪贴项**单一归属**——由捕获它的那台 Mac 拥有（`origin_device` 列）。Primary 只是聚合视图，不是真理唯一来源。这消除了所有同步冲突。
2. 每台 Mac 都有**本地完整 origin 副本**。Primary 额外持有其他设备 ingest 进来的副本。Mirror client 额外持有 primary 全量的影子拷贝（独立表 `item_mirror`，不混入 origin）。
3. 搜索默认打 primary（看到全局）；primary 不可达时本地降级（mirror 模式 → 全集；非 mirror → 仅本机 origin）。
4. 推送是 **at-least-once**，靠主键（UUIDv7）去重幂等。Pull 也是 **at-least-once + 幂等**。
5. **promote follower 是手动操作**，不做自动 failover。3 台个人 Mac 的规模下，`duo-pasted promote-to-primary` + 其他 client 改 `primary_url` 是可以接受的运维代价。

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

-- Mirror 模式专用：primary 拉过来的影子拷贝。
-- 与 item 分表，避免破坏"item 只装本机 origin"的语义；
-- promote-to-primary 时把它 INSERT OR IGNORE 进 item 即完成晋升。
CREATE TABLE item_mirror (
    -- 字段与 item 同（id / origin_device / captured_at_ns / ingested_at_ns /
    --  kind / source_app / source_app_name / preview / text_full /
    --  blob_sha256 / blob_size / blob_mime / pinned / deleted_at_ns）
    -- push_* 不需要：mirror 不参与推送
    -- 额外：
    mirrored_at_ns  INTEGER NOT NULL    -- 本机拉到的时刻，用于诊断
);

CREATE INDEX idx_mirror_captured ON item_mirror(captured_at_ns DESC) WHERE deleted_at_ns IS NULL;
-- mirror 也参与 FTS：用单独的 item_mirror_fts，搜索时 UNION ALL；
-- 不和 item_fts 合并，避免 trigger 复杂化
CREATE VIRTUAL TABLE item_mirror_fts USING fts5(...);

-- Pull watermark：记录本机拉到了 primary 的哪个 ingested_at_ns
CREATE TABLE pull_cursor (
    primary_id      TEXT PRIMARY KEY,   -- primary 的 device-id（换 primary 时 cursor 重置）
    cursor_ns       INTEGER NOT NULL,   -- 上次成功拉到的 ingested_at_ns
    updated_at_ns   INTEGER NOT NULL
);
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

### 3) Mirror 模式：pull 到本地（opt-in，仅 client）

Pull worker（在 `pull.enabled=true` 时启动）：
- 周期（默认 30s）GET `/since?cursor=<last_ingested_at_ns>&limit=500`
- Primary 返回按 `ingested_at_ns ASC` 排序的增量批次（含元数据，不含 blob）
- Client `INSERT OR IGNORE INTO item_mirror ...` 幂等合并，更新 `pull_cursor.cursor_ns`
- 软删、pinned 状态变化：primary 在 `/since` 里也回放（用同 id 的更新行覆盖即可）
- Blob 默认**按需懒拉**：搜索结果点开预览图片时才 `GET /blob/{sha256}` 拉到本地 blob 目录；可选 `pull.eager_blobs=true` 全量预拉（图片密集 + 桌面大盘适用）

Cursor 持久化：`pull_cursor` 表按 `primary_id` 主键。换 primary 时 cursor 自然重置（新 primary 的 device-id 没在表里 → 从 0 开始全量拉）。

### 4) 搜索（任意 Mac UI）

```
用户输入 query
  ↓
判断 primary 可达性（最近 5s 内健康探活成功）
  ├─ 可达 → GET /search?q=...&from=...&to=...&kind=...
  │            返回聚合结果（含其他 Mac 的历史）
  └─ 不可达
       ├─ mirror 已启用 → 本地 FTS over (item UNION ALL item_mirror)，
       │                  顶部 banner "primary 离线，使用本地镜像 (cursor: 14m ago)"
       └─ 无 mirror     → 本地 FTS over item，
                          顶部 banner "primary 离线，仅本机捕获结果"
```

排序：永远按 `captured_at_ns DESC`（pinned 项独占顶部分区）。**绝不**按 `ingested_at_ns` 排序——那会复现 Paste 的"老历史浮上来"bug。

### 5) Snapshot 备份（仅 primary）

- 默认每小时一次 `VACUUM INTO ~/Library/Application Support/duo-paste/snapshots/duo-paste-YYYYMMDD-HH.sqlite`
- 保留策略：最近 24 小时全保留，最近 30 天每天 1 份，更老每月 1 份
- Blob 目录靠 Time Machine 兜底（用户已表示够了）

### 6) 一键导出

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

## 配置与 role

`~/Library/Application Support/duo-paste/config.json`（不存在 → 全部走默认 = 单机 M1 行为）：

```json
{
  "serve": false,                   // true → 启动 Hummingbird ingest/search/since server
  "primary_url": null,              // 非空 → 启动 push worker 推到这里
  "pull": {                         // 仅在 primary_url 非空时有意义
    "enabled": false,               // true → 启动 pull worker，把 primary 全量同步到 item_mirror
    "interval_sec": 30,
    "eager_blobs": false            // true → blob 也预拉（默认懒拉）
  },
  "shared_secret_keychain_account": "io.duopaste.shared-secret"
}
```

四种典型组合：

| 场景 | `serve` | `primary_url` | `pull.enabled` |
|---|---|---|---|
| 单机（M1 兼容） | false | null | false |
| 纯 primary（mini） | true | null | false |
| 纯 client（MBP，节磁盘） | false | mini 地址 | false |
| Mirror client（主 Mac，热备） | false | mini 地址 | **true** |

不存在"primary 也 pull"的合法组合——primary 是聚合源头，不需要从别的地方 pull。

## Primary 生命周期

### a) 加新设备

```sh
# 在新机器上
cp -i ~/path/to/config.json ~/Library/Application\ Support/duo-paste/config.json
# 编辑 primary_url；shared secret 通过 security add-generic-password 写 keychain
./scripts/install-agent.sh
```

新设备启动后 push worker 把自己的本地历史（origin = 自己）增量推到 primary。如果开了 mirror，pull worker 也开始同步 primary 全量到本地。

### b) 计划内换 primary（mini → 新机器）

`duo-pasted migrate-primary` 子命令封装：

1. 停老 primary（`launchctl bootout ...`）
2. 老 primary `VACUUM INTO` 出一份 snapshot
3. rsync DB + blobs 到新机器
4. 新机器 config `serve=true`，启动
5. 输出 "请到其他 client 改 `primary_url` 重启"（暂不自动远程改配置，避免静默变更）

### c) Primary 永久下线 + promote follower

前提：至少有一台 mirror client（否则只能接受丢失 primary 的 origin 历史）。

```sh
# 在 mirror client 上
duo-pasted promote-to-primary
```

子命令做的事：

1. 锁 DB
2. `INSERT OR IGNORE INTO item SELECT ... FROM item_mirror`——把 mirror 提升进 item（保留 origin_device，**不**改成本机；这些条目仍归属原捕获设备，只是现在由新 primary 持有）
3. 删 `item_mirror`、删 `pull_cursor`
4. 改 config：`serve=true`、`primary_url=null`、`pull.enabled=false`
5. 重启 daemon

然后**手动**到其他 client 改 `primary_url` 指向新 primary。其他 client 启动时跑：

### d) Audit push（其他 client 在 primary 变更后跑一次）

`duo-pasted audit-push` 子命令：

1. 拿本地所有 `origin_device == self && deleted_at_ns IS NULL` 的 id 列表
2. POST `/audit` 给新 primary：`{"ids": [...]}`，primary 返回它没有的 id 子集
3. 对返回的 id 把 `push_state` 改回 `pending`，唤醒 push worker

这一步补"老 primary 已 ack 但 mirror 还没拉到就炸了"的洞。3 台机器一台正常 mirror 时这洞最多就几十秒数据；audit 几乎是空操作但兜底有意义。

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
      Server.swift        # /ingest /search /since /blob /health（serve=true 启动）
      PushWorker.swift    # push pending → primary（primary_url 非空启动）
      PullWorker.swift    # pull primary → item_mirror（pull.enabled 启动）
      Promote.swift       # promote-to-primary / migrate-primary / audit-push 子命令
      RemoteSearch.swift  # 客户端打 primary /search 的封装 + 健康探活
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

**M1：单机 MVP（不涉及多 Mac）** ✅ 已完成
- 在一台 Mac 上跑：捕获 → SQLite/FTS5 → 搜索窗 → 小时级 snapshot
- LaunchAgent daily-driver 已上线

**M2：Primary + Client 单向 push** ✅ 已上线生产
- v1_initial 已含 `origin_device / ingested_at_ns / push_state / push_attempts / last_push_error`——M1 schema 当初就前瞻式建好，**没需要 ALTER**
- v2_mirror migration：预建 `item_mirror / item_mirror_fts / pull_cursor`（M3 才用，提前建避免二次 migration）
- `config.json`：`serve` / `serve_host` / `serve_port` / `primary_url` / `pull.*` / `shared_secret_keychain_account`
- shared-secret 文件（64 hex chars，0600）；keychain 留给 M3 再迁
- HMAC-SHA256：`ts || METHOD || path || sha256(body)`；±5min 反 replay；header 携 body hash，middleware 不读 body（省内存），handler 二次校验
- Hummingbird 2 server：`/health` `/ingest`（INSERT OR IGNORE 幂等）`/blob` (HEAD/GET/PUT，path/header/body sha 三方一致校验) `/search`（复用 SearchAPI.fetch）
- Client push worker（actor，串行 tick）：blob 先上传后 ingest；4xx 立即 failed / 5xx+网络计数重试 / 超 maxAttempts (50) 放弃；`wake()` 取消当前 sleep task 缩短延迟
- SearchProvider：有 remote → 试远端 → 失败回退本地 + `searchMode` 标 `.remoteFallback(reason)`；UI banner 显示 reason
- CLI 子命令：`duo-pasted init-secret [--force]` / `retry-failed` / `--help`（SwiftUI App.init 拦截 + exit）
- 集成测试：同进程 server + worker 真 HTTP 全链路（push、search、blob 都覆盖）
- 测试 66/66 通过；live daemon curl 验证 `/health` `/ingest` `/blob HEAD-PUT-GET` `/search` 全通
- FTS5 snippet 高亮 + UI 加粗（单次 SQL 同时拿 item+snippet，maxTokens=8 紧贴匹配词）
- SearchView debounce 100ms + 进程级 URLSession（push/search 共享 TLS 连接池）
- TLS 已实装：mini 上 `tailscale cert` 签发，URLSession 默认信任（macOS 根证书链）
- **生产部署**：mini = `bobbys-mac-mini.tail69730a.ts.net:8443` (primary HTTPS)；MBP `100.68.44.27` = client
- **已知 M2 局限**：client 搜索每次过 Tailscale 一跳，连打 debounce 后单次仍 ~120ms。M3 mirror 模式才能彻底本地化。

**M3：Mirror 模式 + 离线韧性 + DR** ⏳ 下一站
- 第一刀（最小 mirror MVP）：
  - Primary 加 `GET /since?cursor=<ingested_at_ns>&limit=N` 增量 API，按 ingested_at_ns ASC 返回；空 cursor 时全量拉
  - Client `PullWorker` actor，周期（默认 30s）打 `/since`，`INSERT OR IGNORE INTO item_mirror`，更新 `pull_cursor.cursor_ns`
  - `SearchAPI.searchHits` 改：mirror 启用时 UNION ALL 查 `item` + `item_mirror`，按 id 去重（origin 自己的优先）
  - `pull.enabled=true` 时 AppDelegate 启 PullWorker，SearchProvider 知道 mirror 在 → 优先打本地（不再每次 keystroke 过网络）
  - UI banner: 区分 "mirror @ cursor 14m ago" / "primary 离线" / "本机 only"
- 第二刀（运维 + DR）：
  - `duo-pasted promote-to-primary` —— mirror 表提升为 item 表 + 改 config + 重启；**record primary tenure/lineage**（device_id + from_ns + to_ns 序列）写到独立表，供 audit-push 后续做精确 Continuity-dedup 候选过滤（当前 audit 只用 `origin != self` 启发式，多 primary lineage 下会偏宽松）
  - `duo-pasted audit-push` —— 扫本地 origin 项，问新 primary 缺哪些再 re-push
  - `duo-pasted migrate-primary` —— rsync DB + blobs 到新 primary 的脚手架
- 第三刀（优化）：
  - Blob 懒拉（mirror 默认不预拉 blob，搜索结果点开图片时按需 GET）；`pull.eager_blobs=true` 走全量预拉
  - 时钟偏移 sanity check（启动时与 primary 时钟差 > 30s → banner 警告）
- 验证：
  - MBP 开 mirror → 搜索时延 < 50ms（纯本地 FTS）
  - MBP 拔网线 → 搜索仍能看到 mirror 全集（cursor 时刻为准）
  - 模拟 mini 永久下线 → MBP promote 成功，secondary client 切过去 + audit-push 补齐
  - MBP 断网捕获 100 条 → 重连全部到达新 primary

**M4：导出 + UX 打磨**
- Markdown / JSON 导出 UI；类型/时间筛选；pinned；快捷键自定义

**M5 (后期)：iOS**
- 只读 SwiftUI app；Tailscale on iOS；NWConnection over MagicDNS

## 用户原始痛点 ↔ 设计对应

| 痛点 | 设计中的对应 |
|---|---|
| 搜索不新鲜，刚复制的没在最前面 | 严格按 `captured_at_ns` 排序；捕获**同步**落盘后才更新 UI |
| 偶发丢数据 | 同步 WAL commit + push 是后台异步独立任务；hourly VACUUM INTO snapshot；mirror 模式作为热备 |
| 8GB 搜索慢 | FTS5 + 三个时间/类型/pinned 索引；blob 不进 FTS |
| 没有独立搜索窗 | 全局快捷键唤出 NSPanel 风格 spotlight 搜索 |
| 不支持时间筛选 | `from`/`to` 时间区间参数贯穿到 UI |
| 无法导出 | M4 一键导出 JSON/Markdown/原始 SQLite |
| 同步复杂 | 不做双向同步；单向 push（写）+ pull mirror（读 DR）+ 单一归属，从根上消除冲突 |
| Primary 坏了怎么办 | Mirror client 跑 `promote-to-primary` 顶上；其他 client 改 `primary_url` + `audit-push` 补齐 |

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
- 主 Mac 开 mirror，停 mini server 后主 Mac 搜索能命中 mini 历史
- 模拟 mini 永久下线（rm DB） → 在主 Mac 上 `duo-pasted promote-to-primary` → MBP 改配置 + `audit-push` → 三方一致
- 跨设备时钟偏移检测：启动时若与已知 peer 偏移 > 30s 在 UI banner 警告

**M4 验证**
- 8GB 级别 DB 上 FTS 查询 < 100ms
- 导出 30 天数据耗时可接受，文件可被 `jq` / 文本编辑器打开

## 未决问题（实施时再定）

- 全局快捷键默认值（候选：⌘⇧V，会与 macOS 原生 paste-history 冲突，需选别的，比如 ⌥⌘V）✅ 已定为 ⌥⌘V
- 主键究竟用 UUIDv7 还是 ULID（功能等价，看 Swift 生态哪个库稳定）
- Snapshot 在 mini 上的清理策略具体阈值
- Source app 信息怎么拿（NSPasteboard 不直接给 owner app，需要 `NSWorkspace.frontmostApplication` 在捕获瞬间快照）✅ M1 已用 frontmostApplication 实现
- Pull worker 拉到的 blob 何时清理（client 磁盘紧时 LRU？还是永不清理？M3 设计时定）
- Mirror client 是否参与 `/search` 服务（即一台 mirror client 也可以接受其他 client 的搜索请求作为只读副本，进一步去单点）——暂列入 M3+ 拓展，MVP 不做

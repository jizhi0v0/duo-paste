# Mesh + WebSocket 重构

## Context

当前 primary/client 架构（mini = primary，MBP = client）在 daily-driver 长期使用中暴露**多设备搜索结果和总数不一致**的心智负担问题。代码层面盘清四个根因，全部跟"中心化 primary + 异步 push/pull 双管道"模型相关：

1. **Push 待 ACK 窗口**：client 本机搜得到 `push_state=pending` 的行，primary 尚未 ingest，其他 client 拉不到（`PushWorker.swift:221`、`RemoteIngester.swift:50-88`）
2. **Pull cursor 卡住**：`PullWorker.lastPullNs` 在 transient 失败时不更新（`PullWorker.swift:141-143`），mirror 数据比 primary 陈旧但 `SearchProvider` 仍判定 mesh 可信走 `searchUnion` 跳过远端（`SearchClient.swift:194-198`）
3. **Continuity dedup 只覆盖 origin=self**：两台设备各自独立 capture 同文本时（Universal Clipboard / ToDesk 同步），primary 的 `findNearbyOwnContent` 只查 origin=self 挡不住跨 peer 重复（`RemoteIngester.swift:69-80`）
4. **Pin 状态分歧**：RemoteIngester 幂等"已存在不更新"契约 + `searchUnion` id-dedup 按 capturedAtNs 选 winner，让 pin 在两端看到不一样（`Search.swift:116-124`）

**目标**：换成 mesh + WebSocket 拓扑，从根上消除根因 1/2，把根因 3/4 收口在更窄的 fold 兜底层。所有设备平等（每台都是 peer），数据通道走 pull（cursor 是单一真相源），WebSocket 单向通知"我有新内容了"实现 < 1s 同步延迟；WS 断了自然退化为 30s 周期 pull，**业务正确性完全靠 cursor 保证**。

## 设计决策摘要（用户已确认）

| 题 | 决策 | 理由 |
|---|---|---|
| 拓扑 | Full mesh, pull-only + WebSocket 通知 | M3 第二刀的 PullWorker 已经实现完了 pull 模型，只需扩成 N 个 peer；WS 是性能优化层，不增加状态机复杂度 |
| 兼容性 | 全切，删 primary 概念 | 2 台 Mac、daily-driver 稳定，回退价值低；代码净减约 30%，不变量少一半 |
| Schema | 合表（item_mirror → item） | 不一致的根源之一是 searchUnion 的跨表 dedup 逻辑；合表后只剩单路径 fetchHits |
| 迁移 | 新 CLI 子命令 `mesh-init` | 跟现有 promote-to-primary 同形态（用户熟悉），daemon 必须停 + 预先打 snapshot 兜底 |

## 文件级改动清单

### 新增

- `Sources/DuoPasteSync/WSProtocol.swift` — `WSMessage` enum 单点定义（cursorAdvanced / hello / ping / pong），Server / Client 共用
- `Sources/DuoPasteSync/WSBroadcaster.swift` — actor，server 侧活动 WS 连接集合 + `broadcast(.cursorAdvanced)` API；慢消费者 2s 超时即踢，不阻塞 capture 路径
- `Sources/DuoPasteSync/WSNotificationClient.swift` — actor，per peer 一个；维护到 peer `/sync/ws` 长连接 + 重连退避 + 心跳；收到通知 → 对应 PullWorker `wake()`
- `Sources/DuoPasteSync/MeshSupervisor.swift` — AppDelegate 启动入口的薄封装：起 N-1 个 PullWorker + N-1 个 WSNotificationClient + WSBroadcaster；统一 stop
- `Sources/DuoPasteCore/MeshStatus.swift` — 取代 `MirrorStatus`，per peer 状态 map (lastPullNs / lastWSConnectedNs / clockSkewMs / consecutiveFailures)；SearchProvider 拿 `oldestLastPullNs` 算 staleness
- `Sources/DuoPasteCore/MeshInit.swift` — `Admin.meshInit(...)` 纯函数实现 + CLI wrapper

### 修改

- `Package.swift` — 加 `hummingbird-websocket` 依赖（产品 `HummingbirdWebSocket` / `HummingbirdWSClient`，版本约束 `from: "2.0.0"` 跟 hummingbird 主线对齐）
- `Sources/DuoPasteCore/Config.swift` — 删 `primaryURL` / `PullConfig`，新增 `peers: [PeerConfig]` + `mesh: MeshConfig`；`derivedDatabaseRole` 删；`Config.write` 加 `peers` 数组 replace + `mesh` 段 nested merge + 显式 removeValue 老字段 (`primary_url` / `pull`)；`validate()` 重写约束（详 schema 段）
- `Sources/DuoPasteCore/Database.swift` — 加 v7 migration（详下）；删 `DatabaseRole` enum；`Database.init` 删 role 参数
- `Sources/DuoPasteCore/Item.swift` — 删 `PushState` enum + `pushState` / `pushAttempts` / `lastPushError` 字段 + CodingKeys
- `Sources/DuoPasteCore/CaptureService.swift` — **关键改动**（详下）：删 `role` 分支永远走 stamp 路径；**mergeCandidate 查询加 `origin_device == selfDeviceID` 过滤**；tx 提交后回调 `onCursorAdvanced(ingestNs)` 闭包让外部触发 WS 广播
- `Sources/DuoPasteCore/Search.swift` — 删 `fetchHitsMirror` / `fetchUnion` / `countUnion` / `countByKindUnion` / `countMirror`；`fetchHits` 内置 text-fold（同 fetchUnion 的 fold 逻辑，但只查单表，无 id-dedup）
- `Sources/DuoPasteCore/Admin.swift` — 删 `promoteToPrimary` / `migratePrimary` / `retryFailed` + 对应 errors；保留 `initSecret` / `retryFailedOCR`
- `Sources/DuoPasteSync/Server.swift` — 删 `/ingest` route + `RemoteIngester` 注入；新增 `/sync/ws` upgrade route（HMAC auth 复用 `HMACAuthMiddleware`，签 `GET\n/sync/ws\n<emptyHash>`）；注入 `WSBroadcaster`
- `Sources/DuoPasteSync/PullWorker.swift` — actor 构造接 `peerDeviceID` + `peerBaseURL`；`primary_id` → `peer_device_id`；`reconcilePrimary` → `reconcilePeer`；**applyPage INSERT 目标从 `item_mirror` 改 `item`**（`origin == selfDeviceID` 用 `INSERT OR IGNORE` 兜底，否则 `INSERT OR REPLACE`）；`crossDeviceDedupWindowNs` 逻辑保留；`MirrorStatus` 接口改 `MeshStatus.peer(peerDeviceID)`
- `Sources/DuoPasteSync/SinceClient.swift` — `HTTPIngestClient` 改名 `HTTPPeerClient`；`fetchPrimaryHealth` → `fetchPeerHealth`；新增 `connectWS(peerDeviceID:)` 返回 `WSConnection`
- `Sources/DuoPasteSync/SearchClient.swift` — `SearchProvider.Mode` 简化为 `.local` / `.mesh(stalenessSec:)`；删 `remoteOK` / `remoteFallback` / `localMirror` / `SearchTransport`；删 `remote` 注入参数
- `Sources/DuoPasteSync/PushClient.swift` — 改名 `BlobClient.swift`；删 `ingest` / `putBlob` 方法 + `IngestRequest` / `IngestResponse`；保留 `getBlob` 给 lazy paste-back
- `Sources/duo-pasted/AppDelegate.swift` — 删 PushWorker / 单 PullWorker 启动入口；用 `MeshSupervisor` 替换；`pasteBlobFetcher` 改成在 peers 之间按顺序探 GET `/blob/<sha>`；`startSyncServer` 注入 `WSBroadcaster`
- `Sources/duo-pasted/AppDependencies.swift` — `MirrorStatus` → `MeshStatus`；删 `searchProvider.remote` 参数；注入 `WSBroadcaster`（单例）
- `Sources/duo-pasted/CLI.swift` — 删 `promote-to-primary` / `migrate-primary` / `audit-push` / `retry-failed`；新增 `mesh-init`

### 删除

- `Sources/DuoPasteSync/PushWorker.swift`
- `Sources/DuoPasteSync/RemoteIngester.swift`
- `Sources/DuoPasteSync/IngestRequest.swift`
- `Sources/DuoPasteSync/AuditPush.swift`
- `Sources/DuoPasteCore/MirrorStatus.swift`（由 `MeshStatus.swift` 取代）
- 对应测试文件：`PushWorkerTests.swift` / `IngestTests.swift` / `AuditPushTests.swift` / `AdminPromoteTests.swift` / `AdminMigrateTests.swift` / `SearchUnionTests.swift`

## Schema migration v7

GRDB DatabaseMigrator 单 tx 包整段。`Database.runMigrations` 内 `m.registerMigration("v7_mesh_consolidation")`：

```sql
-- step 1: 合表 item_mirror -> item（mirror 行 push_state 强制 'acked'）
INSERT OR IGNORE INTO item (
    id, origin_device, captured_at_ns, ingested_at_ns, kind,
    source_app, source_app_name, preview, text_full,
    blob_sha256, blob_size, blob_mime,
    pinned, deleted_at_ns,
    push_state, push_attempts, last_push_error,
    ocr_state
)
SELECT
    id, origin_device, captured_at_ns, ingested_at_ns, kind,
    source_app, source_app_name, preview, text_full,
    blob_sha256, blob_size, blob_mime,
    pinned, deleted_at_ns,
    'acked', 0, NULL,
    ocr_state
FROM item_mirror;

-- step 2: 兜底 stamp ingested_at_ns IS NULL（合表后引入 + 旧 client 遗留）
--   Swift 端逐行 nextIngestNs 保单调递增（不能纯 SQL 一次性 UPDATE）
--   见 Database.nextIngestNs 不变量

-- step 3: drop mirror 相关
DROP TRIGGER IF EXISTS item_mirror_au;
DROP TRIGGER IF EXISTS item_mirror_ad;
DROP TRIGGER IF EXISTS item_mirror_ai;
DROP TABLE IF EXISTS item_mirror_fts;
DROP INDEX IF EXISTS idx_mirror_blob_sha;
DROP INDEX IF EXISTS idx_mirror_kind_captured;
DROP INDEX IF EXISTS idx_mirror_captured;
DROP TABLE IF EXISTS item_mirror;

-- step 4: pull_cursor PK 重建（primary_id -> peer_device_id）
CREATE TABLE pull_cursor_v7 (
    peer_device_id  TEXT PRIMARY KEY,
    cursor_ns       INTEGER NOT NULL,
    cursor_id       TEXT NOT NULL DEFAULT '',
    updated_at_ns   INTEGER NOT NULL
) STRICT;
INSERT INTO pull_cursor_v7 (peer_device_id, cursor_ns, cursor_id, updated_at_ns)
SELECT primary_id, cursor_ns, cursor_id, updated_at_ns FROM pull_cursor;
DROP TABLE pull_cursor;
ALTER TABLE pull_cursor_v7 RENAME TO pull_cursor;

-- step 5: drop primary_lineage（mesh 拓扑下无任期概念）
DROP TABLE IF EXISTS primary_lineage;

-- step 6: drop push_* 列 + 关联 index（SQLite 3.35+ 支持 ALTER DROP COLUMN）
DROP INDEX IF EXISTS idx_item_push;
ALTER TABLE item DROP COLUMN push_state;
ALTER TABLE item DROP COLUMN push_attempts;
ALTER TABLE item DROP COLUMN last_push_error;
```

**不变量保留检查**：`idx_item_ingested(ingested_at_ns, id) WHERE ingested_at_ns IS NOT NULL` 不动（`/since` 主查询路径）；`idx_item_captured` / `idx_item_pinned_captured` / `idx_item_kind_captured` / `idx_item_blob_sha` 全保留；FTS5 触发器 `item_ai / item_au / item_ad` 不引用 push_* 列，不需要重建。

## Config schema

```swift
public struct Config {
    // 保留：serve / serveHost / servePort / serveTLS / tlsCert/Key / sharedSecretKeychainAccount / ocr / capture / hotkey
    // 新增：
    public var peers: [PeerConfig]
    public var mesh: MeshConfig
    // 删除：primaryURL / pull
}

public struct PeerConfig {
    public var url: URL                 // 必填
    public var deviceID: String?        // 可选；nil 时 mesh-init 后由首次 /health 探测回填
}

public struct MeshConfig {
    public var enabled: Bool = true            // 关掉退化为 standalone（=peers 为空）
    public var pullIntervalSec: Int = 30       // floor pull 兜底（WS 通了仍周期跑）
    public var pullBatchLimit: Int = 500
    public var pullInitialBackoffSec: TimeInterval = 2
    public var pullMaxBackoffSec: TimeInterval = 120
    public var crossDeviceDedupWindowNs: Int64 = 5_000_000_000  // Universal Clipboard ±5s
    public var clockSkewWarnMs: Int64 = 30_000
    public var eagerBlobs: Bool = false
    public var wsEnabled: Bool = true          // 关掉退化为 30s 轮询
    public var wsReconnectInitialSec: TimeInterval = 1
    public var wsReconnectMaxSec: TimeInterval = 60
    public var wsHeartbeatSec: TimeInterval = 30
    public var wsServerHeartbeatTimeoutSec: TimeInterval = 75  // > 2x ping 期
}
```

`Config.validate` 新约束：`mesh.enabled && peers.isEmpty && !serve` → invalidCombination；`mesh.wsHeartbeatSec * 2 > mesh.wsServerHeartbeatTimeoutSec` → 拒；peers 内 url scheme/host 校验 + url / deviceID 重复检查。

`Config.write` 沿用现有 "顶层 + 嵌套 merge" 路径，**显式 removeValue 老字段** `primary_url` / `pull`（防 mesh-init 后残留）。`peers` 数组 replace（数组无嵌套 merge 语义）；`mesh` 段 nested merge。

## WebSocket 协议

### Endpoint + Auth

- 路径：`GET /sync/ws`（HTTP Upgrade）
- Auth：现有 `HMACAuthMiddleware` 链路；Upgrade 请求带 `X-DP-Timestamp` / `X-DP-Body-SHA256=<empty hash>` / `X-DP-Auth`。签名串 `<ts_ms>\nGET\n/sync/ws\n<emptyHash>`
- TLS：`serveTLS=true` 走 `wss://`，否则 `ws://`（依赖 Tailscale WG 加密，跟 `/ingest` 同 threat model）
- 建立后 frame **不再签**——长连接里假设已认证（同 SSH session 模型）；server 端可选定期 close 强制重连刷新（如 4h，但 MVP 不做）

### 消息 schema

```swift
enum WSMessage: Codable {
    case cursorAdvanced(version: Int = 1, deviceID: String, latestIngestedAtNs: Int64)
    case hello(version: Int = 1, deviceID: String, nowMs: Int64, latestIngestedAtNs: Int64)
    // ↑ hello 带 baseline latestIngestedAtNs，让 client 重连后能立刻自检要不要 pull
    //   （不靠 hello 就只能等下一次 capture 才触发 advance）
    case ping(version: Int = 1)
    case pong(version: Int = 1)
}
```

Wire 形态：JSON `{"type":"cursor_advanced","version":1,"device_id":"...","latest_ingested_at_ns":...}`

### 心跳 / 重连

- Client 每 `wsHeartbeatSec`（30s）发 ping；连续 2 次没收到 pong → close + 重连
- Server 在 `wsServerHeartbeatTimeoutSec`（75s）内没收到 ping → close
- 重连：`wsReconnectInitialSec` 起步指数翻倍，封顶 `wsReconnectMaxSec`；连成功后立刻 `pullWorker.wake()` 兜底重连期间 missed advance（用 hello 里的 latestIngestedAtNs 跟本地 cursor 比对决定）

### Broadcaster 注入点

`CaptureService.ingest` 完成 `pool.write` 后调用注入闭包 `onCursorAdvanced: @Sendable @escaping (Int64) -> Void`（默认 no-op，方便测试）。`MeshSupervisor` 把闭包路由到 `WSBroadcaster.broadcastCursorAdvanced(deviceID: selfDeviceID, latestNs:)`。Pin / 软删等 bump `ingested_at_ns` 路径同款（`Database.setPinned` 返回新的 `ingestedAtNs`，由 AppDelegate 调用层 broadcast，避免 Core 持有 sync 层闭包）。

## CaptureService 改动

合并 primary / client 双路径成单一 mesh peer 路径：

1. 删 `database.role` 分支判断
2. **新行**永远走 `nextIngestNs(db, now:)` stamp（writer tx 内），删 `ingestNs: Int64? = role == .primary ? ... : nil` 三元
3. **merge candidate 查询**加 `.filter(Column("origin_device") == deviceID)` —— **关键修复**：合表后 item 表含 peer 行，原查询 `kind+text_full+deleted_at_ns IS NULL` 会命中 peer 行并 bump 它的 captured_at_ns / ingested_at_ns（错的：peer 行不该被本机写）。同样改 `ingestBlob` 的 mergeCandidate 查询（按 blob_sha256 也要加 origin 过滤）
4. 删 `pushState` / `pushAttempts` / `lastPushError` 写入路径
5. tx commit 后调 `onCursorAdvanced(ingestNs)`（成功路径 only；merged 路径也调，因为 ingestedAtNs 被 bump 了，peer 需要拉这次刷新）

CaptureService 构造函数新增可选参数：

```swift
public init(
    database: Database,
    blobs: BlobStore,
    deviceID: String,
    ...,
    onCursorAdvanced: @Sendable @escaping (Int64) -> Void = { _ in }
)
```

## Search 改动

合表后 `item` 表含本机 + 所有 peer。Search 路径只剩 `fetchHits` 单表 SQL；text-fold 责任搬进 `fetchHits` 内部 Swift 端兜底。

### fetchHits 新结构

```swift
static func fetchHits(_ db: GRDB.Database, query q: SearchQuery) throws -> [(Item, String?)] {
    // SQL：item join item_fts，ORDER BY pinned/prefix(24h窗)/captured DESC
    // oversample: kinds/pinnedOnly 非空时拉 Int.max；否则 limit+offset

    let raw = try Row.fetchAll(db, sql: oversampleSQL, arguments: ...)
    var hits = raw.map { ... }

    // text-fold: blob_sha256 IS NULL 行按 text_full 二次 fold
    // winner = max(capturedAtNs)，pinned 通过 OR 聚合
    var byText: [String: (Item, String?)] = [:]
    var nonTextFolded: [(Item, String?)] = []
    for hit in hits {
        if hit.0.blobSha256 == nil, let tf = hit.0.textFull, !tf.isEmpty {
            if let existing = byText[tf] {
                let winner = hit.0.capturedAtNs > existing.0.capturedAtNs ? hit : existing
                var w = winner.0
                w.pinned = hit.0.pinned || existing.0.pinned
                byText[tf] = (w, winner.1)
            } else {
                byText[tf] = hit
            }
        } else {
            nonTextFolded.append(hit)
        }
    }
    let folded = Array(byText.values) + nonTextFolded
    // re-sort（fold 改了 pinned 聚合）+ apply 后置 kind/pinned filter + LIMIT/OFFSET
}
```

`count` / `countByKind` 同源走 fold 后路径，保证 list / total / chip 三者口径一致（沿用现有不变量）。

### SearchProvider.Mode 简化

```swift
public enum Mode: Sendable, Equatable {
    case local                          // standalone / peers 空
    case mesh(stalenessSec: Int)        // staleness = now - min(peer.lastPullNs)，最悲观
}
```

`search()` 完全本地同步（无 await）；`searchProvider.remote` 注入参数删。UI banner "mirror Xs 前同步" 改 "mesh Xs 前同步"。

## PullWorker 多 peer 化

`MeshSupervisor.start()`:

```swift
for peer in config.peers {
    let worker = PullWorker(
        peerDeviceID: peer.deviceID,
        peerBaseURL: peer.url,
        transport: HTTPPeerClient(baseURL: peer.url, auth: auth),
        selfDeviceID: deviceID,
        meshStatus: meshStatus,
        ...
    )
    let wsClient = WSNotificationClient(
        peerURL: peer.url,
        auth: auth,
        peerDeviceIDExpected: peer.deviceID,
        onCursorAdvanced: { [weak worker] in worker?.wake() },
        onStatusChange: { connected in meshStatus.update(peerDeviceID: ...) { $0.lastWSConnectedNs = ... } }
    )
    Task { await worker.start() }
    Task { await wsClient.start() }
}
```

### applyPage 改 INSERT 目标

从 `INSERT OR REPLACE INTO item_mirror` 改为 `INSERT OR ... INTO item`：

- `item.originDevice == selfDeviceID` → `INSERT OR IGNORE`（罕见但理论可能：peer 把本机 origin 行回推给本机；不能覆盖本机自家数据）
- `item.originDevice != selfDeviceID` → `INSERT OR REPLACE`（pin 变更 / 软删等 state update 回放）

不再有 `mirrored_at_ns` 列；`ingestedAtNs` 仍保留（peer 视角的全局序）。

### Cross-device dedup 保留

`crossDeviceDedupWindowNs` 逻辑保留：写 item 前查本机 origin=self 同内容在 ±5s 内已存 → skip（Universal Clipboard 同步去重）。

### WS kick

PullWorker `wake()` 已经有 nonisolated 接口（PushWorker 经验），WSNotificationClient 收到 cursorAdvanced 直接调，取消当前 sleep 立刻进入 tick。

## mesh-init CLI

```
duo-pasted mesh-init \
    --peer URL[,DEVICE_ID] \
    --peer URL[,DEVICE_ID] \
    [--serve-host H] \
    [--serve-port P] \
    [--allow-missing-blobs] \
    [--dry-run]
```

步骤（基本沿用 `promoteToPrimary` 不变量）：

1. **daemon 必须停**：检查 `LaunchAgent.isRunning(label:)`；在跑 → throw（refuse），让用户手动 `launchctl bootout`
2. **预检 blob 缺失**：扫 item + item_mirror 里 `blob_sha256 IS NOT NULL AND deleted_at_ns IS NULL` 的去重 sha 集合；缺失 + 默认 → throw `MissingBlobs`；`--allow-missing-blobs` 跳过
3. **预 snapshot**：`Snapshot.takeSnapshot` 落到 `snapshots/`，回滚兜底
4. **打开 DB 触发 v7 migration**：`Database(path: dbPath)` 自动跑 migrator；migration 是单 tx，原子
5. **写 config.json**：`Config.write` 接 `peers` / `mesh` / `serve=true` 新值；`removeValue("primary_url")` + `removeValue("pull")` 清老字段；nested merge 保留未知字段
6. **打印 kickstart 提示**：不主动改 LaunchAgent

**writer tx 边界**：migration 整段在 GRDB DatabaseMigrator 单 tx 内；Config.write 在 tx 外（失败时 DB 已是 v7，操作员手动改 config 或回 snapshot）。

**未决问题**（迁移落地时确认）：执行 mesh-init 时若发现 item 表里有 `push_state='pending'` 或 `'failed'` 的本机 own 行（升级中间态产物），合表前给它们补 `nextIngestNs` stamp + 强制 'acked'。否则升级完后这些行 `ingested_at_ns=NULL` 会被 `/since` 永远过滤掉，peer 永远拉不到（同 `promoteToPrimary` 不变量 #7）。

## 部署 / 升级（用户视角）

**前置**：两台 Mac mini + MBP 都先升级到包含 mesh 代码的新 binary（`./scripts/install-agent.sh`）。

**每台机器**：

```sh
# 1. 停 daemon
launchctl bootout gui/$UID/io.duopaste.agent

# 2. 跑 mesh-init（mini 上）
~/Applications/duo-paste/duo-pasted mesh-init \
    --peer https://mbp.tail-xxx.ts.net:8443 \
    --serve-host 0.0.0.0 --serve-port 8443

# 在 MBP 上反过来
~/Applications/duo-paste/duo-pasted mesh-init \
    --peer https://mac-mini.tail69730a.ts.net:8443 \
    --serve-host 0.0.0.0 --serve-port 8443

# 3. 重启 daemon
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/io.duopaste.agent.plist

# 4. 验证：菜单栏图标显示 "mesh ↔ 1 peer"
#    在 mini 上复制内容 → MBP ⌥⌘V 立即看到（WS 通了 < 1s）
```

### 中间态窗口期

"mini 已 mesh / MBP 还 client" 期间：

- MBP push → mini：mini server 已删 `/ingest` → MBP PushWorker 收 404 标 failed。**这段时间 MBP 新数据不会到 mini**
- MBP pull → mini：仍 OK，mini /since 还在
- **不丢数据**前提：MBP 也跑 mesh-init。`promoteToPrimary` 不变量 #7 路径会把 pending/failed 行 stamp + 合并 → MBP 升级完后这些行可被 mini 通过 /since 拉到

**建议**：两台**同一会话内连续升级**，窗口 < 5min。

### 回滚

1. DB：从 mesh-init 打的 snapshot 恢复 `cp snapshot db/main.sqlite`
2. Config：mesh-init 前可以手动 `cp config.json config.json.pre-mesh.bak`；恢复时手动改回
3. Binary：`git revert` 一组 PR 重 build。**注意**：老 binary 的 migrator 不认识 v7，必须先恢复 v6 snapshot

## 关键不变量（必须保留）

迁移过程中以下契约不能破：

1. `Database.nextIngestNs(db, now:)` 必须在 writer tx 内调用（保 commit 顺序 = ns 顺序，`/since` cursor 无漏行）—— `CaptureService` / `PullWorker.applyPage` 路径不动
2. 文本永久 dedup 两层：**capture 层**（同 origin 同 text_full 永久合并，加了 origin 过滤）+ **search 层**（fetchHits 内置 text-fold，跨 origin 兜底）。两层互补不可少
3. HMAC 签名格式：`<ts_ms>\n<METHOD>\n<path_with_query>\n<sha256_hex(body)>`；WS Upgrade 请求 body 为空走相同模板；Upgrade 后 frame 不签
4. BlobStore content-addressed + `putVerified` 接受字节前重算 sha 校验
5. `pasteBack` 不立刻 hide panel，hide 责任由 onPaste 回调实现方执行（image lazy 路径需要）
6. NSPasteboard 自写防回环：写后 `watcher.suppressUpToCurrent()`
7. `SearchPanelController.onDismiss` 必须 cancel lazy paste task
8. VACUUM INTO 必须 `writeWithoutTransaction`
9. CLI 子命令在 SwiftUI 接管 NSApp 之前 exit
10. **新增**：Pin 操作仅 origin=self 行生效（`Database.setPinned` 已有约束）。Mesh 拓扑下两台同时 pin 同一行不可能发生（只有 origin 那台能 pin 自己的行）

## PR 拆分（推荐顺序）

1. **PR 1 — Schema migration v7（保留 push_*）**：仅合表 + DROP mirror + pull_cursor PK + DROP primary_lineage；**暂不**删 push_* 列；PullWorker INSERT 改 item 表（写 push_state='acked' 维持兼容）；现有 PushWorker / RemoteIngester 测试全过；新增 fold 单测
2. **PR 2 — 多 peer PullWorker**：actor per-peer 实例化；`MeshSupervisor` 框架；`MeshStatus` 取代 `MirrorStatus`；单 peer 部署行为等价；新增"两 peer 起 2 个 PullWorker"集成测试
3. **PR 3 — WebSocket 通知层**：`WSBroadcaster` + `WSNotificationClient` + `/sync/ws` route；CaptureService 加 onCursorAdvanced 闭包；本机 capture → 5s 内对端拉到
4. **PR 4 — 删 push 链路**：删 PushWorker / RemoteIngester / IngestRequest / AuditPush / `/ingest` / Item push_* + v8 migration `ALTER DROP COLUMN`；删 promote / migrate CLI + 测试
5. **PR 5 — mesh-init CLI**：`Admin.meshInit` + `MeshInitTests`；Config schema 完整切换；从 v6 fixture DB + 老 config 出发跑 mesh-init 验证
6. **PR 6 — 收尾**：删 MirrorStatus.swift；删 SearchProvider remote 分支；统一 banner 文案；性能 / 长跑测试

## 风险评估

| 风险 | 缓解 |
|---|---|
| **PoC P0**：Hummingbird WebSocket client 在 self-signed TLS 场景兼容性 | Tailscale `tailscale cert` 已签 Let's Encrypt，客户端默认信任。仍要先 spike 最小 client 跑通 cert + Upgrade 再写 WSNotificationClient。Fallback：URLSessionWebSocketTask（API 不同要重新封） |
| macOS App Nap 冻结 WS 长连接 | daemon 启动时 `ProcessInfo.beginActivity(options: .userInitiated)` 拿 activity assertion；本地跑 1 小时不动键鼠测试 WS 是否仍连。worst case 退化为 30s pull |
| 中间态窗口期数据不一致 | mesh-init 合并阶段会兜底 stamp pending/failed 行（不变量 #7）；建议两台连续升级 < 5min 窗口 |
| 删大量代码（push / promote / migrate / audit）回归 | 每条路径有专属测试整文件一起删；text-fold 性能新增 1 万行 fixture timing 断言（< 100ms） |
| Universal Clipboard 跨 peer 同文本去重 | `PullWorker.crossDeviceDedupWindowNs` 逻辑保留（写 item 前查本机 origin=self ±5s 同内容 → skip），等效保留原 RemoteIngester + PullWorker 两端 hook |
| `audit-push` 失去后无对账工具 | 后续可加 `mesh-doctor` CLI（探所有 peer /health + 对比 pull_cursor + blob 缺失统计），MVP 不做 |

## 验证

### 测试覆盖

- **新增**：`MigrationV7Tests`（v6→v7 round-trip）/ `MeshInitTests`（daemon guard / missing blobs / dryRun）/ `WSProtocolTests`（encode/decode）/ `WSBroadcasterTests`（多连接广播 + 慢消费者踢）/ `WSNotificationClientTests`（重连退避 + ping/pong 超时 + 收到通知触发 wake）/ `MultiPeerPullWorkerTests`（多 peer cursor 独立 + WS kick 取消 sleep + 跨 peer 同文本 fold）
- **改动**：`PullWorkerTests`（删"primary 换了"用例改"peer device_id 换了"）/ `SearchTests` / `SearchPrefixBoostTests`（fixture 改成"item 单表跨 origin 混存"）/ `BlobLazyPullTests`（BlobFetcher 改 HTTPPeerClient，多 peer 探 GET 顺序）
- **删除**：`PushWorkerTests` / `IngestTests` / `AuditPushTests` / `AdminPromoteTests` / `AdminMigrateTests` / `SearchUnionTests`

### 端到端验证步骤

```sh
swift build && swift test  # 全过

# 准备两套独立 testdata
# 在 fixture-mini 上跑 mesh-init --peer fixture-mbp
# 在 fixture-mbp 上跑 mesh-init --peer fixture-mini
# 各自起 daemon

# 在 mini 上 capture 一条文本 → 检查 MBP 5s 内拉到（WS 通了 < 1s）
# 关掉 mini 的 WS（mesh.ws_enabled=false）→ 验证 30s 内仍能拉到
# 关掉 mini 的网络一段时间 → MBP 应当 backoff 重连 + 上线后追上
```

### 不变量回归

- 检查 `SearchProvider` 测试 `searchProviderSkipsRemoteWhenMirrorActive` 重命名为 `searchProviderUsesLocalWhenMeshReady` —— 验证 `oldestLastPullNs() != nil` 时走 .mesh 不再远端调用（远端 SearchTransport 已删，断言改成 transport 不存在）
- `prefix boost 24h 窗`回归（SearchPrefixBoostTests 4 条全过）

## Critical Files

- `Sources/DuoPasteCore/Database.swift` — v7 migration 落点
- `Sources/DuoPasteCore/Config.swift` — schema 重写主战场
- `Sources/DuoPasteCore/CaptureService.swift` — 关键 bug 修复（mergeCandidate origin 过滤）+ 路径合并
- `Sources/DuoPasteCore/Search.swift` — fetchHits 内置 fold
- `Sources/DuoPasteSync/PullWorker.swift` — 多 peer 化主战场
- `Sources/DuoPasteSync/Server.swift` — /sync/ws upgrade route
- `Sources/duo-pasted/AppDelegate.swift` — 启动入口换 MeshSupervisor

## 已知后续工作（不在本次重构范围）

- `mesh-doctor` CLI（探 peer /health + 对账 pull_cursor / blob 缺失）
- WS server 端定期主动 close 强制重连刷新（4h），让安全边界不靠"连接永生"
- iOS peer 接入（M5）
- Peer 自动发现（bonjour `_duopaste._tcp.local`）—— 当前手填 peers

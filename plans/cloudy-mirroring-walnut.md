# Storage mode — full mirror（默认）/ optimized（按需）+ LRU 驱逐

## Context

**Mesh 拓扑下当前 blob 同步语义有错位**。`mesh.eager_blobs` 默认 `false` 让 PullWorker 只同步元数据不拉字节，「真要粘的那一刻」走 lazy GET `/blob/<sha>` 拉。设计动机是 M2 primary/client 时代的省存储省带宽——client 是「远程偶尔粘贴」的角色。

切到 mesh 拓扑后两台 Mac 平等，这套 lazy-by-default 带出三个肉眼可见的问题：

1. **零冗余**：某 sha 唯一存在的那台挂了 → 另一台 lazy fetch 永远 404，blob 字节永久丢失。mesh 字面意思就是「每节点完整副本」，违反语义
2. **离线就废**：peer URL 不通时（飞机/弱网）所有 peer-origin 图都拉不到
3. **UI 默认坏掉**：缩略图 + Space 预览路径**不会触发 lazy fetch**，只查本地 BlobStore → 缺 blob = 「图片预览失败」占位。**用户在 mini 上截图实测，最近 3.5h 的 8 张 peer file-image 全本机缺 blob，全部预览失败**

而 lazy 模式的存储节省在 daily-driver 双 Mac (mini 1TB SSD / MBP 类似) 场景下毫无意义——全量 blob 也就几十 GB。

**目标**：把 blob 同步模型从「lazy by default」翻成 iCloud 「优化存储」式的二态抽象——默认 `full mirror`（mesh 字面语义），`optimized` 显式 opt-in 给存储受限节点（未来 iOS peer M5、小盘 Mac、临时备机）。

## 设计决策（用户已确认）

| 题 | 决策 | 理由 |
|---|---|---|
| 抽象命名 | `storage_mode: "full" \| "optimized"` 替换 `eager_blobs: Bool` | 对齐 iCloud 优化存储心智，用户立刻懂；布尔字段语义不清 |
| 默认值 | `full`（PullWorker eager 拉 blob 字节） | mesh 字面语义；daily-driver 场景存储不是约束 |
| optimized 触发点 | 缩略图渲染 / Space 预览 / Enter 粘贴 | UI 内每次「需要看到字节」的操作都自动拉；用户无感 |
| UI 状态提示 | iCloud 风格 ☁️ SF Symbol 覆盖卡片角标 + 下载中转圈 | 用户能区分「本地有」vs「peer 上有但没下载」 |
| 历史 catch-up | 新 CLI `mesh-fetch-missing`（或扩 `mesh-doctor` 加 `--fetch` flag） | 用户从 lazy 切 full 后跑一次补齐历史缺失 blob |
| 老 config 兼容 | `eager_blobs=true` 隐式映射 `storage_mode=full`；`eager_blobs=false` 或缺失映射 `full`（**新默认**）；只有显式声明 `storage_mode=optimized` 才走 lazy | 升级零摩擦，老配置自动得到「修复后的正确语义」 |
| Schema | 不动 DB（纯 config 改动） | blob 字节存储 metadata 不变；BlobStore.exists 已经能区分 |

## Non-Goals

- **不做单条 blob 手动 evict**：iCloud 有「移除下载副本」按钮，本期不抄——blob 量级小，没必要
- ~~**不做 LRU 自动清理**~~：**已落地（PR 5）**——磁盘水位驱逐 + ENOSPC 救援，永不删 text / pinned 行
- **不做跨 peer fanout 重试**：lazy fetch 仍只打 `peers[0]`（沿用现状）；多 peer 调度是另一个 plan
- **不动 OCR worker**：OCR Phase 1 严格 own-origin，跟 storage_mode 解耦
- **不动 `mesh-init` 预检逻辑**：现在 `missingBlobs` 默认拒——切到 full 默认后这个预检语义更对（mesh 就该有完整副本），不需要改

## 文件级改动清单

### 新增

- `Sources/DuoPasteCore/StorageMode.swift` — `public enum StorageMode: String, Codable, Sendable { case full, optimized }` + `static let `default`: StorageMode = .full`；CLI 友好的 `description` / `init?(rawValue:)`
- `Sources/duo-pasted/CLI.swift` 新子命令 `mesh-fetch-missing`（或选 `mesh-doctor --fetch <yes|all>`）：扫 DB 找 origin=peer + kind in (image,file) + blob_sha256 非空 + BlobStore 不在的所有 sha，按 peer 分组并发 GET `/blob/<sha>` 补到本机。复用 `HTTPPeerClient.getBlob` + `BlobStore.putVerified`
- `Sources/duo-pasted/CloudBadgeView.swift` — SwiftUI 视图，输入 `(item: Item, blobs: BlobStore, fetcher: BlobFetcher?, storageMode: StorageMode)`；optimized 模式 + blob 不在本地时显示 ☁️ + 「点击下载」hover 提示；下载中转圈。复用已有 `pasteBlobFetcher`

### 修改

- `Sources/DuoPasteCore/Config.swift`：
  - `MeshConfig` 加 `storageMode: StorageMode`；删 `eagerBlobs: Bool` 字段
  - decode 路径加兼容：先尝 `storage_mode` 键；缺失时尝老键 `eager_blobs`（`true → .full`，`false → .full` 因为新默认改了），都缺则 `.full`
  - `validate()`：StorageMode 已经是 enum 不需要单独 validate
  - `Config.write` 写 `storage_mode` 键 + 显式 `removeValue("eager_blobs")` 让升级后老字段被洗掉
  - 默认值：`storageMode: .full` 替换 `eagerBlobs: false`
- `Sources/DuoPasteSync/PullWorker.swift`：
  - `Config` 字段从 `eagerBlobs: Bool` 改 `storageMode: StorageMode`
  - `fetchBlobsEager` 第一行 guard 改 `config.storageMode == .full`
  - 名字 `fetchBlobsEager` 改 `fetchBlobsFull` 跟 mode 命名对齐；调用点同步改
- `Sources/duo-pasted/SearchView.swift`：
  - `ImageThumbnailCache.thumbnail(for:blobs:)` 加可选 `fetcher: BlobFetcher?` + `storageMode: StorageMode` 参数
  - 缩略图渲染流程：`blobs.read(sha256:)` 拿到 nil 时——`storage_mode == .optimized && fetcher != nil` → `await fetcher.getBlob(sha256:)` 拉字节，成功后 `BlobStore.putVerified` 写盘 + 解码；`storage_mode == .full` → 直接 return nil（理论上 PullWorker 已拉，缺失说明 catch-up 没跑过）
  - `prefetch(items:blobs:)` 同样接 fetcher + storageMode；optimized 模式 prefetch 跳过 lazy fetch（用户没主动看就别拉，避免后台流量）
- `Sources/duo-pasted/PreviewOverlay.swift`：
  - `PreviewPanelController.decodeMedia(item:blobs:)` 加 `fetcher` + `storageMode` 参数
  - blob 不在本地时 optimized 模式起 fetch；UI 内 PreviewPanelContent 显示「下载中…」状态 + cancel 入口（关 panel 取消，跟 lazy paste 路径同源处理）
- `Sources/duo-pasted/AppDelegate.swift`：
  - 把 `pasteBlobFetcher` 暴露给 `AppState` / SearchView / PreviewPanelController（已经有，extend 注入路径）
  - `applicationDidFinishLaunching` 启动期日志加 `storage_mode=full|optimized`
- `Sources/DuoPasteCore/Admin.swift`：
  - 新增 `Admin.fetchMissingBlobs(dbPath:blobs:peers:secret:concurrency:log:) async throws -> Report`——一次性 catch-up，按 peer 分组扫缺失 sha → 并发 (concurrency 默 4) GET `/blob/<sha>` → `putVerified` 写盘。返回 `(total, fetched, failed, missing)` 统计
  - 复用 `scanMissingBlobs` 拿候选清单
- `Sources/duo-pasted/CLI.swift`：
  - 新 case `mesh-fetch-missing`，wrapper 调 `Admin.fetchMissingBlobs`，支持 `--dry-run`（默 false）/ `--concurrency N`（默 4）/ `--peer <url>` 单峰目标（默全 peers）
  - help 文案 + dispatch 注册

### 删除

- `Sources/DuoPasteCore/Config.swift` 内 `eagerBlobs` 字段定义 + CodingKey + write 序列化
- 测试：`MeshConfigTests` 里 `eager_blobs` 相关用例改名跟 storage_mode 对齐

## Schema migration

**无 DB schema 改动**——本期纯 config + 行为层重构。

## 已有代码可复用的关键点

- `Sources/DuoPasteCore/Admin.swift:101-145` `scanMissingBlobs` 已经实现「扫 origin=peer + kind in (image,file) + blob_sha256 非空 + BlobStore.exists=false」的查询，直接拿来 catch-up CLI 用
- `Sources/duo-pasted/AppDelegate.swift:641` `fetchBlobLazy` + `fetchBlobLazyInner` 已经实现 5s timeout + retry backoff + sha 校验的健壮 lazy 路径；UI hook 直接复用，不要写第二份
- `Sources/DuoPasteSync/PullWorker.swift:515` `fetchBlobsEager` 内部已经处理 sha 验证（`BlobStore.putVerified`）+ 失败不阻塞 tick；只改 guard 条件即可
- `Sources/duo-pasted/PreviewOverlay.swift:211` `decodeMedia` 是 nonisolated 后台 task，加 async fetch 完全适配现有 task 模型

## PR 拆分

### PR 1 — config schema 翻新 + 默认值翻 full（最小可上线）

- `StorageMode.swift` 新增
- `Config.swift` 字段 + 解码兼容（`eager_blobs` 老键映射）+ 序列化
- `PullWorker.swift` guard 改 storageMode + 命名
- 默认 `.full` 让升级用户**立刻**得到正确语义
- 测试：`MeshConfigDecodingTests` 加 5 个用例（新 key / 老 key true/false / 都缺 / 老新都有冲突取新值）

**风险**：用户升级后 PullWorker 突然开始 eager 拉字节；下一次 tick 会狂拉 missing blobs（取决于本机缺多少）。但 lazy 路径 5s 超时 + transient 不阻塞 cursor，所以最坏只是慢一会儿，不会卡死

### PR 2 — `mesh-fetch-missing` 一次性 catch-up CLI

- `Admin.fetchMissingBlobs` 纯函数实现
- CLI wrapper + help
- `--dry-run` / `--concurrency` / `--peer` flags
- 测试：mock peer 返回 200/404/损坏字节场景 + 并发计数

**用法**：用户切 full 模式后跑一次补历史；以后 PR 1 的 eager pull 自动处理新行

### PR 3 — UI 内 optimized lazy hook（缩略图 + 预览）

- `ImageThumbnailCache.thumbnail` 接 fetcher + storageMode；optimized 缺 blob → lazy fetch
- `PreviewPanelController.decodeMedia` 同上
- AppDelegate 把 `pasteBlobFetcher` 注入 AppState / SearchView / PreviewPanelController
- 测试：`ImageThumbnailCacheTests` 加 (mode=full + 缺 blob → 立返 nil) 和 (mode=optimized + 缺 blob → fetch 成功后命中) 两条

**风险**：UI 卡片大量同时缺 blob 时 lazy fetch 会并发打 peer——继承 `fetchBlobLazy` 的 5s 超时不会阻塞 UI thread，但 peer 短时间扛压；prefetch 跳过 optimized 模式已经规避了批量预拉

### PR 4 — iCloud 风格 ☁️ 角标

- `CloudBadgeView` 新增
- SearchView 卡片右上角 overlay；状态机：`local`（不显示）/ `cloud`（☁️）/ `downloading`（转圈）/ `failed`（红色 !）
- 点击 ☁️ 主动触发 lazy fetch（哪怕没要 paste，用户想预先下载也行）
- 测试：状态机单测 + snapshot test（如果有 SwiftUI snapshot infra）

**单独拆**因为 UX polish 不阻塞功能；PR 1-3 上线后系统已经能用，PR 4 让用户看得见 mode 差异

### PR 5 — disk-pressure LRU 驱逐（已落地 2026-05）

**Context**：full mirror 默认上线后，daily-driver 长尾问题暴露——blob 仓库无封顶，没 GC，没驱逐。磁盘满时 capture/paste/pull 三条 put 路径全部 silent 失败（CaptureService 丢条；PullWorker 留 phantom mirror 行刷重试日志；lazy paste `.failed` banner）。用户原话："满了的时候自动删除 oldest 那个文件，否则就删除 older？我希望依然保留文本"。

**核心契约**（不要回退）：

1. **只驱逐 blob 文件**——`item.blob_sha256` 行保留指向 sha，`BlobStore.exists()` 之后返回 false → UI 走 CloudBadge 状态 → Enter 走 lazy 路径从 peer 重拉。等价 per-row 降级到 `storage_mode=.optimized` 行为
2. **永不删 text 行**（`blob_sha256 IS NULL`）——用户硬要求"保留文本"，数据本身占空间小
3. **永不删 pinned**（`pinned=1`）——硬不变量
4. **永不删 DB 行**——驱逐 ≠ tombstone

**两档触发**：
- **救援档**（实时）：BlobStore.put / putVerified ENOSPC catch → evictor 同步释放 LRU → retry。覆盖 CaptureService.ingestBlob / PullWorker.fetchBlobsFull / AppDelegate.pasteBack lazy 三个核心站点
- **预防档**（周期）：SnapshotScheduler hourly tick 末尾跑 `evictToWatermark(low=5GB, high=10GB)`。双水位 hysteresis 防抖；perTickCap=500 兜底

**新文件**：

- `Sources/DuoPasteCore/BlobEvictor.swift` —— `evictOneOldest(batchSize:)` + `evictToWatermark(lowBytes:highBytes:perTickCap:availableBytes:)`
- `Sources/DuoPasteCore/DiskFull.swift` —— ENOSPC 三路检测（POSIXError 28 / NSFileWriteOutOfSpaceError 640 / Cocoa 包 underlying POSIX）
- `Sources/DuoPasteCore/Volume.swift` —— `availableBytes(at:)` + `directorySize(at:)`
- `Tests/DuoPasteCoreTests/BlobEvictionTests.swift` —— 29 个测试覆盖 pinned/tombstone/text-only 排除、LRU 顺序、跨 origin sha dedup、retry loop 骨架、DiskFull 检测、watermark 行为

**修改**：

- `Sources/DuoPasteCore/BlobStore.swift` —— `evict(sha:) -> EvictOutcome` + `size(sha:)` + `putRetryingOnFull` / `putVerifiedRetryingOnFull` 包装（共享内部 `retryOnFull` 循环）
- `Sources/DuoPasteCore/Database.swift` —— `refCountForBlob(sha:)` + `oldestEvictableShas(limit:)` SQL（`GROUP BY blob_sha256 ORDER BY MIN(captured_at_ns) ASC` + 三道硬过滤）
- `Sources/DuoPasteCore/CaptureService.swift` —— 加 `evictOnFull: (@Sendable () throws -> Bool)?` 注入；ingestBlob 路径走 retry 版本
- `Sources/DuoPasteSync/PullWorker.swift` —— 同上，fetchBlobsFull 用 retry 版本
- `Sources/duo-pasted/AppDelegate.swift` —— pasteBack lazy 落盘走 `deps.blobs.putVerifiedRetryingOnFull(..., evictor: deps.evictOnFull)`
- `Sources/duo-pasted/AppDependencies.swift` —— 进程级 `BlobEvictor` + `evictOnFull` 闭包
- `Sources/duo-pasted/SnapshotScheduler.swift` —— tick 末尾跑 `runBlobWatermarkGC()`，硬编码 5GB/10GB
- `Sources/duo-pasted/SettingsView.swift` —— 关于 tab 加「存储」section 显示 blob 占用 + 可用空间 + 水位 hint

**已保留现状**（按 "Don't add features beyond what the task requires"）：

- `Admin.fetchMissingBlobs` / `PreviewOverlay` / `SearchView` 的 `try?` 站点——admin / 预览 UI 路径 ENOSPC 失败可接受，不强行驱逐
- 阈值硬编码 5GB/10GB——系统级常量；用户要调改源码
- 不按 kind 拆分 blob 占用——一行总数够用
- 不加"立即跑 LRU"按钮——预防档每小时自然跑

**风险 / 验证**：

- 阈值 5GB/10GB 对小盘 Mac（128GB）偏紧；对大盘 SSD（2TB）偏松。daily-driver 双 Mac 1TB 场景合适
- ENOSPC 仿真要 `dd if=/dev/zero` 占满 tmp 卷，CI 不易构造——retry loop 用 mock 闭包测覆盖；真 ENOSPC 路径靠 install-agent + 实机自然观察
- SwiftUI Settings 「存储」section 用 `Task.detached` 算占用——10k+ blob 走 enumerator < 1s，但仍异步跑不卡 UI

## 不变量（PR 1-5 落地后）

1. **`storage_mode=full`（默认）= 完整 mirror**：PullWorker 每 tick 顺路拉新 page 的 blob 字节；BlobStore.exists 为 false 是异常（catch-up 应该已经跑过）**或被 LRU 驱逐过**（PR 5）
2. **`storage_mode=optimized` = 按需拉**：PullWorker 不拉字节；UI 看到时自动拉；本地 BlobStore 是 hot cache 不是源
3. **paste 路径行为跟 mode 解耦**：Enter 触发的 lazy fetch 永远走（无论 mode 如何）——full 模式正常不会触发，但兜底；optimized 模式是主路径；**LRU 驱逐过的 sha 也走 lazy 重拉**（PR 5）
4. **catch-up 不阻塞 daemon**：`mesh-fetch-missing` 是 CLI 子命令独立进程，跟 daemon 同时跑 OK（GRDB DatabasePool 并发安全 + BlobStore.putVerified 原子 rename）
5. **老 `eager_blobs` 字段**：完成 PR 1 写入新 config 后被 removeValue 洗掉；老代码不存在了
6. **LRU 驱逐只动 fs 不动 DB 行**（PR 5）：`item.blob_sha256` 保留指向 sha；CloudBadge UI 自动落到"云端"态；lazy paste 路径从 peer 重拉。**pinned / text-only / tombstone 行的 blob 永不驱逐**
7. **磁盘满不丢 capture / paste**（PR 5）：BlobStore.put ENOSPC → 同步驱逐 oldest → retry。三路 put 站点（capture / pull / lazy paste）都走 retry 版本。仿真 ENOSPC 难，靠实机验

## 测试覆盖

- `StorageModeTests`：decode 兼容 + raw value + default
- `MeshConfigDecodingTests` 扩 5 用例：见 PR 1
- `AdminFetchMissingBlobsTests`：mock peer 200/404/损坏/timeout 各场景；dry-run 不写盘；concurrency 实际并发数（用 fake clock + signaller）
- `ImageThumbnailCacheTests` 扩两用例：见 PR 3
- `PullWorkerStorageModeTests`：mode=full 顺路拉 + mode=optimized 跳过（mock fetcher 验证调用次数）
- 集成：`MeshSyncIntegrationTests` 跑 (full + optimized) × (本机有/缺 blob) 矩阵

## 部署 / 升级路径

切到 PR 1（默认 full）：

```sh
# 两台都升二进制后
launchctl kickstart -k gui/$UID/io.duopaste.agent

# PR 2 之后用户跑一次补齐历史：
~/Applications/duo-paste/duo-pasted mesh-fetch-missing
# 输出: fetched=8, failed=0, total_missing=8, took=2.3s

# 想节省存储的设备（未来 iOS / 小盘备机）显式 opt-in：
# 改 ~/Library/Application Support/duo-paste/config.json
{
  "mesh": {
    "storage_mode": "optimized",
    ...
  }
}
launchctl kickstart -k gui/$UID/io.duopaste.agent
```

## 已知坑（写代码时记住）

- **`install-agent.sh` 后必须 `codesign --force --sign -`**（见 [memory: install-agent.sh 后必须 codesign --force](../../.claude/projects/-Users-bobby-Developer-jizhi0v0-duo-paste/memory/feedback_install_codesign.md)）——SwiftPM 增量 build 出来的 linker-signed adhoc 二进制 macOS 26 taskgate 会 SIGKILL
- **PR 1 升级后第一次 tick 会狂拉**——如果用户本机缺很多 peer blob，第一次 pull tick 会同步拉一堆字节。fetchBlobsEager 已经 concurrency 限制 + 失败不抛，所以最坏只是慢；但日志会刷很多 `eager blob get ...`
- **catch-up CLI 走 HMAC 跟 daemon 同一份 shared-secret**——CLI 进程读 `~/Library/Application Support/duo-paste/shared-secret` 同路径；不要走 keychain（daemon 才用 keychain，CLI 简单读文件）
- **UI fetcher 注入要顺路传** `storageMode`——别再加单独的 `@EnvironmentObject` 或全局，已经够乱了；直接通过 `SearchView` / `PreviewPanelController` init 参数传

## 命名 candidate

`cloudy-mirroring-walnut`——「云端化镜像」语义对齐 iCloud；whimsical 收尾对齐 plans/ 命名风格 (`vivid-scanning-vellum` / `mesh-polished-chipmunk` / `vivid-mapping-muffin`)

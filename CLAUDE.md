# duo-paste

替换 Paste.app 的自托管剪贴板管理器，Apple-only。M1（单机）+ M2（multi-Mac primary/client）已上线 daily-driver；M3 第一刀 + 第二刀（mirror pull worker + 本地 union 搜索）已完工，client 搜索不再过 Tailscale。

正式架构计划：`plans/https-pasteapp-io-macos-ios-paste-moonlit-wave.md`。

## 项目当前状态

- **M1 完成**：捕获 + SQLite/FTS5 + 内容寻址 blob + SwiftUI 搜索窗（NSPanel HUD）+ ⌥⌘V 全局快捷键 + 菜单栏 + LaunchAgent + 小时级 snapshot
- **M2 已上线生产**：mini = primary（HTTPS @ 0.0.0.0:8443，`bobbys-mac-mini.tail69730a.ts.net`）+ MBP（`100.68.44.27`）= client。双向同步在 DB 层验证通过
- **M3 第一刀 完成**：`GET /since` 增量 cursor API + 一致性根因修复
  - `SinceAPI` / `SinceCursor (ns, id)` 二元 cursor / `SincePageWire` Codable wire 形态
  - `Database.nextIngestNs(db, now:)` 在 writer tx 内 stamp ingested_at_ns，保证 commit 顺序 = ns 顺序（避免 mirror cursor 漏行）；RemoteIngester + CaptureService 全用它
  - v3 migration：`idx_item_ingested(ingested_at_ns, id) WHERE ingested_at_ns IS NOT NULL` partial index，配 /since cursor 走 index-only seek
  - `parseSinceQuery` parse 层 clamp limit；handler 返回 `{items, next_cursor, has_more, count}`
  - primary 上 capture merge 路径也 bump ingested_at_ns，让 mirror 看见合并更新
- **M3 第二刀 完成**：mirror pull worker + 本地 union 搜索
  - v4 migration：pull_cursor 加 cursor_id 列（SinceCursor 二元 cursor 持久化）
  - `MirrorStatus` 共享对象（NSLock）：PullWorker 写 `lastPullNs`/`primaryDeviceID`，SearchProvider 读
  - `SinceClient` (HTTPIngestClient extension) 实现 `SinceTransport`：`/since` + `/health`（容忍 String/Int64/Double 三种 `now_ms` 编码）
  - `PullWorker` actor：仿 PushWorker 单 actor 串行 tick。每 tick = `/health` → 比对 persisted primary_id（变了 → 清空 mirror + cursor 重拉）→ `/since` → INSERT OR REPLACE item_mirror（**跳过 origin=self**，让 union 不重叠）→ 更新 pull_cursor。`has_more=true` 立刻接下一页，否则 sleep `pull.interval_sec`（默认 30s）。`lastPullNs` 只在 `!hadTransient && !hasMore` 时设——表示"已严格追平"
  - `SearchAPI.searchUnion` + `fetchHitsMirror`：item + item_mirror 各超量取 limit+offset，**先按 id dedupe（取 capturedAtNs 最大那份，无视 pinned 状态）**，再按 (pinned DESC, prefix DESC, captured_at_ns DESC) 排序，最后裁 limit/offset
  - `SearchProvider.Mode.localMirror(stalenessSec:)`：`mirrorLastPullNs()` 非 nil → 直接走 `searchUnion`，**不**打远端
  - UI banner：`.localMirror` 灰色「本地镜像 · 更新于 Xs/m/h 前」；`.remoteFallback` 黄色保留
- **Capture 字节守门 完成**：`config.capture.{max_blob_mb=32, max_text_kb=512}` 默认。意外复制超大对象跳过入库（NSPasteboard 自身不受影响，Cmd+V 仍正常）。UI 端 orange skipBanner 5 分钟自动消失 + 手动 ✕ 关闭。详见下文设计决策段
- **M3 完成**（PR#4 + PR#7 + PR#8 + PR#10 + PR#11 + blob 懒拉已就位）：
  - **时钟偏移 sanity check**：PullWorker 每 tick 在 `/health` 拿 `primary.now_ms` 跟本机 wall-clock 比对，通过 `MirrorStatus.clockSkewMs()` 暴露给 UI；|skew| ≥ 30s 时 log warn + `SearchView.clockSkewBanner` 黄色提示（HMAC 容忍 ±5 分钟，30s 是早期预警）
  - **audit-push 子命令**：`duo-pasted audit-push [--sample N]` 拿本机 own-origin item 跟 primary `/since` 全量对账。输出 push_state 分布 + missing on primary + failed 详情 + **Continuity dedup absorbed**（acked 但 id 不在 primary，内容在跨 origin 行 ±5s 找到）+ **stale on primary**（同 id 但 pinned / deletedAtNs / capturedAtNs diverge，RemoteIngester 不更新已有行造成）+ **dedupAbsorbedThenDeleted**（吸收源后被软删，单独成桶让操作员判断是否预期）。exit 码：missing/failed/stale 任一非 0 → 1
  - **promote-to-primary 子命令**（PR#7）：`duo-pasted promote-to-primary [--serve-host H] [--serve-port P]` 把本机从 client 提升为 primary。一个 writer tx 内：(1) `INSERT OR IGNORE INTO item SELECT ... FROM item_mirror` 把 mirror 抬进 item（保留 origin_device，新行 push_state='acked'），(2) 清空 item_mirror + pull_cursor，(3) 写 `primary_lineage` 两行——`(self, now, NULL)` 开新任期 + `(old_primary, 0, now)` 闭老任期（started=0=未知起点）。然后用 `Config.write` 改 config.json：`serve=true`、移除 primary_url、`pull.enabled=false`，**保留未知字段**（capture / tls / 用户手动加的注释 key 都不丢）。子命令不动 LaunchAgent，打印 kickstart 提示
  - **v5 migration**：`primary_lineage(device_id TEXT, started_at_ns INTEGER, ended_at_ns INTEGER, PK(device_id, started_at_ns))`。PR#7 埋数据；PR#8 切 audit-push：按 row.capturedAtNs 落在 `[started_at_ns, ended_at_ns)` 区间确定该 push 时刻的 active primary，dedup 候选必须 origin 严格 == 这个 device_id。空 lineage / 时间未覆盖 / expected==self 的 stale 边界回退 `origin != self` 启发式保单 primary 部署零回归
  - **migrate-primary 子命令**：`duo-pasted migrate-primary [--new-primary-host HOST]` 在老 primary 上跑 prepare 阶段：校验 primary 模式 + daemon 不在跑 + VACUUM INTO 落一份 snapshot 到 `snapshots/`（复用 `Snapshot.filename` 命名）+ walk `blobs/` 统计 files/bytes + 读 item/item_mirror 行数。命令本身只读（除快照副产物），不动 DB/config/blobs；输出 rsync 命令模板 + 新机配置步骤 + 其他 client 后续动作（改 primary_url + audit-push 补齐）。**MVP 不写 lineage** —— 新 primary 接管行没人写，单 primary 部署 audit-push 不受影响，多次换 primary 链路下可能产生跨任期 dedup 误判（plan §b 原文也没要求；后续可加 `--demote-and-record` flag 补）
  - **blob 懒拉**：两条互补路径覆盖"mirror client 上图片 paste-back"痛点
    - **Lazy (paste-back)**：`AppDelegate.pasteBack` 在 image kind + 本机 `BlobStore` 缺字节时起 `currentPasteTask`：UI banner `.fetching(spinner)` → `BlobFetcher.getBlob` (2 次 backoff 2s/4s，总超时 5s) → `BlobStore.putVerified` (sha 校验防 MITM) → `Copyback.write` + `panel.hide`。失败 → banner `.failed(reason)`，panel 保持显示让用户看错误。多次按 Enter 自动 cancel 旧 task 避免重复 GET 竞争 BlobStore.put
    - **Eager (`pull.eager_blobs=true`)**：PullWorker `applyPage` 同事务收集本页 image/file + deleted_at_ns IS NULL 的 sha 集合；tick 完 cursor 已 commit 后 best-effort 循环 GET missing blobs → `putVerified`。失败 only log，**不阻塞 cursor 推进**——下次 tick 同 sha 自然重试。已存在的 sha 直接 short-circuit 走 BlobStore.exists 不发请求
    - **新协议 `BlobFetcher`**：`HTTPIngestClient.getBlob` 实现 GET /blob + HMAC + 200 时本地重算 sha 校验防字节篡改。返回 `.found(Data)` / `.notFound`；4xx 非 404 / 5xx / sha mismatch 走 `GetBlobError`（rejected / transient / shaMismatch）。新增 `BlobStore.putVerified` 防御接口先校验 expected sha 再落盘
    - **UI 入口契约改动**：`SearchPanelController.installKeyMonitor` 的 Enter case 不再立刻 `self.hide()`——把 "何时 hide" 交给 onPaste 回调实现。AppDelegate.pasteBack 在同步路径完成后 `panel.hide()`、慢路径（image + missing）由 currentPasteTask 完成时再 hide。不变量：panel 持有引用 = 控制权
- M3 全部完成；下一站 M4
- **RTF 三层降级 完成**（PR#3 + PR#5 合作）：watcher 抓 RTF 时优先 (a) pasteboard 自带非空 .string → 直接用；(b) raw RTF 字节 ≤ `maxTextBytes` cap → `decodeRTFToPlain` 用 NSAttributedString 解出 plain；(c) 失败/全空白/raw 太大 → 兜底存 raw rtf 让 CaptureService 字节守门拦下。`PasteboardWatcher.maxRawRTFBytes` 由 AppDelegate 注入 `deps.config.capture.maxTextBytes`，避免 50MB RTF 在 @MainActor 轮询路径上同步分配巨型 NSAttributedString
- **搜索 prefix boost 完成**（PR#6）：搜索排序契约 `(pinned DESC, prefix DESC, captured_at_ns DESC)`。`preview` 起始命中 = 2 分 / `text_full` 起始命中 = 1 分 / 否则 0。**24h 时间窗**：只对 24h 内的项生效，跨天老内容哪怕起头匹配也按时间倒序排——剪贴板心智是"搜=找最近用过的"。SQL 端三条路径（`fetchHits` / `fetchHitsMirror` / `fetch`）+ Swift 端 `fetchUnion.prefixScore` 全部对称实现，回归测试见 `SearchPrefixBoostTests.swift`
- **测试**：236 个测试（含 BlobStoreTests 4 + BlobLazyPullTests 10）。BlobLazyPullTests 覆盖 `eager_blobs` 拉 missing + off skip / 已有字节短路 / tombstone 跳过 / own-origin 跳过 / fetcher 失败不回滚 mirror / notFound 不致命 + HTTPIngestClient.getBlob 端到端（200/404/401）。BlobStoreTests 覆盖 putVerified 接受/拒绝/已存在短路/byteOrder。PullWorker HTTP 端到端 + 部分 in-memory eager 测试**已知偶发并发 flake**（端口/SQLite 竞争——全集跑挂、单跑必绿），跟 `swift test --filter PullWorker` / `--filter BlobLazyPull` 单独验证
- **依赖**：GRDB 7.10.0 + Hummingbird 2.22.0 + HummingbirdTLS（SwiftPM 远程依赖）
- **下一站**：M4 导出（Markdown/JSON/原始 SQLite）+ UX 打磨（类型/时间筛选 / pinned UI / 快捷键自定义）。详细拆解见 plans/...moonlit-wave.md

## 架构与 Non-Goals

- 拓扑（未来）：家里 Mac mini = 初始 primary；主 Mac / MBP / iOS = 客户端。Primary 不是终身制——任一 mirror client 可 `duo-pasted promote-to-primary` 顶上
- **单一归属**：每条剪贴项归属捕获它的设备（`origin_device`），primary 只做聚合，从根上消除冲突
- **写读分离**：写是多 master（每台设备本地 commit 再异步 push），读由 primary 聚合；mirror 模式让 client 可选周期 pull 全量到 `item_mirror` 表（DR + 离线全集搜索）
- 传输：Tailscale / Surge Ponte 等 P2P 隧道，**不走公网**

**Non-Goals**（被用户明确排除，不要主动建议）：
- iOS 客户端在 M5 前不做
- iCloud 加密备份（用户拒绝）
- 双向同步 / 端到端冲突解决（架构上不需要）
- 自动 leader election / 共识算法（Mac 数量个位数，promote 走手动子命令）

## 部署与运行

### 装 / 卸 LaunchAgent

```sh
./scripts/install-agent.sh    # 幂等：build release + 拷到 ~/Applications + bootstrap
./scripts/uninstall-agent.sh  # 拆掉，不动数据
```

### CLI 子命令（直接调装好的二进制）

```sh
~/Applications/duo-paste/duo-pasted --help                # 子命令列表
~/Applications/duo-paste/duo-pasted init-secret           # 首次部署：生成 32 字节 shared secret
~/Applications/duo-paste/duo-pasted retry-failed          # 把 push_state=failed 全部重置回 pending
~/Applications/duo-paste/duo-pasted audit-push            # 跟 primary /since 对账（仅 client 模式）
~/Applications/duo-paste/duo-pasted promote-to-primary    # 本机从 client 升级为 primary（详 plan §c）
~/Applications/duo-paste/duo-pasted migrate-primary       # 老 primary 上跑 prepare：snapshot + rsync 模板（详 plan §b）
```

无参运行 → 进入 SwiftUI daemon 流程（这是 LaunchAgent 的调用方式）。任何已识别的子命令在 SwiftUI 接管 NSApp 之前 exit。

### 多设备配置（M2）

详细步骤见 `docs/deploy-multi-mac.md`。要点：

`config.json` 不存在 → standalone 模式（= M1，零回归）。要起 multi-Mac：

**Primary（mini）**：

```json
{ "serve": true, "serve_host": "0.0.0.0", "serve_port": 8443 }
```

**Client（主 Mac / MBP）**：

```json
{
  "primary_url": "https://duo-paste-primary.tailXXXX.ts.net:8443",
  "pull": { "enabled": true, "interval_sec": 30, "eager_blobs": false }
}
```

`pull.enabled=true` 才会启动 PullWorker mirror（DR + 离线全集搜索；实现细节见上方"M3 第二刀 完成"段）。`shared-secret` 文件三台机同份（`scp` 过去 + `chmod 600`）。

### 关键路径

数据：

| 内容 | 路径 |
|---|---|
| 主 DB（含 FTS5） | `~/Library/Application Support/duo-paste/db/main.sqlite` |
| 内容寻址 blob | `~/Library/Application Support/duo-paste/blobs/<ab>/<cd>/<sha256>.<ext>` |
| 小时级 snapshot | `~/Library/Application Support/duo-paste/snapshots/duo-paste-YYYYMMDD-HHmmss.sqlite` |
| 本机稳定 UUID | `~/Library/Application Support/duo-paste/device-id` |

部署产物：

| 内容 | 路径 |
|---|---|
| release 二进制 | `~/Applications/duo-paste/duo-pasted` |
| LaunchAgent plist | `~/Library/LaunchAgents/io.duopaste.agent.plist` |
| 日志 | `~/Library/Logs/duo-paste/duo-pasted.{out,err}.log` |

### launchctl 速查

```sh
launchctl print    gui/$UID/io.duopaste.agent      # 状态
launchctl bootout  gui/$UID/io.duopaste.agent      # 停
launchctl kickstart -k gui/$UID/io.duopaste.agent  # 强重启
```

## 开发工作流

LaunchAgent 装好后，主 Mac 常驻 release 版 daemon。调试时不能直接 `swift run`——双进程会**重复捕获、抢全局快捷键、SQLite WAL 多写者竞争**。

1. 改代码 → `swift build && swift test`
2. 重装：`./scripts/install-agent.sh`（脚本幂等）
3. 跑 dev 二进制前先 `launchctl bootout gui/$UID/io.duopaste.agent`，跑完恢复
4. 日志：`tail -f ~/Library/Logs/duo-paste/duo-pasted.err.log`
   - 注意：stderr 里有 "UI ready" / "snapshot ok" / `[HummingbirdCore] Server started` 这种正常诊断输出，不全是错误
5. 如果 bootstrap 报 `5: Input/output error`，sleep 2s 后手动 `launchctl bootstrap ... && launchctl kickstart -k ...`
6. **launchd "languishing" 状态**：短时间内反复 bootout/bootstrap 会触发 launchd 速率限制，`launchctl print` 显示 `state = languishing` + bootstrap 持续报错。等 10-30s 直到 `launchctl print` 返回 `Could not find service`（彻底 boot out 干净）再重新 bootstrap 即可。不要 sudo / 不要改 plist。

## 关键设计决策（不要回退）

### Capture 字节守门（防意外 Cmd+C 巨物）

`config.capture.{max_blob_mb=32, max_text_kb=512}` 默认值。意外复制 4K 长截图 / Cmd+A 大日志 / Figma 多 MB 嵌入资源 → CaptureService 跳过入库，返回 `.skippedTooLarge`，**NSPasteboard 自身不受影响**（用户 Cmd+V 立即正常粘贴）。

文件路径走 `.file` kind + 字符串形式（< 1KB），永远过文本 cap。所以 Finder 复制 50GB 工程文件夹零受影响。

UI 反馈：AppState.recentSkip + SearchView orange skipBanner（含 ✕ 关闭按钮 + 5 分钟自动消失 Task）。文案明确说"剪贴板本身正常可直接 Cmd+V 粘贴"——防止用户以为 daemon 挂了。

**作用域注意**：是 per-device capture policy 不是 sync-wide invariant。Primary `/ingest` `/blob` handler 只校验 body 总上限（1MB / 64MB），不重新校验单字段大小。HMAC + 共享 secret = 已认证内部边界，threat model 允许 trust。所以 A 设备配 max_text_kb=900 推一条 900KB，primary + 其他 client mirror 都接受。这是有意的，不是漏洞。

### Mirror 模式：本地 union 路径优先于远端

PullWorker `lastPullNs` 非 nil（至少完成过一轮 `has_more=false` 追平）→ SearchProvider 直接走 `searchUnion(item + item_mirror)`，**跳过远端**。这是 M3 第二刀的核心收益：client 搜索连过 Tailscale 的 100-200ms 延迟都没有了。

不变量保护：`Tests/DuoPasteSyncTests/SearchTests.swift` 有 `searchProviderSkipsRemoteWhenMirrorActive` —— mock 远端 transport，断言 `callsCount() == 0`。reorder `if let last = mirrorLastPullNs()` 跟 `guard let remote else` 的次序就会红。

跨表 dedupe（同 id 在 item 跟 item_mirror 都有，promote-to-primary 过渡期 / pin 状态分歧时常见）：**先**按 `captured_at_ns` 取最新那份，**后**做 (pinned DESC) 排序——否则旧 mirror 行带 pinned=true 会赢过新 own 行的 unpinned 文本。位置：`Search.swift fetchUnion`。

### 搜索排序契约：pinned > prefix(24h) > time

完整排序：`(pinned DESC, prefix_score DESC, captured_at_ns DESC)`。prefix_score：preview 以 query 起始 = 2 / text_full 起始 = 1 / 否则 0。**仅对 24h 内的项生效**——跨天老内容哪怕起头匹配也走纯时间倒序，剪贴板心智是"搜=找最近用过的"，不希望陈年老条目被翻上来。

SQL 端三处必须对称：`fetchHits` / `fetchHitsMirror` / `fetch`，每处 `instr(LOWER(IFNULL(col, '')), LOWER(?)) = 1` 计算 `_prefix` 列 + `CASE WHEN (CAST(strftime('%s','now') AS INTEGER) * 1e9 - captured_at_ns) < 86400e9 THEN _prefix ELSE 0 END DESC` 包进 ORDER BY。prefix 占位符必须 `args.insert(at: 0)`（SELECT 列表的 `?` 出现在所有 WHERE/LIMIT 占位符之前）。

Swift 端 `fetchUnion.prefixScore` 跟 SQL 端口径**必须**一致——跨表 dedup 后 SQL 算的 `_prefix` 列已丢，重算。回归测试 `SearchPrefixBoostTests.swift` 4 条覆盖：单表 boost / pinned 优先 / 24h 窗外不 boost / union 跨表保留优先级。改动任何一条排序都要先看测试是否仍通过。

### RTF 三层降级 + raw-size 守门

RTF 抓取走三层降级：
1. pasteboard 同时写 `.string` 非空 → 直接用 plain
2. raw RTF 字节 ≤ `maxRawRTFBytes`（= `config.capture.maxTextBytes`，默认 512KB）→ `decodeRTFToPlain` 用 NSAttributedString 解出 plain
3. 解析失败 / 全空白 / raw 超 cap → 兜底存 raw rtf，让 CaptureService 字节守门拦下

`maxRawRTFBytes` guard 是 PR#5 review 要求的修复：watcher 跑在 `@MainActor` 轮询路径上，`NSAttributedString(data:options:[.documentType:.rtf])` 同步解析 50MB markup 会在 UI 线程分配巨型 attributed string；用 raw-size guard 提前跳过 decode，让兜底层走到 CaptureService 字节守门时被拦下（decoded plain ≤ raw RTF，所以这种 case 解出来也大概率仍超 cap，无解码价值）。

**不要回退**：把 `maxRawRTFBytes` 默认调大或去掉 guard 等于让 main actor 在 RTF 路径上裸跑——卡顿出现时极难溯源（轮询每 200ms 一次，单次 spike 会被淹没在 Instruments 噪声里）。

### promote-to-primary 的不变量

`Admin.promoteToPrimary` 把本机从 client 升级到 primary，writer tx 包住步骤 3-7。重要不变量：

1. **`item_mirror` → `item` 用 `INSERT OR IGNORE`，不是 REPLACE**。本机自家 own-origin item 比 mirror 行可信（mirror 是从老 primary 拉的，可能漏更新；自家 own 是源头）。冲突时 own 行赢，mirror 行被丢弃。回归测试 `promoteWithIDConflictSkipsMirrorRow`。
2. **被 promote 进来的 item `push_state` 强制设 'acked'**。`push_state` 是 NOT NULL DEFAULT 'pending' —— 如果不显式设 'acked'，INSERT 进来变成 pending，本机如果之后又被改回 client 模式会让 PushWorker 误推。强制 acked 让这些行从 sync 角度看是"终态"。
3. **改 config 前先 commit DB tx**。Swift 抛出 `Config.write` 失败时 DB 已经 promote 完。这是有意的：DB 状态是事实根（mirror 已经空了，lineage 已经写了），config 写失败的恢复方式是手动改文件让它 match。反过来——先改 config 后改 DB——失败时 daemon 会按新 config 起 server 但 DB 还是 client 状态，更糟。
4. **`primary_lineage` 闭老任期行用 `started_at_ns=0`**，表示"未知何时开始"。audit-push 读全表按区间挑 active primary，闭区间 `[0, ended)` 让该行能覆盖 ended 之前的所有时刻；新 self 任期 `(self, now, NULL)` 覆盖 `[now, ∞)`，两行合起来无缝覆盖全时间轴。PK 是 `(device_id, started_at_ns)`，同一 device 多次任期可记，但 (id, 0) 行不会重复——`INSERT OR IGNORE` 兜底。
5. **`Config.write` 保留未知字段（含嵌套）**。读原 JSON 成 dict 做 base，逐 key 覆盖 cfg 内部字段——**`pull` / `capture` 子 dict 是 merge 而非 replace**（P2 review fix）。这样顶层 + 嵌套层未来加的字段、用户手动加的注解 key 都不丢。回归测试 `promotePreservesUserConfigFields`（顶层）+ `promotePreservesNestedUserConfigFields`（嵌套）。
6. **不主动改 LaunchAgent 但要查它在不在跑**——P1 review fix。CLI 子命令是单次 exit 进程，不应该 bootout/kickstart 自己；但 promote 入口必须查 `launchctl list io.duopaste.agent` 看 PID 字段，daemon 在跑就直接 refuse + 让用户手动 `launchctl bootout` 再重试。**为什么必须停**：promote 跑完后到用户手动 kickstart 之间存在窗口，daemon 仍以 client mode capture 新行（`ingested_at_ns=nil`，stamp 阶段已经过去）。promote 后 PushWorker 不再启动，这些行也不会再被 stamp——永远过滤掉在 `/since` 之外。回归测试 `promoteRefusesWhenDaemonRunning` / `promoteProceedsWhenDaemonNotRunning`。dev 场景 `swift run` 不在 launchctl 管理下，`isRunning=false` 放行——"跑 dev 二进制前先 launchctl bootout" 是用户责任。
7. **必须 stamp `ingested_at_ns IS NULL` 的所有 item 行**——P1 review 修复。`CaptureService` 在 `.client` role 下从不 stamp（line 121-122）：client 行 ACK 后只翻 `push_state`，`ingested_at_ns` 永远 nil。promote 后 `/since` `WHERE ingested_at_ns IS NOT NULL` 会过滤掉这些行，其它 client 拉不到。修：writer tx 内 INSERT mirror→item **之后**扫所有 nil 行，按 `captured_at_ns ASC` 排序后逐行 `Database.nextIngestNs` UPDATE，同步 `push_state='acked'` + attempts/error 清零。覆盖：own-origin 老遗留 + mirror 异常 nil 行（防御）。回归测试 `promoteStampsOwnOriginNullIngestedNs` / `promoteStampsMirrorOriginatedRowsAsLastResort` / `promoteDoesNotReStampAlreadyIngestedRows`。
8. **必须预检 blob 缺失**——P2 review 修复。PullWorker 默认 `eager_blobs=false` 只镜像 blob 元数据；本机变 primary 后 `/blob/<sha>` 找不到字节即 404。promote 入口预扫 item + item_mirror 里 `blob_sha256 IS NOT NULL AND deleted_at_ns IS NULL` 的去重 sha 集合，逐个 `BlobStore.exists`。缺失 + 默认 → throw `AdminError.missingBlobs`，writer tx 不开。`--allow-missing-blobs` flag 让 promote 继续，缺失走 PromoteResult 报告字段 + CLI warning。回归测试 `promoteRefusesWhenBlobsMissingByDefault` / `promoteWithAllowMissingBlobsReportsAndContinues` / `promoteIgnoresMissingBlobOnSoftDeletedRows`（tombstone 不需要字节）/ `promotePassesWhenBlobBytesPresent`。

### migrate-primary 的不变量

`Admin.migratePrimary` 在**老 primary** 上跑 plan §b 的 prepare 阶段。跟 `promoteToPrimary`（计划外抢救）对应，是计划内换 primary 的辅助命令。重要不变量：

1. **命令只读**——除写 snapshot 文件这个副产物外，不动 DB / config / blobs。回归测试 `migrateDoesNotMutateConfigOrMainDB`。这是跟 promote 最大的差异：promote 是事实根重写（DB 状态变了，config 也变），migrate 是"我帮你准备好快照和命令模板，剩下的你跑"。理由跟 promote 不变量 #3 同一脉络：跨机 rsync 涉及 ssh 凭证 / 网络 / 防火墙，封进 Swift 命令容易卡在边界条件上调试困难——打印模板让操作员手跑反而最可控。

2. **daemon 必须停**——同 promote 不变量 #6 用 `LaunchAgent.isRunning` 检测，但理由不同：promote 怕的是 daemon 仍以 client 角色 capture 出 ingested_at_ns=nil 漏 stamp 的行；migrate 怕的是 VACUUM INTO 完之后 daemon 继续 ingest 新行，rsync 完成时新机数据比老机落后，等于静默丢数据。回归测试 `migrateRefusesWhenDaemonRunning` / `migrateProceedsWhenDaemonNotRunning`。

3. **不写 lineage**——MVP 已知缺口。plan §b 原文没要求写。后果：rsync 到新机后，新 primary DB 里没有"新 primary 接管"的 lineage 记录，其它 client 跑 audit-push 时 `activePrimaryDeviceID` 找不到新 primary 任期 → 回退 `origin != self` 启发式。单 primary 部署 audit 不受影响；多次换 primary 链路下可能产生跨任期 dedup 误判。后续若需要可加 `--demote-and-record` flag 在本机写一行 + 让新机 daemon 启动时检测"我是 primary 但 lineage 表里没我"自动补——是新运行时行为，要新增测试。

4. **快照路径复用 `Snapshot.filename`**——文件名 `duo-paste-YYYYMMDD-HHmmss.sqlite`，跟小时级 snapshot 同形态落在 `snapshots/`，享用现有 prune 策略。但 migrate 是手动触发的"迁移用一次性快照"语义不同于小时级备份，文件混在一起后操作员靠时间戳区分。**不**单独再造一个 migrate-snapshots/ 子目录——保持 `Paths` 不变。

5. **blob 校验只统计不算 sha**——递归 walk `blobs/` 算文件数 + 字节数。**不**重算每个 sha256（10 万 blob × 100KB 跑半小时不切实际）。靠 rsync `--checksum` 在传输时校验。如果操作员要"传完后核对"，CLI 输出里有 `blobsTotalFiles` + `blobsTotalBytes` 让新机跑 `find blobs -type f | wc -l` + `du -sb blobs` 自己比。

6. **`walkBlobsDir` 跳过非 regular file** —— BlobStore.put 只写 regular file，但用户可能手动放 symlink / pipe / 目录在 blobs 下。统计只算 regular file 让结果可解释。目录不存在时返回 (0, 0) 不抛错，让命令对"全新 primary 机器没 blobs/"边界鲁棒。回归测试 `migrateHandlesEmptyBlobsDir` / `migrateHandlesMissingBlobsDir`。

### blob 懒拉的不变量

`pull.eager_blobs` 字段（默认 false）+ `AppDelegate.pasteBack` lazy 路径 + `PullWorker.fetchBlobsEager` 三处协同。重要不变量：

1. **content-addressed 接收方必须重算 sha** —— `HTTPIngestClient.getBlob` 200 时本地重算 SHA256 比 path-sha；不匹配抛 `GetBlobError.shaMismatch`。理由：HMAC 签名只保 request 完整性，不保 response body；MITM 或 server bug 给错字节会污染本机 BlobStore。`BlobStore.putVerified` 第二层兜底（lazy / eager 两条路径都调它）。回归测试 `putVerifiedRejectsMismatchedSha` / `httpGetBlobReturnsBytesOn200`（本地校验隐含在通过路径里）

2. **eager 失败不回滚 mirror** —— PullWorker.tick 内 `applyPage` 已经在 writer tx 内 commit mirror 行 + cursor，**之后**才调 `fetchBlobsEager`。eager 失败 only log，不抛、不让整个 tick 标 transient。下次 tick 同样 sha 自然重试（BlobStore.exists short-circuit 让已 mirror 但只缺 blob 的 sha 在每 tick 被重试一次）。回归测试 `eagerBlobsFailureDoesNotRevertMirror`

3. **eager 不拉 tombstone 的 blob** —— `applyPage.mirroredShas` 收集时过滤 `item.deletedAtNs != nil`。primary 上软删行的 blob 通常已被清，拉 404 没意义且污染日志。回归测试 `eagerBlobsSkipsTombstone`

4. **eager 不拉 origin=self 的 blob** —— own-origin 行根本不入 mirror（PullWorker 现有契约），applyPage `for item in page.items { if item.originDevice == device { continue } }` 会让这些 item 不被 INSERT，mirroredShas 收集自然跳过。回归测试 `eagerBlobsSkipsOwnOriginRows`

5. **lazy paste 同步阻塞 panel，不 async 关 panel 后再写 pasteboard** —— `SearchPanelController.installKeyMonitor` 的 Enter case 不再立刻 `self.hide()`；hide 责任移交 onPaste 回调实现方（AppDelegate.pasteBack）。同步路径（非 image / blob 已在）完成后 `panel.hide()`；慢路径起 `currentPasteTask` 完成后再 hide。**不要回退**——async 关 panel + 后台写 pasteboard 会让用户切到目标 app 后 paste 时已脱离原 context，体感"延迟到达"，并且 NSPasteboard 写完不代表内容到位（Cmd+V 时机错位会失败）

6. **panel hide 必须 cancel 进行中的 lazy task**——P1 review fix。`SearchPanelController.init` 接 `onDismiss` callback，`hide()` 调它；AppDelegate 注册 `onDismiss = cancelLazyPasteIfAny`，作用是 `currentPasteTask?.cancel(); currentPasteTask = nil; state.pasteProgress = .idle`。覆盖三条触发：Esc 键 / `windowDidResignKey`（焦点切走）/ 主动 `hide()`。**不要回退**——不 cancel 会让 task 在 panel 关闭后继续把字节写进 NSPasteboard（孤儿写入：用户切到别的 app 莫名得到 paste），`.failed` banner 也会残留到下次 panel 打开

7. **lazy 多次 Enter 自动 cancel 旧 task** —— `AppDelegate.currentPasteTask` 保存上一次 Task，`pasteBack` 调用时 `currentPasteTask?.cancel()` 再起新的。防 "拉一半再按 Enter" 重复 GET 同 sha 竞争 BlobStore.put（put 是原子 rename，重复其实安全；但避免浪费带宽 + 让 UI 状态机简单）

8. **lazy 5s 总超时靠 TaskGroup race，不靠 `Date()` 检查**——P1 review fix。`fetchBlobLazy` 用 `withThrowingTaskGroup` race 两个 task：(a) `fetchBlobLazyInner` 重试循环 `backoffs=[0, 2, 4]` 处理 transient（`.transient` 进入下一轮；`.rejected`/`.shaMismatch`/`.notFound` 立即 fail），(b) `Task.sleep(5s)` 抛 timeout outcome。先完成的赢 + `group.cancelAll()`。**不要回退**——只靠 inner 循环开头 `Date() > deadline` 早退不够：URLSession 单 request 默认 60s timeout，server hang 在 connection 建立但不返回数据时，inner 根本没机会 check Date()；group cancel 让 URLSession 抛 `URLError.cancelled` 立即返回，是唯一能保证 5s 内一定有结果的姿态。`lazyBlobTimeoutSec` 必须 `nonisolated`（sleeper task capture 要求）

9. **`pasteBlobFetcher` 跟 PullWorker / PushWorker 解耦**——P1 review fix。`setupPasteBlobFetcher` 在 `applicationDidFinishLaunching` 跟 `startPullWorker` 平行调用，只依赖 `primary_url + shared-secret 可加载`，**不**依赖 `pull.enabled` / `serve`。理由：用户配了 primary_url 但关掉 `pull.enabled`（不想拉全量元数据、只想 paste 时按需取单个 blob）是合法配置；fetcher 绑在 PullWorker 启动里会让这种配置下 image paste 永远失败

### PullWorker primary 换了的检测

每 tick 第一步 `/health` 拿 `device_id`，跟 `pull_cursor.primary_id` 比。不一致 → `DELETE FROM item_mirror; DELETE FROM pull_cursor` 重拉。这是 plan §c 的 promote-follower 流程兼容性保证。

边界：`/health` 返回 `device_id=""` 当 transient 跳过（不污染 pull_cursor PK）；`now_ms` 解码三种形态都接（String/Int64/Double）—— `SinceClient.HealthResponse`。

### ingested_at_ns 必须在 writer tx 内 stamp

`Database.nextIngestNs(db, now:)` 返回 `max(now, MAX(item.ingested_at_ns)+1)`。**唯一**正确的 stamp 时机是 `pool.write { db in ... }` 闭包内——不能提前到外面算 `now`。

为什么：GRDB DatabasePool 让 reader 并发但 writer 串行。两路并发 `pool.write` 在 writer 队列排队，外面打的 `now` 时间戳跟 commit 顺序可以反过来 → reader 看到 `ns=200` 推进 cursor，之后 `ns=100` 才 commit → `/since` WHERE `ns > 200` 永远漏掉那行 → mirror 漏数据。

调用点：`RemoteIngester.ingest`、`CaptureService.ingestText` / `ingestBlob` 的 primary 路径 + merge 路径。

### NSPasteboard 自写回环——双层防御

剪贴板管理器自己粘回内容会触发自己的监听器看到 changeCount 变化。曾试过"记 `pb.changeCount` 再等值比较"方案，实测**不稳**（写多 type 或写时机微妙错位都会漏）。当前防御：

**写后立刻** `watcher.suppressUpToCurrent()`——把 watcher 内部 `lastChangeCount` 推到当前 `pasteboard.changeCount`，下一 tick 自然 `cc == lastChangeCount` 跳过。位置：`AppDelegate.pasteBack(_:)`。

**不要**重新引入 `lastSelfWriteChangeCount` 静态比较方案。

> 历史：曾有第二层防御——`Watcher.extract()` 顶端 `frontApp.pid == self.pid → return nil`，意在防止"搜索框 Cmd+C 污染历史"。**已撤掉**（2026-05）。撤销原因：用户实际场景里更常想把搜索框里的串作为新剪贴板项入库（剪贴板管理器本质就是"复制就该被记录"）；self-pid 跳过的副作用是把 self frontmost 期间的 changeCount 吃掉但永不补，搜索结果永远 0 条。pasteBack 已经有 suppressUpToCurrent 做隔离，self-pid 过滤是多余且有害的。不要再加回去。

### SwiftUI TextField + 列表导航——NSEvent local monitor

TextField 抢焦点后吞箭头键，父视图的 `.onKeyPress(.upArrow/.downArrow)` 不触发。

当前方案：`SearchPanelController.installKeyMonitor` 在 panel show 时装 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`，按 keyCode（126↑ / 125↓ / 36,76 Return / 53 Esc）拦截后返回 nil 吞掉，路由到 `AppState.navigate(by:)` / `onPaste`。

注意：NSEvent 非 Sendable，进 `MainActor.assumeIsolated` 闭包前先取 `Int(event.keyCode)` 出来再用，否则 Swift 6 严格并发不过。

### onTapGesture(count:1) + (count:2) 的 500ms 延迟

并存让单击必须等"会不会有第二击"消歧 500ms。当前方案：双击挂 `.gesture(TapGesture(count: 2))`，单击挂 `.simultaneousGesture(TapGesture(count: 1))` 跳出消歧立即触发。

### 鼠标点击不触发滚动

`.onChange(of: selectedID) { proxy.scrollTo }` 会让鼠标点击的 selection 变化也强制居中滚。当前方案：`AppState.scrollPulse` 计数器，只在键盘导航时 `&+= 1`；`SearchView .onChange(of: scrollPulse)` 触发 `proxy.scrollTo`。点击只改 `selectedID` 不动 scrollPulse。

### VACUUM INTO 必须 writeWithoutTransaction

GRDB 的 `pool.write { ... }` 自动包事务，SQLite 禁止事务内 VACUUM。要用 `pool.writeWithoutTransaction { ... }`。位置：`Snapshot.takeSnapshot`、`Exporter.writeSQLite`。

### Watcher 自身实现的两个轮询事实

- NSPasteboard 没有 KVO/通知 API，只能 200ms 轮询 `changeCount`
- 类型优先级：`file > image > rtf > html > url > string`（同一次复制同时存在多 type 时取最高优先级）
- concealed/transient 类型直接 skip（密码管理器约定，见 `skipMarkerTypes`）

### HMAC 签名：path-encoded body sha256，middleware 不读 body

签名输入：`<ts_ms>\n<METHOD>\n<path_with_query>\n<sha256_hex(body)>`，hex 在 header `X-DP-Body-SHA256` 里发出。中间件**只**校验 header 上的 hex 跟签名匹配——**不读 body**（让 multi-MB blob 不占中间件内存）。Handler 读完 body 必须**自己**再 sha256 跟 header 对比，否则攻击者可伪造合法签名 + 任意 body。`/ingest` 和 `/blob/{sha}` 的 handler 都做了二次校验；`/blob` 的还多校验 path sha = body sha = header sha 三方一致（content-addressed 契约）。位置：`AuthMiddleware.swift` + `Server.swift` 各 handler。

### Push worker 不能用共享 AsyncStream.Iterator 跨 Task

Swift 6 strict concurrency 拒绝把同一个 iterator 实例 capture 进多个 child task（`group.addTask`）。当前方案：`PushWorker` 持有 `currentSleep: Task<Void, Error>?`，每 tick 起一个新 sleep task，`wake()` nonisolated 调用 actor method 取消这个 task 让 sleep 提前结束。注意 `wake()` 必须 `nonisolated`，否则外部回调拿不到非阻塞接口。位置：`PushWorker.runLoop` / `cancelCurrentSleep`。

### Server 序列化 Item：pinned 必须是 Bool，不能是 0/1

`Item.Codable` 的 `pinned: Bool` 期望 JSON true/false。一开始误用 `pinned ? 1 : 0` 让 client 端 `JSONDecoder().decode(Item.self)` 报 typeMismatch。除此之外 `push_state` / `push_attempts` client 内部字段虽然没语义，但 Item.Codable 标了必填，server 也要原样下发。位置：`Server.itemToJSON`。

### CLI 子命令在 SwiftUI 接管之前 exit

`@main DuoPasteApp.init()` 里第一行调 `CLI.dispatchAndExitIfApplicable()`。命中 `init-secret` / `retry-failed` / `--help` 则跑完直接 `exit(0|1)`，根本不让 SwiftUI 拉起 NSApp。无参 / 未识别参数返回，daemon 流程照常。子命令实现住在 `DuoPasteCore.Admin`（纯函数，便于单测），CLI 只做 argv 解析 + exit。

## 已知环境坑

### SwiftPM 克隆 GRDB.swift 弱网必断

GRDB.swift 仓库 ~200MB / 113k objects，弱网下 `swift package resolve` 会 `curl 18 Transferred a partial file` 死在 ~130MB。

应对（按顺序尝试）：
1. **再试一次**——网络瞬抖大概率过
2. 反复失败走手动 shallow：
   ```sh
   git clone --depth 1 --branch v7.x.y https://github.com/groue/GRDB.swift.git .local-deps/GRDB.swift
   ```
   改 `Package.swift`：`.package(path: ".local-deps/GRDB.swift")`；`.gitignore` 已加 `.local-deps/`
3. **不要**急着换库或自己写 sqlite3 wrapper——曾经想这么做被用户中断
4. **不要**改全局 git config 加 `http.postBuffer`

### Swift Testing 在 macOS 26 SDK 上的"假错"

报错形如：
```
macro expansion @Test:26: error: '@const' value should be initialized with a compile-time value
macro expansion @Test:26: error: global variable must be a compile-time constant to use @section attribute
```

**几乎都是自家代码错误的下游表现**——最常见：**Int64 字面量溢出**（上限 9_223_372_036_854_775_807 ≈ 9.22e18；写 `10_000_000_000_000_000_000` 即超界）。

排查：`swift test 2>&1 | grep -E "error:" | head`，自家错通常排在 @Test 宏错前。修了那个，宏错自动消失。**不要**因此搜 swift-testing issue 或回退 XCTest。

### GRDB 7 在 async 上下文挑 async 重载

在 `async throws` 测试或函数里调 `db.pool.read { ... }` 必须 `try await`。sync 重载在 async 上下文里编译不过（报"is async but is not marked with 'await'"）。

### SwiftPM 6.3 / macOS 26 partial-mirror bug——"no versions match" 假阳性

**症状**：fresh clone 后 `swift build` 报 `Dependencies could not be resolved because no versions of '<pkg>' match the requirement X.Y..<Z`，但：
- `Package.resolved` 锁的版本明明在 GitHub tag 列表里
- `git ls-remote https://github.com/<owner>/<pkg>.git` 直接能列出全部 tags
- 错误一个个轮流冒（修一个又冒下一个）

**根因**：Swift 6.3.1 SPM 在 macOS 26 SDK 上对**某些**依赖创建的 bare mirror 配置不完整。对比同项目里的健康 / 坏 mirror（都在 `./.build/repositories/<pkg>-<hash>/config`，注意是项目本地而**不是** `~/Library/Caches/org.swift.swiftpm/repositories/`——Swift 6.3 把 mirror 路径从全局缓存搬进了 `.build/`，老知识失效）：

```
健康 (e.g. hummingbird):                      坏 (partial):
  repositoryformatversion = 0                   repositoryformatversion = 1
  tagOpt = --no-tags                            tagOpt = --no-tags
  fetch = +refs/*:refs/*    ← 关键              (没有)
  mirror = true             ← 关键              (没有)
→ refs/ 有完整 tag 引用                       → refs/ 空，HEAD = ref: refs/heads/.invalid
                                              → 只拉到 main 分支 HEAD commit
                                              → SPM 字面上看不到任何 tag
```

判别：坏 mirror `git -C <dir> fsck` 会报 `invalid HEAD` + `No default references` + 一个孤儿 commit（就是 main 的 tip）。

**修法**——bulk patch + refetch，不动 `Package.swift` / `Package.resolved` / 全局缓存。直接在项目根目录跑：

```sh
cd .build/repositories
for d in */; do
  grep -q "mirror = true" "$d/config" 2>/dev/null && continue
  git -C "$d" config remote.origin.fetch '+refs/*:refs/*'
  git -C "$d" config remote.origin.mirror true
  git -C "$d" fetch origin --quiet && echo "fixed: ${d%/}"
done
cd ../..
swift build
```

**不要走的歧路**（按出现顺序排，每个都试过无效）：
1. `swift package resolve --force-resolved-versions`——会暴露另一类 mirror 损坏（孤立 tree），但不能修
2. `rm -rf ~/Library/Caches/org.swift.swiftpm/...`——SPM 6.3 mirror 不在那；删了无副作用但也无效
3. `rm -rf ~/Library/Caches/org.swift.swiftpm/manifests/manifest.db*`——manifest cache 重建后结论一样
4. `rm -rf ~/Library/Caches/org.swift.swiftpm/`（整个清）——同 2，方向不对
5. `rm -rf .build` 单独清——SPM 重建出来的还是 partial config，立刻复发
6. 改 `Package.swift` 缩 hummingbird 版本范围——治标且改 lockfile，被项目原则禁止

**SPM 多层缓存的定位顺序**（下次出怪事按这个顺序看）：
1. `./.build/repositories/<pkg>-<hash>/` — bare mirror（**6.3 真的 mirror 数据在这**）
2. `./.build/repositories/<pkg>-<hash>/config` — 看有没有 `mirror = true` / `fetch = +refs/*:refs/*`
3. `./.build/checkouts/<pkg>/` — 解出来的 working copy
4. `~/Library/Caches/org.swift.swiftpm/manifests/manifest.db` — manifest 解析结果 (SQLite)
5. `~/Library/org.swift.swiftpm/configuration/` — registry / mirror override（一般是空）

`.build/repositories/` 里的 fix 不持久——下次 `rm -rf .build` 或 `swift package clean` 后 partial config 会复发。每次都按上面 bulk patch 脚本跑一遍。

## 构建 / 测试速查

```sh
swift build              # debug
swift test               # 175/175（PullWorker HTTP 偶发 flake，单跑 --filter PullWorker 必绿）
swift build -c release   # release（install 脚本自动跑）
```

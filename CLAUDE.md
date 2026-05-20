- **同步路径**：每个 peer 一对 `(PullWorker, WSNotificationClient)`。PullWorker 周期 `/since` 拉对端增量到本机 item 表（origin=对端 device_id）；WSNotificationClient 长连接订阅对端 `/sync/ws` cursor_advanced 帧 → 收到立即 `worker.wake()` 跳过 sleep（< 1s 同步延迟）。WS 断了自然退化为周期 pull
- **HTTP routes**：`GET /health` + `GET /blob/<sha>` + `GET /since` + `GET /sync/ws`（HTTP Upgrade）+ `GET /app_icon/<bundleID>` + `POST /bump/<id>`（plan #2，跨设备一致"复制即顶"：iOS tap → Mac DB bump captured/ingested_at_ns → broadcaster fan-out → 其他 peer 通过 PullWorker 看到）。`POST /ingest` + `PUT/HEAD /blob` + `GET /search` 都已删（PR 4 + PR 6）
- **CaptureService**：永远走 `Database.nextIngestNs` stamp（writer tx 内）；merge candidate 查询带 `origin_device == selfDeviceID` 过滤防 bump 对端行；commit 后回调 `onCursorAdvanced` 闭包让 server 端 `WSBroadcaster` fan-out
- **Search**：单一 fold-aware 路径——`SearchAPI.searchHits / count / countByKind` 内部 oversample → text-fold（跨 origin 同 text_full 折一条，pinned OR 聚合）→ kinds/pinnedOnly 后置过滤 → 排序契约 `(pinned DESC, prefix24h DESC, captured_at_ns DESC)` → LIMIT/OFFSET。**list / total / chip 三者口径一致**是硬不变量
- **SearchProvider.Mode**：仅 `.local` / `.mesh(stalenessSec:)`，删 `.remoteOK / .remoteFallback / .localMirror`。永远走本机 fold 不打远端，跨设备 chip 总数自动对齐
- **跨设备 dedup**：两层防御。capture 层（同 origin 同 text 永久合并，merge candidate 加 origin 过滤）+ search fold 层（跨 origin 兜底）。Continuity / ToDesk 副本通过 PullWorker `crossDeviceDedupWindowNs` (5s) + PasteSuppressionSet 拦
- **Blob**：内容寻址 BlobStore（put / putVerified 用 linkItem 而非 moveItem——POSIX rename atomic-replace 会让竞态丢方误计 stats，详 §"BlobStore 内容寻址不变量"）；lazy paste-back（按需从 peer GET `/blob/<sha>`，TaskGroup 30s 超时 race——见下方 §"blob 懒拉的不变量" #8）；可选 eager (`mesh.eager_blobs=true`) PullWorker 拉完元数据顺路拉字节
- **HMAC 认证**：`<ts>\n<METHOD>\n<path>\n<body_sha256_hex>` 签名。HTTP middleware 不读 body（让多 MB blob 不占内存），handler 自己读 body 后再算 sha256 比对 header。WS upgrade 用相同模板（empty body hash），upgrade 后 frame 不签
- **OCR**：Phase 1 + Phase 2 都已落地。Phase 1 = 本机 own-origin image 跑 Vision OCR 写 `text_full` 进 FTS5；Phase 2 = OCR markDone 触发 onCursorAdvanced 让对端 < 1s 同步 OCR 结果（共享 wsBroadcaster fan-out 路径），peer FTS5 trigger 自动重 index 让对端搜索可命中
- **mesh-doctor CLI**：探每 peer /health (deviceID + skewMs + 跟 expected 是否匹配) + 本机 pull_cursor 行 + 本机 max(ingested_at_ns) + missing blob 统计。只读不动 DB / config。退出码 0=都健康；任一 peer unreachable / device_id 不匹配 / blob 缺失 → 1
- **WS auth rotation**：`mesh.ws_rotation_sec`（默 4h，0 = 关）控制 WSBroadcaster 每周期主动 close 所有连接。合法 client 走 backoff 重连 + 重 HMAC upgrade（用最新 secret），shared-secret 被窃取后能监听窗口压到 ≤ 这个值
- **依赖**：GRDB 7.10.0 + Hummingbird 2.22.0 + HummingbirdTLS + hummingbird-websocket 2.6.0
- **测试**：~270 个，PullWorker / BlobLazyPull 集成测试**已知偶发并发 flake**（端口/SQLite 竞争——全集跑挂、单跑必绿），用 `swift test --filter PullWorkerTests` / `--filter BlobLazyPullTests` 单独验证
- **iOS 端**（M5）：
  - **WS zombie 检测**：iOS URLSessionWebSocketTask 没协议层 PING 路径，走应用层 `WSMessage.ping/.pong` 心跳——`PeerWebSocket.pingLoop` 每 30s 发 ping，10s 内没 pong → 抛 `WSError.pongTimeout` 触发重连。`PeerSyncCoordinator` 加 5s tick + 90s heartbeat staleness 兜底降级到 `.error("链路无响应")`
  - **POST /bump 客户端**：`HistoryCellView.triggerCopy` 先 `store.bumpToFront` 乐观顶 + UCB 写 pasteboard，**再** `coordinator.bumpItemOnServer` async 让 Mac DB 也顶。404/410 swallow，best-effort 跨设备一致
  - **Bonjour 发现 + QR 配对**：Mac daemon `BonjourAdvertiser` 用 NetService publish `_duopaste._tcp` (NWListener 强制绑端口、SyncServer 已占，所以走 NetService) + Settings 显示二维码（60s 倒计时，QR 含 url + secret hex）；iOS `PeerDiscovery` NWBrowser + `QRScannerView` AVCaptureSession 扫码自动填字段。Info.plist 需配 `NSBonjourServices=_duopaste._tcp` / `NSCameraUsageDescription` / `NSLocalNetworkUsageDescription`
  - **BlobCache 磁盘 + LRU**：`Caches/Blobs/v1/<ab>/<cd>/<sha>.bin` 三层目录持久化跨启动。500MB cap 按 mtime 升序 evict。Detached IO 避免大图同步读卡 main actor
  - **后台 pull**：`BackgroundPullService` 用 BGAppRefreshTask（identifier `io.duopaste.ios.background-pull`，Info.plist `BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes=fetch`），系统 best-effort 唤醒拉 /since 几页 + 持久化到 `Caches/HistoryStore/items.json`。app `scenePhase=.active` 时 merge 磁盘内容到 store。WS 后台不能跑（iOS 限制），降级周期 HTTP pull
- **下一站**（plan 之外可选）：M4 导出 / pinned UI / 快捷键自定义 / 自定义时间 picker

## 架构与 Non-Goals

- **拓扑**：每台 Mac 是平等 peer（mini + MBP 双向）。没有 primary，没有 promote。`mesh-init` CLI 配双向 peer URL，daemon 启动时为每个 peer 起一对 `(PullWorker, WSNotificationClient)`
- **单一归属**：每条剪贴项归属捕获它的设备（`origin_device`），跨设备 dedup 在 PullWorker / search fold 兜底
- **同步对称**：peer A 通过 `/since` 从 peer B 拉数据，反过来同时也跑（双向 mesh）。WS 通知层让推送延迟 < 1s
- 传输：Tailscale 网络，**不走公网**

**Non-Goals**（被用户明确排除，不要主动建议）：
- iOS 客户端在 M5 前不做
- iCloud 加密备份（用户拒绝）
- 双向同步冲突解决（mesh 拓扑下 own/peer 单一归属，无需冲突解决）
- 自动 leader election / 共识算法（mesh 拓扑没 leader 概念）

## 部署与运行

### 装 / 卸 LaunchAgent

```sh
./scripts/install-agent.sh    # 幂等：build release + 拷到 ~/Applications + bootstrap
./scripts/uninstall-agent.sh  # 拆掉，不动数据
```

### CLI 子命令（直接调装好的二进制）

```sh
~/Applications/duo-paste/duo-pasted --help                  # 子命令列表
~/Applications/duo-paste/duo-pasted init-secret             # 首次部署：生成 32 字节 shared secret
~/Applications/duo-paste/duo-pasted mesh-init --peer URL... # 切到 mesh 拓扑：写 peers/mesh config，删老 primary_url/pull
~/Applications/duo-paste/duo-pasted mesh-doctor             # 探所有 peer /health + cursor 对账 + missing blob 统计（只读）
~/Applications/duo-paste/duo-pasted retry-failed-ocr        # 把 OCR failed/skipped 行翻回 pending
```

无参运行 → 进入 SwiftUI daemon 流程（这是 LaunchAgent 的调用方式）。任何已识别的子命令在 SwiftUI 接管 NSApp 之前 exit。

### 多设备配置（mesh）

`config.json` 不存在 → standalone 模式（peers 空 + serve=false，零回归）。要起 mesh：

**两台都跑 `mesh-init`**（先 `launchctl bootout` 停 daemon，否则 mesh-init 拒）：

```sh
# Mini 上：peer = MBP，启 TLS
~/Applications/duo-paste/duo-pasted mesh-init \
    --peer https://bobbys-macbook-pro.tail69730a.ts.net:8443 \
    --serve-host 0.0.0.0 --serve-port 8443 \
    --serve-tls \
    --tls-cert ~/Library/Application\ Support/duo-paste/tls/bobbys-mac-mini.tail69730a.ts.net.crt \
    --tls-key  ~/Library/Application\ Support/duo-paste/tls/bobbys-mac-mini.tail69730a.ts.net.key

# MBP 上：peer = mini，启 TLS（cert 路径换成本机）
~/Applications/duo-paste/duo-pasted mesh-init \
    --peer https://bobbys-mac-mini.tail69730a.ts.net:8443 \
    --serve-host 0.0.0.0 --serve-port 8443 \
    --serve-tls \
    --tls-cert ~/Library/Application\ Support/duo-paste/tls/bobbys-macbook-pro.tail69730a.ts.net.crt \
    --tls-key  ~/Library/Application\ Support/duo-paste/tls/bobbys-macbook-pro.tail69730a.ts.net.key
```

写好的 config 形如：

```json
{
  "serve": true, "serve_host": "0.0.0.0", "serve_port": 8443,
  "serve_tls": true, "tls_cert_path": "...", "tls_key_path": "...",
  "peers": [{ "url": "https://<peer-host>:8443" }],
  "mesh": { "enabled": true, "pull_interval_sec": 30, "ws_enabled": true, ... }
}
```

要点：
- TLS cert 一对从 `tailscale cert <hostname>` 拿。两端 scheme 必须对齐——一端 https 一端 http 会让 ws-client TLS 握手 EOF
- `shared-secret` 文件两台同份（`scp` 过去 + `chmod 600`）
- 两端 peer URL 互指（A 的 config peer = B URL，B 的 config peer = A URL）。两端 daemon 都跑 `serve` + 跑 PullWorker
- `mesh-init` 会预检 blob 缺失（image/file 行 sha 不在本机 BlobStore 上），默认拒；`--allow-missing-blobs` 跳过。完成后手动 `launchctl bootstrap + kickstart` 拉起 daemon

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
| release bundle | `~/Applications/DuoPaste.app` |
| release 二进制 | `~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted` |
| LaunchAgent plist | `~/Library/LaunchAgents/io.duopaste.agent.plist` |
| 日志 | `~/Library/Logs/duo-paste/duo-pasted.{out,err}.log` |

签名:Developer ID Application: BO LI (`RS59HDH7Y3`) + hardened runtime。Bundle ID = `io.duopaste.daemon`。macOS TCC 按 Team ID + Bundle ID 判 Accessibility 权限保留——`install-agent.sh` 重装时 cdhash 变但 DR 不变,权限自动跟 app 走。**禁止回退 adhoc 签名**:adhoc 让 Accessibility 列表里旧 cdhash 失效,每次 install 都得重勾,体验崩盘

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

### SearchProvider 永远走本机 fold-aware（chip 总数对齐）

`SearchProvider.search` 永远走 `SearchAPI.searchHits / count / countByKind` —— 内部 fold-aware（跨 origin 同 text_full 折一条），不再有"raw count vs fold count"双路径。

**核心不变量**：mesh 拓扑下 `item` 表混存本机 own + 对端 peer 行，跨 origin 同 text 是常态。raw count（`COUNT(*) FROM item`）会把每个 ToDesk/Continuity 副本算一遍，跟对端口径不齐——这是 PR 6 之前 chip 总数差 ~265 条的根因。

PR 6 之前的 `SearchProvider.Mode` 有 `.local / .localMirror / .remoteOK / .remoteFallback` 四种，按"是否有 PullWorker (mirrorLastPullNs 非 nil)"决定走 raw 还是 fold。新代码只剩 `.local / .mesh(stalenessSec:)` 两种，count 永远 fold——对端 chip 数自动对齐到 1 条 race 范围内。

回归测试 `searchProviderTotalCountMatchesFoldedRowCount` 钉死路径正确：own + peer 同 text 必须 fold 成 1 条。

### 搜索排序契约：pinned > prefix(24h) > time

完整排序：`(pinned DESC, prefix_score DESC, captured_at_ns DESC)`。prefix_score：preview 以 query 起始 = 2 / text_full 起始 = 1 / 否则 0。**仅对 24h 内的项生效**——跨天老内容哪怕起头匹配也走纯时间倒序，剪贴板心智是"搜=找最近用过的"，不希望陈年老条目被翻上来。

SQL 端 `fetchHitsRaw` 内 `instr(LOWER(IFNULL(col, '')), LOWER(?)) = 1` 计算 `_prefix` 列 + `CASE WHEN (CAST(strftime('%s','now') AS INTEGER) * 1000000000 - captured_at_ns) < 86400000000000 THEN _prefix ELSE 0 END DESC` 包进 ORDER BY。prefix 占位符必须 `args.insert(at: 0)`（SELECT 列表的 `?` 出现在所有 WHERE/LIMIT 占位符之前）。

Swift 端 `fetchHitsFolded.prefixScore` 跟 SQL 端口径**必须**一致——fold 后 SQL 算的 `_prefix` 列已丢，重算。回归测试 `SearchPrefixBoostTests.swift` 4 条覆盖：单表 boost / pinned 优先 / 24h 窗外不 boost / fold 后保留优先级。

### 文本永久 dedup（capture + search 双层）

文本 kind（`text/url/file`，即 `blob_sha256 IS NULL`）走永久 dedup，跟 blob 路径独立：

1. **Capture 层**（`CaptureService.ingestText`）：`config.capture.text_merge_window_sec` 默认 `null` = 永久。同 kind + 同 `text_full` + 未删 + **同 origin** 行无论何时再次 capture，都合并 bump `captured_at_ns` + `ingested_at_ns` 让对端 peer 通过 /since 看到刷新。**merge candidate 必须加 origin_device 过滤**——合表后 item 表含 peer 行，不加过滤会 bump 对端行（等于本机改了别人数据）。设 `0` 完全禁用，设 `N>0` 退化到固定窗口。`blob mergeWindowSec` 独立保留 300s
2. **搜索层**（`Search.fetchHitsFolded`）：oversample 后按 `text_full` 跨 origin fold。Winner = `max(capturedAtNs)`，**pinned 通过 OR 聚合**（任一条 pinned → fold 结果 pinned=true，pin 是对内容的属性而非具体 row）。`count` / `countByKind` 走同源 fold 路径，保证 list / total / chip 三者口径一致

为什么要两层：
- 单 Capture 层不够 —— ToDesk / Continuity 把 mini pasteboard 同步到 MBP，两台 watcher 各自抓到一条 own-origin 行（不同 id 不同 origin_device），mini 行通过 PullWorker 进 MBP 的 item 表（origin=mini），搜索时跨 origin 同 text 仍要 fold
- 单 fold 层不够 —— 同设备短时间内重复 copy 仍会插多行，存储白浪费；capture 层 dedup 让 DB 干净

**不要回退到固定窗口默认值**：5 分钟窗口在 ToDesk 同步场景下两端时间错位常超窗，回退会再现"同文本并排两条"的 UI 问题。

### `preview` vs `text_full` 字段语义：UI 必须读 textFull

`item.preview` 字段是 `CaptureService.makePreview` 截到 **280 字符 + `…`** 的网络传输短预览，**给 server→client `/since` 列表渲染省 payload 用**。`item.text_full` 是原始可粘贴文本完整内容（受 `config.capture.max_text_kb` 字节守门，默认 512KB）。两个字段在 server 端**同时**写入 DB，client 通过 `/since` JSON 也**同时**收到（`Server.itemToJSON` 直传无截断）。

**UI 端必须用 textFull,不能用 preview**——daemon SearchView 跟 SQLite 同进程,iOS 通过 /since 也拿到完整 textFull,直接 fallback 到截过的 preview 会让卡片末尾出现 server 加的 `…` 截断符,且文本短于 lineLimit 时填不满 frame 留大块空白(2026-05-20 已踩过)。

**统一入口**：`Item.cardPreviewSource(maxChars:)` (Sources/DuoPasteCore/Item.swift) —— textFull 优先 + `prefix(maxChars)` 防御性截断。`maxChars` 给 SwiftUI lineLimit + frame 物理约束**之外**的兜底:macOS 卡片 240×204 ≈ 11 行 × 15 字符 = 165 字符,默认 512 给 3 倍缓冲;iOS HistoryCellView lineLimit(5) ≈ 95 字符,传 300。

**规则范围 = 卡片/列表 cell 展示路径**。其它路径（详情大预览、导出 SQLite/Markdown、open-with 临时文件、paste-merge 文本比较、本地 contains 过滤等）**允许**用 `item.textFull ?? item.preview` 形态——这些是 textFull 优先 + preview 兜底的合法 fallback,**不算违反**。

受规则约束的卡片/列表展示调用点(不要再添加新的 `item.preview ??` fallback)：
- `Sources/duo-pasted/SearchView.swift` 的 `previewAttributedForTextCard` else 分支(snippet 不空时另有 FTS 高亮路径)
- `Sources/duo-pasted/SearchView.swift` 的 `previewText` else 分支(file kind 文件名解析路径不走这条)
- `iOS/DuoPaste/Models.swift` 的 `displayPreview`

**已知边界 · iOS cold-launch 老 cache**：`BackgroundPullService` 把 item 持久化到 `Caches/HistoryStore/items.json`,app 升级后 cold-launch 读老 cache 项可能 textFull 为 nil → cardPreviewSource 退到 preview → 卡片仍带 server `…` 截断符,直到下一次 PullWorker 拉到新 item 完整 textFull 覆盖才修复。这是已知边界不修——加 cache schema version invalidate 老 entries 代价高于收益。

**多段 textFull paragraphStyle 精细应用**：`previewAttributedForTextCard` 的 `firstLineHeadIndent=8` (避开左上 app icon) **必须只应用到第一个 paragraph**——NSAttributedString.firstLineHeadIndent 是 per-paragraph,整段统一设会让多段 textFull 每段首行 indent 8pt 视觉错位。代码里两个 paragraphStyle (pIndent / pPlain) + 按 `\n` 分隔的 range 精细 addAttribute,**不要回退到单一 paragraphStyle 全 range 应用**。

**回归测试**：`Tests/DuoPasteCoreTests/CardPreviewSourceTests.swift` —— textFull 优先 / textFull 缺失退 preview / 都空返回空串 / maxChars 截断 / preview 路径无视 maxChars 五条契约。任一 PR 把 `cardPreviewSource()` 改回 `item.preview ??` 会让这些测试 fail。

**为什么不在 `Item.preview` getter 里直接返回 textFull**：preview 字段还要喂给 FTS5 索引、`/since` JSON wire（让老 iOS 客户端没 textFull 也能展示）、搜索 prefix-boost 排序（`SearchPrefixBoostTests` 里 `pv.lowercased().hasPrefix(needle)` 算 score=2）等数据路径,这些都该保留**网络短预览**语义。坑只在 UI 卡片消费端。

### RTF 三层降级 + raw-size 守门

RTF 抓取走三层降级：
1. pasteboard 同时写 `.string` 非空 → 直接用 plain
2. raw RTF 字节 ≤ `maxRawRTFBytes`（= `config.capture.maxTextBytes`，默认 512KB）→ `decodeRTFToPlain` 用 NSAttributedString 解出 plain
3. 解析失败 / 全空白 / raw 超 cap → 兜底存 raw rtf，让 CaptureService 字节守门拦下

`maxRawRTFBytes` guard 是 PR#5 review 要求的修复：watcher 跑在 `@MainActor` 轮询路径上，`NSAttributedString(data:options:[.documentType:.rtf])` 同步解析 50MB markup 会在 UI 线程分配巨型 attributed string；用 raw-size guard 提前跳过 decode，让兜底层走到 CaptureService 字节守门时被拦下（decoded plain ≤ raw RTF，所以这种 case 解出来也大概率仍超 cap，无解码价值）。

**不要回退**：把 `maxRawRTFBytes` 默认调大或去掉 guard 等于让 main actor 在 RTF 路径上裸跑——卡顿出现时极难溯源（轮询每 200ms 一次，单次 spike 会被淹没在 Instruments 噪声里）。

### mesh-init 的不变量

`Admin.meshInit` 把本机切到 mesh schema：写 `peers/mesh` config + 删老 `primary_url/pull` 字段。重要不变量：

1. **不动 DB**：本机 item 表里可能有老 push 链路 / 老 PullWorker 留下来的对端行，让 daemon 启动后 PullWorker 自己的 reconcilePeer 流程清理（peer device_id 不匹配时清行 + cursor）。PR 1 v7 migration 已合表，PR 4 v8 已 DROP push_*；不需要再开 tx
2. **daemon 必须停**——`LaunchAgent.isRunning` 检测在跑直接 throw。理由：mesh-init 改 config 期间 daemon 仍以老 config 跑可能 capture 行 + 启 PullWorker 抢锁
3. **预检 blob 缺失**：扫 item 表 blob_sha256 非空 + image/file + 未删的去重 sha，逐个 `BlobStore.exists`。缺失 + 默认 → throw `missingBlobs`；`--allow-missing-blobs` 跳过；tombstone (deleted_at_ns 非空) 不计
4. **`Config.write` 显式 removeValue 老字段**：`primary_url` / `pull` 在新写入路径里删掉，避免 daemon 读 config 时两套字段共存让用户困惑
5. **TLS 字段一致性**：`mesh-init --serve-tls` 必须配 `--tls-cert/--tls-key`（或 oldConfig 已经有）+ 文件存在性预检。两端 peer URL scheme 必须对齐——一端 https 一端 http 会让 ws-client TLS 握手 EOF（用户曾踩过）。回归测试 `meshInitRefusesServeTLSWithoutCertAndKey` / `meshInitRefusesServeTLSWhenCertFileMissing` / `meshInitInheritsTLSFromOldConfigWhenNotGiven`
6. **不主动改 LaunchAgent**——CLI 子命令是单次 exit 进程，不应该 bootout/kickstart 自己；mesh-init 完成后打印 kickstart 提示让用户手动重启 daemon
7. **保留无关字段**——hotkey / capture / ocr / shared_secret_keychain_account 等不动。Config.write 走 nested merge 路径让用户手动加的未知字段也保留。回归测试 `meshInitPreservesUnrelatedConfigFields`

### blob 懒拉的不变量

`mesh.eager_blobs` 字段（默认 false）+ `AppDelegate.pasteBack` lazy 路径 + `PullWorker.fetchBlobsEager` 三处协同。重要不变量：

1. **content-addressed 接收方必须重算 sha** —— `HTTPIngestClient.getBlob` 200 时本地重算 SHA256 比 path-sha；不匹配抛 `GetBlobError.shaMismatch`。理由：HMAC 签名只保 request 完整性，不保 response body；MITM 或 server bug 给错字节会污染本机 BlobStore。`BlobStore.putVerified` 第二层兜底（lazy / eager 两条路径都调它）。回归测试 `putVerifiedRejectsMismatchedSha` / `httpGetBlobReturnsBytesOn200`（本地校验隐含在通过路径里）

2. **eager 失败不回滚 mirror** —— PullWorker.tick 内 `applyPage` 已经在 writer tx 内 commit mirror 行 + cursor，**之后**才调 `fetchBlobsEager`。eager 失败 only log，不抛、不让整个 tick 标 transient。下次 tick 同样 sha 自然重试（BlobStore.exists short-circuit 让已 mirror 但只缺 blob 的 sha 在每 tick 被重试一次）。回归测试 `eagerBlobsFailureDoesNotRevertMirror`

3. **eager 不拉 tombstone 的 blob** —— `applyPage.mirroredShas` 收集时过滤 `item.deletedAtNs != nil`。primary 上软删行的 blob 通常已被清，拉 404 没意义且污染日志。回归测试 `eagerBlobsSkipsTombstone`

4. **eager 不拉 origin=self 的 blob** —— own-origin 行根本不入 mirror（PullWorker 现有契约），applyPage `for item in page.items { if item.originDevice == device { continue } }` 会让这些 item 不被 INSERT，mirroredShas 收集自然跳过。回归测试 `eagerBlobsSkipsOwnOriginRows`

5. **lazy paste 同步阻塞 panel，不 async 关 panel 后再写 pasteboard** —— `SearchPanelController.installKeyMonitor` 的 Enter case 不再立刻 `self.hide()`；hide 责任移交 onPaste 回调实现方（AppDelegate.pasteBack）。同步路径（非 image / blob 已在）完成后 `panel.hide()`；慢路径起 `currentPasteTask` 完成后再 hide。**不要回退**——async 关 panel + 后台写 pasteboard 会让用户切到目标 app 后 paste 时已脱离原 context，体感"延迟到达"，并且 NSPasteboard 写完不代表内容到位（Cmd+V 时机错位会失败）

6. **panel hide 必须 cancel 进行中的 lazy task**——P1 review fix。`SearchPanelController.init` 接 `onDismiss` callback，`hide()` 调它；AppDelegate 注册 `onDismiss = cancelLazyPasteIfAny`，作用是 `currentPasteTask?.cancel(); currentPasteTask = nil; state.pasteProgress = .idle`。覆盖三条触发：Esc 键 / `windowDidResignKey`（焦点切走）/ 主动 `hide()`。**不要回退**——不 cancel 会让 task 在 panel 关闭后继续把字节写进 NSPasteboard（孤儿写入：用户切到别的 app 莫名得到 paste），`.failed` banner 也会残留到下次 panel 打开

7. **lazy 多次 Enter 自动 cancel 旧 task** —— `AppDelegate.currentPasteTask` 保存上一次 Task，`pasteBack` 调用时 `currentPasteTask?.cancel()` 再起新的。防 "拉一半再按 Enter" 重复 GET 同 sha 竞争 BlobStore.put（put 是原子 rename，重复其实安全；但避免浪费带宽 + 让 UI 状态机简单）

8. **lazy 30s 总超时靠 TaskGroup race，不靠 `Date()` 检查**——P1 review fix（5s → 30s，DERP 中继 TLS 握手 3s+ 经常超时）。`fetchBlobLazy` 用 `withThrowingTaskGroup` race 两个 task：(a) `fetchBlobLazyInner` 重试循环 `backoffs=[0, 2, 4]` 处理 transient（`.transient` 进入下一轮；`.rejected`/`.shaMismatch`/`.notFound` 立即 fail），(b) `Task.sleep(lazyBlobTimeoutSec)` 抛 timeout outcome。先完成的赢 + `group.cancelAll()`。**不要回退**——只靠 inner 循环开头 `Date() > deadline` 早退不够：URLSession 单 request 默认 60s timeout，server hang 在 connection 建立但不返回数据时，inner 根本没机会 check Date()；group cancel 让 URLSession 抛 `URLError.cancelled` 立即返回，是唯一能保证总超时内一定有结果的姿态。`lazyBlobTimeoutSec` 必须 `nonisolated`（sleeper task capture 要求）

    **配合修复**：30s 超时窗口下"panel.hide → blob 拉到 → 写入 NSPasteboard"的孤儿写入窗口被放大 6 倍；`SearchPanelController.hide` 必须**同步**先调 `onDismiss()`（cancel `currentPasteTask` + 清 preview），再走 140ms 视觉收场动画。旧实现把 cancel 塞进动画 completion 里在 140ms 后才 fire——配合 30s timeout 让用户切到目标 app 后莫名收到 paste。**不要回退**：hide 入口同步 cancel 是硬不变量

9. **`pasteBlobFetcher` 跟 PullWorker 解耦**。`setupPasteBlobFetcher` 在 `applicationDidFinishLaunching` 跟 `startMeshSupervisor` 平行调用，只依赖 `peers[0] + shared-secret 可加载`，**不**依赖 `mesh.enabled` / `serve`。理由：用户配了 peers 但关掉 `mesh.enabled`（不想周期 pull、只想 paste 时按需取单个 blob）是合法配置；fetcher 绑在 PullWorker 启动里会让这种配置下 image paste 永远失败

### BlobStore 并发竞态：linkItem 取代 moveItem

`BlobStore.put` / `putVerified` 共享 `writeBlob` 唯一实现：先 stage 写 tmp，再 `linkItem(at: tmp, to: target)`（hard link），失败若 target 已存在 → wasExisting=true + **不**调 `notifyAdded`。`defer { removeItem(tmp) }` 保证 tmp 总被清。

**不要回退到 moveItem**：`FileManager.moveItem` 走 POSIX `rename(2)` —— atomic replace，dst 已存在时**不报错而是覆盖**。竞态丢方根本进不了 catch 分支，原 catch 内的 "wasExisting + notifyAdded" 误判让 BlobStorageStats 重复计字节、UI 仓库占用虚增。`linkItem` 走 `link(2)`，dst 存在必定 EEXIST，才是真正的 exclusive create。

回归测试：`concurrentPutSameShaCountsOnceInStats`（16 并发 put 同 sha 字节只算一份）。位置：`BlobStore.swift` + `BlobStoreTests.swift`。

### WSNotificationClient 长连接成功 reset failureCounter

`Config.longLivedConnectionThresholdSec`（默 30s）划分"短闪连失败"vs"长连接合法关"。`setConnected(true)` 记 `currentConnectionStartedAt`；`setConnected(false)` 算 elapsed，达阈值置 `longConnectionThisRound`。runLoop 跑完 `connectOnce` 后 `consume` flag——长连接路径 reset `consecutiveFailures = 0`，短闪连走原有 `+=1` + 指数 backoff。

**不要回退到无条件 +1**：旧实现配合 WSBroadcaster `mesh.ws_rotation_sec`（默 4h）主动 close 所有连接，约 60h 后所有合法长连接客户端 consecutiveFailures 累到 budget=15，触发 catastrophic `exit(1)`，launchd 重启——每隔几天来一次 daemon 重启而没人知道为啥。

回归测试：`longLivedConnectionResetsFailureCounter`。位置：`WSNotificationClient.swift`。

### /pair TLS-only 护栏

`SyncServer.requirePairingTLS`（默 true）+ `tls == nil` 时 `/pair/<pin>` handler 在 PIN 校验**之前**返 503。daemon 启动期若不满足条件且 `pairingService != nil`，stderr 立刻打 WARN 让运维侧能看到。测试用 `requirePairingTLS: false` 显式 opt-out。

**为什么硬护栏**：`/pair` response body 含 `secret: hex` 明文（iOS 用作 HMAC 主密钥）。Tailscale 路径下 WG 加密兜底 OK，但 iOS 配对常走 `.local` / 直连 IP——不进 tailnet，secret 明文暴露给 LAN 中间人。PIN 单次 + 5 次封锁挡不住"监听一次成功配对"。

**不要回退**：未来若 daemon 跑 plain HTTP（罕见），必须升级到 TLS 才能用 iOS 配对，不是放宽这条护栏。回归测试：`pairReturns503WhenTLSRequiredButMissing`。位置：`Server.swift` + `PairHTTPTests.swift`。

### PullWorker peer 换了的检测（reconcilePeer）

每 tick 第一步 `/health` 拿 `device_id`，跟 `pull_cursor.peer_device_id` 比。不一致 → 精确清该 peer 的旧 origin 行 + 该 peer cursor 行（不动其他 peer 的行 / 自家 own 行）。

**严格模式 vs 学习模式**：
- `expectedPeerDeviceID` 非 nil（mesh-init 时显式给 deviceID）→ 严格模式。/health 返回的 device_id 跟 expected 不一致立即 transient skip 不污染 DB
- `expectedPeerDeviceID` nil（mesh-init 没给 / 学习模式）→ 首次 /health 拿到 device_id 后 stamp 进 pull_cursor。学习模式只能用于单 peer 部署（多 peer LIMIT 1 不可靠）

边界：`/health` 返回 `device_id=""` 当 transient 跳过（不污染 pull_cursor PK）；`now_ms` 解码三种形态都接（String/Int64/Double）—— `SinceClient.HealthResponse`。

### ingested_at_ns 必须在 writer tx 内 stamp

`Database.nextIngestNs(db, now:)` 返回 `max(now, MAX(item.ingested_at_ns)+1)`。**唯一**正确的 stamp 时机是 `pool.write { db in ... }` 闭包内——不能提前到外面算 `now`。

为什么：GRDB DatabasePool 让 reader 并发但 writer 串行。两路并发 `pool.write` 在 writer 队列排队，外面打的 `now` 时间戳跟 commit 顺序可以反过来 → reader 看到 `ns=200` 推进 cursor，之后 `ns=100` 才 commit → `/since` WHERE `ns > 200` 永远漏掉那行 → 对端漏数据。

调用点：`CaptureService.ingestText` / `ingestBlob` 的 insert + merge 路径，`PullWorker.applyPage`。

### NSPasteboard 自写回环——双层防御

剪贴板管理器自己粘回内容会触发自己的监听器看到 changeCount 变化。曾试过"记 `pb.changeCount` 再等值比较"方案，实测**不稳**（写多 type 或写时机微妙错位都会漏）。当前防御：

**写后立刻** `watcher.suppressUpToCurrent()`——把 watcher 内部 `lastChangeCount` 推到当前 `pasteboard.changeCount`，下一 tick 自然 `cc == lastChangeCount` 跳过。位置：`AppDelegate.pasteBack(_:)`。

**不要**重新引入 `lastSelfWriteChangeCount` 静态比较方案。

**第二层防御**：`Watcher.extract()` 顶端 `frontApp.pid == self.pid → return nil`。pasteBack 的 `suppressUpToCurrent` 只挡**程序化**写回（auto-paste 完写一次 pasteboard 后把 lastChangeCount 推到当前 cc）；用户在搜索框 / Settings 文本框里**手动** Cmd+C 时 changeCount 真实自增，suppressUpToCurrent 来不及介入——只有 self-pid 过滤能拦下来，否则 search 框 Cmd+C 会被重新入库，触发"复制 → 入库 → 又出现 → 再复制"的反复回环。

已知副作用接受：self frontmost 期间所有 changeCount 自增被吃掉。这是期望行为——剪贴板管理器自己 UI 里的复制不该污染历史，跟"在 search 框敲字然后 Cmd+C 整段当新条目入库"那条产品诉求二者**只能选一**，PR 20 review 选了不污染。

历史：2026-05 曾撤掉这一层（想让搜索框 Cmd+C 入库），PR 20 review 指出回退了双层防御不变量并恢复。如果未来要再次改产品语义，请同步更新本节 + `PasteboardWatcher.extract()` 注释 + 新增对应回归测试。

### 自动粘贴 (PasteInjector) 的不变量

panel `.nonactivatingPanel` styleMask + `HUDPanel.canBecomeKey = true` 让 panel 拿键盘焦点但**不抢** app activation——目标输入框仍是 first responder。paste 完成后 `PasteInjector.injectCmdV` 合成 Cmd+V CGEvent 让目标 app 自己读 NSPasteboard,内容直接落到原 caret 位置。

**硬不变量**(每条都踩过坑/影响多个文件,不要回退):

1. **`SearchPanelController.show()` 永远不调 `NSApp.activate(ignoringOtherApps:)`**——这一行单独存在就让 duo-paste 切到 frontmost 破坏整条 nonactivating 路径(panel 一旦抢 activation,目标输入框 first responder 状态丢,后续 Cmd+V 落不到原 caret)。即便有人想"调试时让 panel 更显眼"也**不能**加。位置:`SearchPanelController.swift` show() 路径

2. **`previousFrontmostApp` 必须 `panel.show` 之前抓 `NSWorkspace.frontmostApplication`**——`makeKeyAndOrderFront` 之后语义会受 AppKit 实现细节影响,绝对**不**在 `pasteBack` 时刻再读。self pid 直接排掉留 nil(menubar/Settings 触发场景),让 PasteInjector graceful 退化只写 pb

3. **AXIsProcessTrusted=false 时 graceful degradation,不阻塞 paste 主路径**——`CGEvent.post` 静默失败,pasteboard 已写,用户切回去 Cmd+V 仍能粘。**不**主动弹 `AXIsProcessTrustedWithOptions` 那个系统 prompt(体验糟糕且不一定到位),通过 Settings "自动粘贴权限" section 引导。Settings 用户授权完没实时回调,提供"重新检查"按钮 + 重启 daemon 两条路径

4. **50ms `Task.sleep` 不可省**——NSPasteboard 写入到所有 app 可见有 ~30ms 同步窗口(尤其 Electron/web 输入框),50ms 是 Paste.app 经验值。少数 IME composing 中输入框可能丢首字符,文档化不修。**不**用 `usleep` block main——panel hide 动画 140ms 同步跑,会卡 UI

5. **CGEvent 用 `.cghidEventTap` 不是 `.cgSessionEventTap`**——HID 流最顶端系统看到的就是用户真按了 Cmd+V,部分 sandboxed app 收不到 session-tap 注入的事件

### 空格预览 + PreviewPanel rect 上报路径(三层修复,删 NSApp.activate 后暴露的 race)

`PreviewPanelController` 的 cardRectInGlobal 通过这条链路上报:`LazyHStack` 中 anchor 卡的 `.background { GeometryReader { ... .preference(SelectedCardFramePreference, geo.frame(in: .global)) } }` → SwiftUI 内部 PreferenceKey cache → `.onPreferenceChange` → `state.selectedCardWindowRect` → `.onChange` → `onPreviewChange(true)` → `preview.show(cardRectInGlobal:)`。

这条链路有**三个 latent race**,删 `NSApp.activate(ignoringOtherApps:)` 之前都被 app-wide layout flush 掩盖,删除后浮出来:

1. **anchor (`selectedIDs.last`) vs scrollTo (`results.first`) 不一致**——panel show 时 `state.openPulse++` 触发 `proxy.scrollTo(results.first?.id, anchor: .leading)` 滚回视口起点,但 `previewAnchorID = selectedIDs.last ?? results.first?.id` 仍指向用户上次选的卡(在视口外)。LazyHStack 不渲染视口外 cell,GeometryReader 不挂载,永远不 publish frame。**修法**:`SearchPanelController.show()` 入口 `state.selectedIDs = []`,让 anchor 自然落到 results.first 跟 scrollTo 对齐

2. **SwiftUI PreferenceKey cache vs 外部 @Observable state 不同步**——SwiftUI 只在 GeometryReader publish value 跟内部 cache 不同时 fire `onPreferenceChange`。任何手动 reset 外部 `state.selectedCardWindowRect = .zero` 都不会影响 SwiftUI cache。同 anchor 卡再 publish 同样的 frame → cache 没变 → 不 fire → state 永久 stuck 在 .zero。**修法**:GeometryReader 上挂 `.id(state.openPulse)` 让每次 panel show 强制重新实例化,SwiftUI 把它当新 view → cache 清空 → 新实例 publish 必定 fire

3. **anchor 切换时 P3 reset 跟 onPreferenceChange fire 时序撞车**——历史 P3 修复(防新卡未进视口 preview 用旧 rect 错位)在 `.onChange(previewAnchorID)` 里 reset state.rect=.zero。但 SwiftUI 异步事件顺序常常是:新卡 GeometryReader publish → onPreferenceChange 写 state=新 rect → **之后** P3 reset fire 把 state 抹回 .zero。写入立刻被覆盖。**修法**:删 P3 reset 整段。新卡不在视口的边角 case 退化成"短暂错位一帧"——scrollPulse 会把新卡滚进视口,GeometryReader 挂载 publish,rect 自动修正,可接受

**不要回退任何一层**:三个修复互补缺一不可。任何一层回退都让空格预览在某些场景下死锁("必须按 ←/→ 才能触发")。

**教训**:依赖 framework 隐式副作用做"自然 fix" 是定时炸弹。历史 P3 修复 + NSApp.activate 副作用互相掩盖了 ~1 年,删 activate 一行就触发三层叠加 bug。审 PreferenceKey / Observable 跨边界路径时,如果某条 fix 路径依赖"反正某地方会再 fire 一次"——立刻警觉,显式 trigger 比依赖隐式好。

5b. **paste 路径调 `panel.hide(immediate: true)` 同步 orderOut,不走 140ms 淡出动画**——动画期间 panel 仍在 windowserver 的 window list 中,系统把 panel 当 key window,CGEvent Cmd+V 被路由到 panel 而不是目标 app,paste 完全失效。问题首次在 Zed Preview / Claude for Desktop 复现(2026-05-19),用 `immediate: true` 同步 orderOut + alpha 复位修复。Esc / 点空白处 / windowDidResignKey 这些非 paste 关闭路径默认 `immediate=false` 保留淡出动画。**不要回退**:任何把 paste 路径改回 `hide()` 默认动画的改动会立刻让 Cmd+V 注入失效

6. **self-write 防回环不需改动**——`CGEvent.post` Cmd+V 让目标 app 自己读 pb,`pasteboard.changeCount` 不会变,watcher 轮询看到 cc 不变直接跳过;`pasteBack` barrier 内 `suppressUpToCurrent` 已把 lastChangeCount 推过 self-write 那次跳变;self-pid 过滤这次根本不触发(frontmost 不是 self)。**不要**为了"以防万一"叠新防御层

7. **macOS 钥匙串密码框被 Secure Event Input 拦 CGEvent 是期望行为**——密码框本来就不该被剪贴板管理器自动粘,这是安全特性不是 bug。文档化不修

回归测试位置:`SearchPanelControllerTests`(暂未加,manual smoke 覆盖:Safari 地址栏 / VS Code / 终端 / 钥匙串密码框 / Accessibility 关闭 fallback)。

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

### Worker 不能用共享 AsyncStream.Iterator 跨 Task

Swift 6 strict concurrency 拒绝把同一个 iterator 实例 capture 进多个 child task（`group.addTask`）。当前方案：`PullWorker` 持有 `currentSleep: Task<Void, Error>?`，每 tick 起一个新 sleep task，`wake()` nonisolated 调用 actor method 取消这个 task 让 sleep 提前结束。注意 `wake()` 必须 `nonisolated`，否则外部回调（WSNotificationClient.onCursorAdvanced）拿不到非阻塞接口。位置：`PullWorker.runLoop` / `cancelCurrentSleep`。

### Server 序列化 Item：pinned 必须是 Bool，不能是 0/1

`Item.Codable` 的 `pinned: Bool` 期望 JSON true/false。一开始误用 `pinned ? 1 : 0` 让对端 `JSONDecoder().decode(Item.self)` 报 typeMismatch。位置：`Server.itemToJSON`。

### CLI 子命令在 SwiftUI 接管之前 exit

`@main DuoPasteApp.init()` 里第一行调 `CLI.dispatchAndExitIfApplicable()`。命中 `init-secret` / `retry-failed` / `--help` 则跑完直接 `exit(0|1)`，根本不让 SwiftUI 拉起 NSApp。无参 / 未识别参数返回，daemon 流程照常。子命令实现住在 `DuoPasteCore.Admin`（纯函数，便于单测），CLI 只做 argv 解析 + exit。

### 空格预览浮窗：SwiftUI 子树 + `.id(kindKey)` 切换，不要换 NSViewRepresentable Coordinator

`PreviewPanelController` 是独立 `NonKeyHUDPanel`，hostingView 里 SwiftUI 子树按 `media` 路由到 `PDFPreviewBody` / `Image` / `TextPreviewBody` / `FilePreviewBody`。kind 切换靠 `contentBody().id(kindKey)` 强制 SwiftUI clean swap 子树。代价：切回同一 PDF 时 PDFView 重建 + 首页重渲，肉眼"封面闪一下"。**接受这个 trade-off**，user 已确认。

**不要回退到**: "把所有 kind 的 NSView (PDFView / NSImageView / NSScrollView+NSTextView / NSHostingView) 全 lazy 挂在一个 container 里只 toggle isHidden" 的方案。本意是切回同 PDF 不重渲，但是 `NSImageView` / `PDFView` 的 `intrinsicContentSize`（图片像素 / PDF 页尺寸）会通过 macOS 14+ `NSHostingView.updateAnimatedWindowSize`（私有 `windowDidLayout` notification 路径）**推回 NSWindow 触发 auto-grow**——panel 从 497×706 涨到 1440×906 / 1276×2112（恰好是图片像素值）。

试过且**全部无效**的拦截方案：

| 方案 | 结果 |
|---|---|
| `NSPanel.contentMinSize = contentMaxSize = contentSize` | 私有路径无视 min/max |
| `NSHostingView.sizingOptions = []` | 默认就是 `[]`，显式写也不管用 |
| Subclass `NSHostingView` override `intrinsicContentSize = noIntrinsicMetric` | `updateAnimatedWindowSize` 不经过 intrinsicContentSize |
| Subclass `NSPanel` override `setFrame(_:display:animate:)` | private 路径不走 public `setFrame`，override 从未 fire |
| `didResizeNotification` observer + setContentSize revert | 跟 `windowDidLayout` 同步 layout pass 死循环，NSException `more Update Constraints in Window passes than there are views` 直接崩 daemon |
| 上面 + DispatchQueue.main.async 延迟 revert | 用户能看到 panel 一帧涨一帧缩，体感很糟 |

唯一守得住 panel 尺寸的路径就是**不让 NSImageView / PDFView 持续挂在 hosting view 的 SwiftUI 子树里**——`.id(kindKey)` 切 kind 时 SwiftUI 整体 tear down 这些 NSViewRepresentable，AppKit 没东西可推就不 auto-resize 了。位置：`PreviewOverlay.swift` 的 `PreviewPanelContent.contentBody` + `kindKey`。

### Settings 窗口 traffic lights 自管 placement（macOS 26 不要回到 ignoresSafeArea 那条路）

Paste 风格 Settings：sidebar 卡片视觉上**包住** traffic lights（红绿灯漂在 sidebar 卡片内部 ~14px 处）。macOS 26 上**不要**试图通过 SwiftUI 让卡片扩到 titlebar 区——这条路被验证完全走不通。

**正确姿态**（位置：`AppDelegate.showSettings` + `positionSettingsTrafficLights`）：
- NSWindow styleMask 含 `.fullSizeContentView`，`titlebarAppearsTransparent = true`，`titleVisibility = .hidden`，**不含** `.resizable`（用 `maxSize = win.frame.size` 锁尺寸，避免 traffic lights placement 在 resize 时漂移）
- contentView = `FullBleedHostingView`（NSHostingView 子类 override `safeAreaInsets` 为 0；macOS 26 上这个 override 只让 SwiftUI 的 `GeometryReader` **报告**全 0 safe area，**渲染像素**仍然 clip 到 contentLayoutRect——所以单靠它**还不够**，但它仍然要保留让 SwiftUI 内部布局正确）
- **关键步骤**：拿 `window.standardWindowButton(.closeButton / .miniaturizeButton / .zoomButton)` 三个按钮，`contentView.addSubview(button, positioned: .above, relativeTo: nil)` 把它们从 frameView 重新挂到 contentView，再 `setFrameOrigin` 手动定位（当前实现 topInset=40 / leftInset=34 / spacing=25 落在 sidebar 卡片内部）
- 补一层 `TrafficLightGlyphOverlay` 自定义 NSView，覆盖在三个按钮上方，hover 时自己画 ×/-/+ glyph（按钮被 reparent 后系统的 hover-glyph 路径断了，必须手画）。`hitTest` 返回 nil 让点击穿透到底下的真按钮
- `windowDidResize` hook 重 position（即便 resize 被锁，写了无害）

**试过且全部无效的方向**（macOS 26 NSHostingView 真的会无视所有 SwiftUI 层 safe area 控制）：

| 方案 | 结果 |
|---|---|
| `NSHostingView.safeAreaInsets` override 为 0 | GeometryReader 报告 size=(W, contentView.h) safeArea=0，但渲染像素仍在 titlebar 下方开始 |
| `NSHostingView.safeAreaRegions = []`（macOS 14+ 标准 API） | 同上 |
| SwiftUI `.ignoresSafeArea()` / `.ignoresSafeArea(.all)` | 同上 |
| NSWindow 创建时一次传完整 styleMask（避免后追加 .fullSizeContentView） | window/contentView frame 正常变 680，但渲染区不变 |
| 套 wrapper NSView 作 contentView + hostingView `topAnchor = wrapper.top - 32`（让 host frame 712 高，向上突出窗口顶 32px） | hostingView 内部 inset 不按 host frame 算而按 NSWindow.contentLayoutRect 绝对算，hack 没生效 |
| SwiftUI root `.padding(.top, -32)` 把所有内容上移 | 视觉上 sidebar 卡片是贴顶了，但 SwiftUI 内容画到 hostingView 边界外被 frameView 的 traffic lights 整体遮住，红绿灯反而完全看不见 |

**根本原因**：macOS 26 上 NSHostingView 在 `fullSizeContentView` 窗口里把 SwiftUI **渲染**硬剪到 `window.contentLayoutRect`（=contentView.frame 减 titlebar 32px），跟 hostingView 自身 frame 没关系，跟 SwiftUI 报告的 safeArea 也没关系。SwiftUI 的 logical layout 是 680 高，但实际像素只画 648 高（top 32px 是 titlebar 区，hostingView 自己跳过）。

**不要回退**：下次看到 `positionSettingsTrafficLights(in:)` 这个看起来 hacky 的 ~30 行函数觉得"是不是能用 SwiftUI 干净方案替代"——**不能**。从 `.padding(.top, -32)` 起所有 SwiftUI 层 hack 都验证过失败。Codex 接手 3 轮就用这个 AppKit 姿态修好了，方向正确。

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

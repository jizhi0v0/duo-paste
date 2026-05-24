- **同步路径**：每个 peer 一对 `(PullWorker, WSNotificationClient)`。PullWorker 周期 `/since` 拉对端增量到本机 item 表（origin=对端 device_id）；WSNotificationClient 订 `/sync/ws` cursor_advanced 帧 → 收到 `worker.wake()` 跳过 sleep（< 1s 延迟）。WS 断了退化为周期 pull
- **HTTP routes**：`GET /health` + `GET /blob/<sha>` + `GET /since` + `GET /sync/ws`（Upgrade）+ `GET /app_icon/<bundleID>` + `POST /bump/<id>`（跨设备一致"复制即顶"：iOS tap → Mac DB bump captured/ingested_at_ns → broadcaster fan-out → 其他 peer 通过 PullWorker 看到）。无 push / 远端搜索路径（`POST /ingest` / `PUT/HEAD /blob` / `GET /search` 已下线）
- **CaptureService**：永远走 `Database.nextIngestNs` stamp（writer tx 内）；merge candidate 带 `origin_device == selfDeviceID` 过滤防 bump 对端行；commit 后回调 `onCursorAdvanced` 让 server 端 `WSBroadcaster` fan-out
- **Search**：单一 fold-aware 路径——`SearchAPI.searchHits / count / countByKind` 内部 oversample → text-fold（跨 origin 同 text_full 折一条，pinned OR 聚合）→ kinds/pinnedOnly 后置过滤 → 排序契约 `(pinned DESC, prefix24h DESC, captured_at_ns DESC)` → LIMIT/OFFSET。**list / total / chip 三者口径一致**是硬不变量。`SearchProvider.Mode` 仅 `.local` / `.mesh(stalenessSec:)`，永远走本机 fold 不打远端
- **跨设备 dedup**：两层防御——capture 层（同 origin 同 text 永久合并，merge candidate 加 origin 过滤）+ search fold 层（跨 origin 兜底）。Continuity / ToDesk 副本通过 PullWorker `crossDeviceDedupWindowNs` (5s) + PasteSuppressionSet 拦
- **Blob**：内容寻址 BlobStore（linkItem 不 moveItem，见 §"BlobStore 并发竞态"）；lazy paste-back（按需 GET `/blob/<sha>`，TaskGroup 30s 超时 race，见 §"blob 懒拉的不变量" #8）；可选 eager (`mesh.eager_blobs=true`) 拉完元数据顺路拉字节
- **HMAC 认证**：`<ts>\n<METHOD>\n<path>\n<body_sha256_hex>`。middleware 不读 body（让多 MB blob 不占内存），handler 自己读 body 后再算 sha256 比对 header。WS upgrade 同模板（empty body hash），upgrade 后 frame 不签
- **OCR**：本机 own-origin image 跑 Vision OCR 写 `text_full` 进 FTS5；markDone 触发 onCursorAdvanced 让对端 < 1s 同步 OCR 结果（共享 wsBroadcaster fan-out 路径），peer FTS5 trigger 自动重 index
- **mesh-doctor CLI**：探 /health (deviceID + skewMs vs expected) + pull_cursor + max(ingested_at_ns) + missing blob 统计。只读。退出码 0=健康，任一异常 → 1
- **WS auth rotation**：`mesh.ws_rotation_sec`（默 4h，0 关）WSBroadcaster 每周期主动 close 所有连接；合法 client backoff 重连 + 重 HMAC upgrade。shared-secret 被窃取后的监听窗口 ≤ 这个值
- **依赖**：GRDB 7 + Hummingbird 2 + HummingbirdTLS + hummingbird-websocket（具体版本看 Package.resolved）
- **测试**：~270，PullWorker / BlobLazyPull **已知偶发并发 flake**（端口/SQLite 竞争，全集挂、单跑必绿），用 `swift test --filter PullWorkerTests` / `--filter BlobLazyPullTests` 单独验证
- **iOS 端**：
  - **WS zombie 检测**：URLSessionWebSocketTask 没协议层 PING，走应用层 `WSMessage.ping/.pong`——`PeerWebSocket.pingLoop` 每 30s ping，10s 内没 pong 抛 `WSError.pongTimeout` 重连。`PeerSyncCoordinator` 5s tick + 90s heartbeat staleness 兜底降级到 `.error("链路无响应")`
  - **POST /bump 客户端**：`HistoryCellView.triggerCopy` 先 `store.bumpToFront` 乐观顶 + UCB 写 pasteboard，**再** `coordinator.bumpItemOnServer` async 让 Mac DB 也顶。404/410 swallow
  - **Bonjour + QR 配对**：Mac `BonjourAdvertiser` publish `_duopaste._tcp` + Settings 二维码（60s 倒计时，含 url + secret hex）；iOS `PeerDiscovery` NWBrowser + `QRScannerView` AVCaptureSession。Info.plist 需 `NSBonjourServices=_duopaste._tcp` / `NSCameraUsageDescription` / `NSLocalNetworkUsageDescription`
  - **BlobCache 磁盘 + LRU**：`Caches/Blobs/v1/<ab>/<cd>/<sha>.bin` 三层目录持久化跨启动。500MB cap 按 mtime 升序 evict。Detached IO 避免大图同步读卡 main actor
  - **后台 pull**：`BackgroundPullService` 用 BGAppRefreshTask（id `io.duopaste.ios.background-pull`，Info.plist 配 `BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes=fetch`），系统 best-effort 唤醒拉 /since + 持久化 `Caches/HistoryStore/items.json`。app `scenePhase=.active` 时 merge 磁盘到 store。WS 后台不能跑（iOS 限制）降级周期 HTTP pull

## 架构与 Non-Goals

- **拓扑**：每台 Mac 是平等 peer（mini + MBP 双向）。没有 primary，没有 promote。`mesh-init` CLI 配双向 peer URL，daemon 启动时为每个 peer 起一对 `(PullWorker, WSNotificationClient)`
- **单一归属**：每条剪贴项归属捕获它的设备（`origin_device`），跨设备 dedup 在 PullWorker / search fold 兜底
- **同步对称**：peer A 通过 `/since` 从 peer B 拉，反过来同时跑（双向 mesh）。WS 通知层让推送延迟 < 1s
- 传输：Tailscale 网络，**不走公网**

**Non-Goals**（用户明确排除，不要主动建议）：iCloud 加密备份 / 双向同步冲突解决（mesh 拓扑下 own/peer 单一归属，无需解决）/ 自动 leader election / 共识算法

## 部署与运行

### 装 / 卸 LaunchAgent

```sh
./scripts/install-agent.sh    # 幂等：build release + 拷到 ~/Applications + bootstrap
./scripts/uninstall-agent.sh  # 拆掉，不动数据
```

### CLI 子命令

```sh
~/Applications/duo-paste/duo-pasted --help                  # 子命令列表
~/Applications/duo-paste/duo-pasted init-secret             # 首次部署：生成 32 字节 shared secret
~/Applications/duo-paste/duo-pasted mesh-init --peer URL... # 切到 mesh 拓扑
~/Applications/duo-paste/duo-pasted mesh-doctor             # 探所有 peer + cursor 对账（只读）
~/Applications/duo-paste/duo-pasted retry-failed-ocr        # OCR failed/skipped 翻回 pending
```

无参 → SwiftUI daemon 流程（LaunchAgent 调用方式）。子命令在 SwiftUI 接管 NSApp 之前 exit。

### 多设备配置（mesh）

`config.json` 不存在 → standalone（peers 空 + serve=false，零回归）。要起 mesh：两台都跑 `mesh-init`（先 `launchctl bootout` 停 daemon，否则拒）。典型 flag：`--peer https://<peer>:8443 --serve-host 0.0.0.0 --serve-port 8443 --serve-tls --tls-cert <self.crt> --tls-key <self.key>`。写好的 config 含 `serve_tls / tls_cert_path / tls_key_path / peers[].url / mesh.{enabled, pull_interval_sec, ws_enabled}`。

要点：
- TLS cert：mkcert 双 SAN（tailnet + sgponte，见下方）。**不要**回退到 `tailscale cert` 单 SAN——SmartTransport ponte 路径永久 unreachable
- `shared-secret` 文件两台同份（`scp` + `chmod 600`）
- 两端 peer URL 互指 + scheme 必须对齐（一端 https 一端 http 让 ws-client TLS 握手 EOF）
- `mesh-init` 预检 blob 缺失，默认拒；`--allow-missing-blobs` 跳过。完成后手动 `launchctl bootstrap + kickstart`

### TLS cert：双 SAN（含 sgponte）部署

SmartTransport 同时探 `tailscale` + `ponte` 两条候选——ponte 通过 Surge Ponte 解析 `*.sgponte` 走 proxy（127.0.0.1:6152）。`tailscale cert <hostname>` 单 SAN 只含 tailnet hostname → URLSession 走 ponte 时 SNI 校验失败 → 永久 `A TLS error caused the secure connection to fail.` 静默 fallback。要两条候选都可用，**每台 daemon 的 cert 必须同时含 tailnet + sgponte hostname**。用 mkcert 起本机 CA 签双 SAN leaf，两端 login 钥匙串 trust root CA。

**sgponte hostname 表**（跟 Surge Ponte 配置硬对齐）：

| 设备 | tailnet hostname | sgponte hostname |
|---|---|---|
| mini | `bobbys-mac-mini.tail69730a.ts.net` | `mac.sgponte` |
| MBP  | `bobbys-macbook-pro.tail69730a.ts.net` | `mbpmbp.sgponte` |

**签发**（一台 mac 签完两台，root CA private key 留该机）：

```sh
cd ~/Library/Application\ Support/duo-paste/tls
mkcert -install
mkcert -cert-file <host>.dual.crt -key-file <host>.dual.key <tailnet-host> <sgponte-host>
```

CA root 位置 `mkcert -CAROOT`（默 `~/Library/Application Support/mkcert/`）。`rootCA.pem` 分发对端；`rootCA-key.pem` **绝不**外发（泄露 = attacker 能签任意域名让该用户 HTTPS 客户端信任）。

**部署**（每台 mac 重复）：cp leaf cert/key + `chmod 600 *.key` → `security add-trusted-cert -k ~/Library/Keychains/login.keychain-db -p ssl rootCA.pem`（用户态 SSL EKU only 不需 sudo）→ 改 `config.json` 的 `tls_cert_path/tls_key_path` → `launchctl kickstart -k gui/$UID/io.duopaste.agent` → 自检 `curl -sv https://localhost:8443/health` + `curl -sv --proxy http://127.0.0.1:6152 https://<self-sgponte>:8443/health` 都 verify ok。

**跨机分发**：`tar czf deploy.tar.gz <host>.dual.crt <host>.dual.key rootCA.pem && tailscale file cp deploy.tar.gz <peer>:`（WG/DERP 加密 P2P）。**不要**走 iCloud Drive——private key 在 Apple 服务器留快照。

**到期**：mkcert leaf 默 2 年 3 月**无自动续期**，到期前重跑 `mkcert -cert-file ...`（root CA 不变，对端不需重 trust）。

**不要回退到** tailscale 单 SAN cert——会让 ponte 路径永久 unreachable，UI ponte "不可达" 红字会再出现。

**SAN 是真相，cert 文件名只是部署习惯**：`EndpointDiscovery.certTailscaleHost` 用 `SecCertificateCopyValues + kSecOIDSubjectAltName` 读 cert SAN list，优先返 `.ts.net` 结尾那条（Tailscale FQDN），次选非 `.sgponte` DNS SAN。文件名命名爱怎样怎样，`<host>.dual.crt` / `<host>.tail<id>.ts.net.dual.crt` / `<short>.crt` 都行。**不要假设**改文件名能改 endpoint URL——签新 cert 才行。读 cert 失败（Linux / 文件没了）→ fallback 到 `certHostnameStem` 剥文件名（向后兼容老部署）。

**为什么有这条**：f4e711a 之前 tailscale 候选 URL 借 `ProcessInfo.hostName` 拿 MagicDNS 反查的 FQDN，f4e711a 切到 cert 文件名 stem 修 `.local` 双 suffix 时把 tailnet FQDN 信号一起丢了——cert 文件名是 `<short>.dual.crt`，stem 剥完是裸短名 `<short>`，iOS 拿到后 SNI 校验失败 `NoSuchRecord` 永久断 tailscale 路径。回归测试 `EndpointDiscoveryTests.discoverUsesSANNotFilenameStemWhenCertExists` 锁住这条契约。

### 关键路径

数据（`~/Library/Application Support/duo-paste/` 下）：
- `db/main.sqlite` 主 DB（含 FTS5）
- `blobs/<ab>/<cd>/<sha256>.<ext>` 内容寻址 blob
- `snapshots/duo-paste-YYYYMMDD-HHmmss.sqlite` 小时级 snapshot
- `device-id` 本机稳定 UUID

部署产物：`~/Applications/DuoPaste.app` (`…/Contents/MacOS/duo-pasted`) + `~/Library/LaunchAgents/io.duopaste.agent.plist` + 日志 `~/Library/Logs/duo-paste/duo-pasted.{out,err}.log`。

签名：Developer ID Application: BO LI (`RS59HDH7Y3`) + hardened runtime，Bundle ID = `io.duopaste.daemon`。macOS TCC 按 Team ID + Bundle ID 判 Accessibility 权限——`install-agent.sh` 重装 cdhash 变但 DR 不变，权限自动跟。**禁止回退 adhoc 签名**：adhoc 让 Accessibility 列表旧 cdhash 失效，每次 install 都得重勾。

### launchctl 速查

```sh
launchctl print    gui/$UID/io.duopaste.agent      # 状态
launchctl bootout  gui/$UID/io.duopaste.agent      # 停
launchctl kickstart -k gui/$UID/io.duopaste.agent  # 强重启
```

## 开发工作流

LaunchAgent 装好后常驻 release daemon。**不能** `swift run` 直接调试——双进程重复捕获、抢全局快捷键、SQLite WAL 多写者竞争。流程：改代码 → `swift build && swift test` → `./scripts/install-agent.sh` 重装（幂等）。跑 dev 二进制前先 `launchctl bootout gui/$UID/io.duopaste.agent`，跑完恢复。日志 `tail -f ~/Library/Logs/duo-paste/duo-pasted.err.log`（含 "UI ready" / "snapshot ok" / `[HummingbirdCore] Server started` 正常诊断，不全是错误）。

bootstrap 报 `5: Input/output error` → sleep 2s 后手动 `launchctl bootstrap ... && launchctl kickstart -k ...`。**launchd "languishing"**：反复 bootout/bootstrap 触发速率限制，`launchctl print` 显示 `state = languishing`——等 10-30s 到 `launchctl print` 返回 `Could not find service`（彻底 boot out）再重新 bootstrap。不要 sudo / 不要改 plist。

## 关键设计决策（不要回退）

### Capture 字节守门（防意外 Cmd+C 巨物）

`config.capture.{max_blob_mb=32, max_text_kb=512}`。超 cap → CaptureService 跳过入库返 `.skippedTooLarge`，**NSPasteboard 自身不受影响**（Cmd+V 仍正常）。文件路径走 `.file` kind + 字符串形式（< 1KB）永远过文本 cap，Finder 复制 50GB 工程文件夹零受影响。

UI 反馈：AppState.recentSkip + SearchView orange skipBanner（✕ 关闭 + 5 分钟自动消失）。文案明确说"剪贴板本身正常可直接 Cmd+V 粘贴"——防止用户以为 daemon 挂了。

**作用域**：per-device capture policy 不是 sync-wide invariant。peer 间 HMAC + 共享 secret = 已认证内部边界，不重校单字段大小。

### SearchProvider 永远走本机 fold-aware（chip 总数对齐）

`SearchProvider.search` 永远走 `SearchAPI.searchHits / count / countByKind`——内部 fold-aware（跨 origin 同 text_full 折一条），无 "raw count vs fold count" 双路径。

**核心不变量**：mesh 拓扑下 `item` 表混存本机 own + 对端 peer 行，跨 origin 同 text 是常态。raw count 会把 ToDesk/Continuity 副本算一遍跟对端口径不齐——回归测试 `searchProviderTotalCountMatchesFoldedRowCount`。

### 搜索排序契约：pinned > prefix(24h) > time

`(pinned DESC, prefix_score DESC, captured_at_ns DESC)`。prefix_score：preview 以 query 起始 = 2 / text_full 起始 = 1 / 否则 0。**仅对 24h 内项生效**——跨天老内容哪怕起头匹配也走纯时间倒序，剪贴板心智是"搜=找最近用过的"。

SQL 端 `fetchHitsRaw` 内 `instr(LOWER(IFNULL(col, '')), LOWER(?)) = 1` 算 `_prefix` 列 + `CASE WHEN now-captured_at_ns < 86400000000000 THEN _prefix ELSE 0 END DESC` 进 ORDER BY。prefix 占位符必须 `args.insert(at: 0)`（SELECT 列表 `?` 在 WHERE/LIMIT 之前）。Swift 端 `fetchHitsFolded.prefixScore` 跟 SQL 口径**必须**一致——fold 后 SQL 算的 `_prefix` 列已丢，重算。

回归测试 `SearchPrefixBoostTests.swift`：单表 boost / pinned 优先 / 24h 窗外不 boost / fold 后保留优先级。

### 文本永久 dedup（capture + search 双层）

文本 kind（`text/url/file`，即 `blob_sha256 IS NULL`）走永久 dedup：

1. **Capture 层**（`CaptureService.ingestText`）：`config.capture.text_merge_window_sec` 默认 `null` = 永久。同 kind + 同 `text_full` + 未删 + **同 origin** 再次 capture，合并 bump `captured_at_ns + ingested_at_ns` 让对端 /since 看到刷新。**merge candidate 必须加 origin_device 过滤**——不然合表后 bump 对端行（等于本机改了别人数据）。`0` = 禁用，`N>0` = 固定窗口。`blob mergeWindowSec` 独立保留 300s
2. **搜索层**（`Search.fetchHitsFolded`）：oversample 后按 `text_full` 跨 origin fold。Winner = `max(capturedAtNs)`，**pinned OR 聚合**（任一条 pinned → fold 结果 pinned=true）。`count` / `countByKind` 同源 fold 保证 list / total / chip 口径一致

为什么要两层：Capture 层不够 —— ToDesk/Continuity 把 mini pasteboard 同步到 MBP，两台 watcher 各抓一条 own-origin 行（不同 origin_device），mini 行通过 PullWorker 进 MBP 的 item 表，搜索时跨 origin 同 text 仍要 fold。Fold 层不够 —— 同设备短时重复 copy 仍插多行，存储白浪费。

**不要回退到固定窗口默认值**：5 分钟窗口在 ToDesk 场景下两端时间错位常超窗，再现"同文本并排两条"问题。

### `preview` vs `text_full` 字段语义：UI 必须读 textFull

`item.preview` = `CaptureService.makePreview` 截到 **280 字符 + `…`** 的网络短预览（给 `/since` 列表省 payload）。`item.text_full` = 原始可粘贴完整内容（受 `config.capture.max_text_kb` 守门，默 512KB）。两个字段 server 端**同时**写入 DB + 通过 `/since` JSON **同时**下发（无截断）。

**UI 端必须用 textFull**——fallback 到 preview 会让卡片末尾出现 server 加的 `…` 截断符，且文本短于 lineLimit 时填不满 frame。

**统一入口**：`Item.cardPreviewSource(maxChars:)` (Sources/DuoPasteCore/Item.swift) —— textFull 优先 + `prefix(maxChars)` 防御性截断。macOS 卡片传 512，iOS HistoryCellView 传 300。

**规则范围 = 卡片/列表 cell 展示路径**。其它路径（详情大预览、导出、open-with、paste-merge、本地 contains 过滤等）**允许** `item.textFull ?? item.preview`。受约束的卡片/列表调用点（不要再加新的 `item.preview ??` fallback）：
- `Sources/duo-pasted/SearchView.swift` 的 `previewAttributedForTextCard` else 分支
- `Sources/duo-pasted/SearchView.swift` 的 `previewText` else 分支
- `iOS/DuoPaste/Models.swift` 的 `displayPreview`

**已知边界 · iOS cold-launch 老 cache**：`BackgroundPullService` 持久化 items.json，app 升级后 cold-launch 读老 cache 项 textFull 可能 nil → 退 preview → 卡片仍带 `…`，下次 PullWorker 拉新 item 覆盖才修复。不修——schema version invalidate 代价高于收益。

**多段 textFull paragraphStyle 精细应用**：`previewAttributedForTextCard` 的 `firstLineHeadIndent=8`（避开左上 app icon）**必须只应用到第一个 paragraph**——firstLineHeadIndent 是 per-paragraph，整段统一设让多段每段首行 indent 8pt 错位。代码里两个 paragraphStyle (pIndent / pPlain) + 按 `\n` 分隔的 range 精细 addAttribute，**不要回退到单一 paragraphStyle 全 range 应用**。

**为什么不在 `Item.preview` getter 里直接返回 textFull**：preview 字段还要喂 FTS5 索引 / `/since` wire（老客户端无 textFull 也能展示）/ 搜索 prefix-boost 排序等数据路径，这些保留**网络短预览**语义。坑只在 UI 卡片消费端。

回归测试：`Tests/DuoPasteCoreTests/CardPreviewSourceTests.swift` 五条契约。

### RTF 三层降级 + raw-size 守门

1. pasteboard 同时写 `.string` 非空 → 直接用 plain
2. raw RTF 字节 ≤ `maxRawRTFBytes`（= `config.capture.maxTextBytes`，默 512KB）→ `decodeRTFToPlain` 用 NSAttributedString 解出 plain
3. 解析失败 / 全空白 / raw 超 cap → 兜底存 raw rtf 让 CaptureService 字节守门拦下

`maxRawRTFBytes` guard 是 PR#5 review 修复：watcher 跑 `@MainActor` 轮询，`NSAttributedString(data:options:[.documentType:.rtf])` 同步解析 50MB markup 在 UI 线程分配巨型 attributed string；guard 提前跳过 decode，让兜底走 CaptureService 字节守门（decoded plain ≤ raw RTF，解出来仍超 cap，无解码价值）。

**不要回退**：调大 / 去掉 guard 等于让 main actor 在 RTF 路径裸跑，卡顿极难溯源（200ms 轮询 spike 淹没在 Instruments 噪声里）。

### mesh-init 的不变量

1. **不动 DB**：daemon 启动后 PullWorker `reconcilePeer` 自己清理对端行（v7/v8 migration 已处理）
2. **daemon 必须停**——`LaunchAgent.isRunning` 检测在跑直接 throw。mesh-init 改 config 期间 daemon 跑老 config 可能 capture + 抢 PullWorker 锁
3. **预检 blob 缺失**：扫 item 表 blob_sha256 非空 + image/file + 未删的去重 sha，`BlobStore.exists` 缺失默认 throw `missingBlobs`；`--allow-missing-blobs` 跳过；tombstone 不计
4. **`Config.write` 显式 removeValue 老字段** `primary_url` / `pull`，避免两套字段共存
5. **TLS 字段一致性**：`--serve-tls` 必须配 `--tls-cert/--tls-key`（或 oldConfig 已有）+ 文件存在性预检。两端 peer URL scheme 必须对齐。回归测试 `meshInitRefusesServeTLSWithoutCertAndKey` / `meshInitRefusesServeTLSWhenCertFileMissing` / `meshInitInheritsTLSFromOldConfigWhenNotGiven`
6. **不主动改 LaunchAgent**——CLI 是单次 exit 进程，mesh-init 完成后打印 kickstart 提示让用户手动重启
7. **保留无关字段**——hotkey / capture / ocr / shared_secret_keychain_account 不动；Config.write 走 nested merge 让用户手动加的未知字段也保留。回归测试 `meshInitPreservesUnrelatedConfigFields`

### blob 懒拉的不变量

`mesh.eager_blobs`（默 false）+ `AppDelegate.pasteBack` lazy 路径 + `PullWorker.fetchBlobsEager` 三处协同：

1. **content-addressed 接收方必须重算 sha** —— `HTTPIngestClient.getBlob` 200 时本地重算 SHA256 比 path-sha；不匹配抛 `GetBlobError.shaMismatch`。HMAC 只保 request 完整性不保 response body。`BlobStore.putVerified` 第二层兜底。测试 `putVerifiedRejectsMismatchedSha`
2. **eager 失败不回滚 mirror** —— `applyPage` 已在 writer tx commit mirror + cursor，**之后**才 `fetchBlobsEager`。eager 失败 only log，下次 tick 自然重试。测试 `eagerBlobsFailureDoesNotRevertMirror`
3. **eager 不拉 tombstone 的 blob** —— `applyPage.mirroredShas` 过滤 `item.deletedAtNs != nil`。测试 `eagerBlobsSkipsTombstone`
4. **eager 不拉 origin=self 的 blob** —— own-origin 行不入 mirror，自然跳过。测试 `eagerBlobsSkipsOwnOriginRows`
5. **lazy paste 同步阻塞 panel** —— Enter case 的 hide 责任移交 onPaste 回调（AppDelegate.pasteBack）。同步路径完成后 `panel.hide()`；慢路径起 `currentPasteTask` 完成后再 hide。**不要回退**——async 关 panel 让用户切到目标 app 后已脱离原 context
6. **panel hide 必须 cancel 进行中的 lazy task** —— `SearchPanelController.init` 接 `onDismiss` callback，`hide()` 调它；AppDelegate 注册 cancel currentPasteTask + 清 progress。覆盖 Esc / `windowDidResignKey` / 主动 `hide()`。**不要回退**——不 cancel 让 task 继续写 NSPasteboard 形成孤儿写入
7. **lazy 多次 Enter 自动 cancel 旧 task** —— `AppDelegate.currentPasteTask` 保存上次 Task，pasteBack 调用时先 cancel 再起新的
8. **lazy 30s 总超时靠 TaskGroup race，不靠 `Date()` 检查** —— DERP 中继 TLS 握手 3s+ 经常超时所以 30s。`fetchBlobLazy` 用 `withThrowingTaskGroup` race：(a) `fetchBlobLazyInner` 重试循环 `backoffs=[0, 2, 4]`（`.transient` 进下一轮；`.rejected`/`.shaMismatch`/`.notFound` 立即 fail），(b) `Task.sleep(lazyBlobTimeoutSec)` 抛 timeout。先完成的赢 + `group.cancelAll()`。**不要回退**——URLSession 单 request 默 60s，server hang 在 connection 建立但不返数据时 inner 没机会 check Date()；group cancel 让 URLSession 抛 `URLError.cancelled` 立即返回。`lazyBlobTimeoutSec` 必须 `nonisolated`。配合：`SearchPanelController.hide` 必须**同步**先调 `onDismiss()` 再走 140ms 视觉收场动画
9. **`pasteBlobFetcher` 跟 PullWorker 解耦** —— `setupPasteBlobFetcher` 在 `applicationDidFinishLaunching` 跟 `startMeshSupervisor` 平行调用，只依赖 `peers[0] + shared-secret`，**不**依赖 `mesh.enabled` / `serve`。配 peers 但关 `mesh.enabled`（只想 paste 时按需取 blob）是合法配置

### BlobStore 并发竞态：linkItem 取代 moveItem

`BlobStore.put` / `putVerified` 共享 `writeBlob`：先 stage 写 tmp，再 `linkItem(at: tmp, to: target)`（hard link），失败若 target 已存在 → wasExisting=true + **不**调 `notifyAdded`。`defer { removeItem(tmp) }` 总清 tmp。

**不要回退到 moveItem**：`FileManager.moveItem` 走 POSIX `rename(2)` —— atomic replace，dst 已存在时**不报错而是覆盖**。竞态丢方根本进不了 catch 分支，原 catch 内 "wasExisting + notifyAdded" 误判让 BlobStorageStats 重复计字节、UI 仓库占用虚增。`linkItem` 走 `link(2)`，dst 存在必 EEXIST，是真正 exclusive create。

回归测试：`concurrentPutSameShaCountsOnceInStats`（16 并发 put 同 sha 字节只算一份）。

### WSNotificationClient 长连接成功 reset failureCounter

`Config.longLivedConnectionThresholdSec`（默 30s）划分"短闪连失败"vs"长连接合法关"。`setConnected(true)` 记 `currentConnectionStartedAt`；`setConnected(false)` 算 elapsed 达阈值置 `longConnectionThisRound`。runLoop 跑完 `connectOnce` 后 `consume` flag——长连接路径 reset `consecutiveFailures = 0`，短闪连走原 `+=1` + 指数 backoff。

**不要回退到无条件 +1**：旧实现配合 WSBroadcaster `mesh.ws_rotation_sec`（默 4h）主动 close 所有连接，约 60h 后所有长连接 consecutiveFailures 累到 budget=15，触发 `exit(1)`，launchd 重启——每隔几天来一次而没人知道为啥。

回归测试：`longLivedConnectionResetsFailureCounter`。

### /pair TLS-only 护栏

`SyncServer.requirePairingTLS`（默 true）+ `tls == nil` 时 `/pair/<pin>` handler 在 PIN 校验**之前**返 503。daemon 启动期若不满足且 `pairingService != nil`，stderr 立刻打 WARN。测试用 `requirePairingTLS: false` 显式 opt-out。

**为什么硬护栏**：`/pair` response body 含 `secret: hex` 明文（iOS HMAC 主密钥）。Tailscale 路径 WG 加密兜底 OK，但 iOS 配对常走 `.local` / 直连 IP——不进 tailnet，secret 明文暴露给 LAN 中间人。PIN 单次 + 5 次封锁挡不住"监听一次成功配对"。

**不要回退**：未来 daemon 跑 plain HTTP 时必须升级到 TLS 才能用 iOS 配对，不是放宽这条。回归测试 `pairReturns503WhenTLSRequiredButMissing`。

### PullWorker peer 换了的检测（reconcilePeer）

每 tick 第一步 `/health` 拿 `device_id` 跟 `pull_cursor.peer_device_id` 比。不一致 → 精确清该 peer 旧 origin 行 + 该 peer cursor 行（不动其他 peer / own）。

**严格模式 vs 学习模式**：
- `expectedPeerDeviceID` 非 nil → 严格。/health device_id 跟 expected 不一致立即 transient skip 不污染 DB
- `expectedPeerDeviceID` nil → 学习。首次 /health 拿到 device_id 后 stamp 进 pull_cursor。只能用于单 peer 部署（多 peer LIMIT 1 不可靠）

边界：`device_id=""` 当 transient 跳过；`now_ms` 解码三种形态都接（String/Int64/Double）。

### ingested_at_ns 必须在 writer tx 内 stamp

`Database.nextIngestNs(db, now:)` 返回 `max(now, MAX(item.ingested_at_ns)+1)`。**唯一**正确 stamp 时机是 `pool.write { db in ... }` 闭包内——不能提前算 `now`。

为什么：GRDB DatabasePool 让 reader 并发但 writer 串行。两路并发 `pool.write` 在 writer 队列排队，外面打的 `now` 时间戳跟 commit 顺序可以反过来 → reader 看到 `ns=200` 推进 cursor，之后 `ns=100` 才 commit → `/since` WHERE `ns > 200` 永远漏掉那行。

调用点：`CaptureService.ingestText` / `ingestBlob` 的 insert + merge 路径，`PullWorker.applyPage`。

### NSPasteboard 自写回环——双层防御

**第一层** 写后立刻 `watcher.suppressUpToCurrent()` —— 把 watcher `lastChangeCount` 推到当前 `pasteboard.changeCount`，下一 tick `cc == lastChangeCount` 跳过。位置：`AppDelegate.pasteBack(_:)`。**不要**重新引入 `lastSelfWriteChangeCount` 静态比较方案（实测不稳，写多 type 或时机错位会漏）。

**第二层** `Watcher.extract()` 顶端 `frontApp.pid == self.pid → return nil`。suppressUpToCurrent 只挡程序化写回；用户在搜索框 / Settings 文本框**手动** Cmd+C 时 changeCount 真实自增 suppressUpToCurrent 来不及介入——只有 self-pid 过滤能拦下来，否则触发"复制 → 入库 → 又出现 → 再复制"回环。

已知副作用接受：self frontmost 期间所有 changeCount 自增被吃掉。这是期望行为，跟"在 search 框敲字然后 Cmd+C 整段当新条目入库"二者只能选一，已选不污染。

### 自动粘贴 (PasteInjector) 的不变量

panel `.nonactivatingPanel` styleMask + `HUDPanel.canBecomeKey = true` 让 panel 拿键盘焦点但**不抢** app activation——目标输入框仍是 first responder。paste 完 `PasteInjector.injectCmdV` 合成 Cmd+V CGEvent 让目标 app 自己读 NSPasteboard。

**硬不变量**：

1. **`SearchPanelController.show()` 永远不调 `NSApp.activate(ignoringOtherApps:)`**——一旦调用 duo-paste 切 frontmost 破坏整条 nonactivating 路径（first responder 丢，Cmd+V 落不到原 caret）。调试时也**不能**加
2. **`previousFrontmostApp` 必须 `panel.show` 之前抓 `NSWorkspace.frontmostApplication`**——`makeKeyAndOrderFront` 之后语义受 AppKit 内部影响，绝对**不**在 `pasteBack` 时刻再读。self pid 直接排掉留 nil（menubar/Settings 场景），让 PasteInjector graceful 退化只写 pb
3. **AXIsProcessTrusted=false 时 graceful degradation**——`CGEvent.post` 静默失败，pasteboard 已写用户切回去 Cmd+V 仍能粘。**不**主动弹 `AXIsProcessTrustedWithOptions` 系统 prompt，通过 Settings "自动粘贴权限" section 引导
4. **50ms `Task.sleep` 不可省**——NSPasteboard 写入到所有 app 可见 ~30ms 同步窗口（尤其 Electron/web），50ms 是 Paste.app 经验值。少数 IME composing 输入框可能丢首字符，不修。**不**用 `usleep` block main
5. **CGEvent 用 `.cghidEventTap` 不是 `.cgSessionEventTap`**——HID 流最顶端系统看到的就是用户真按了 Cmd+V，部分 sandboxed app 收不到 session-tap 注入

### 空格预览 PreviewPanel rect 上报路径（三层修复）

`PreviewPanelController.cardRectInGlobal` 通过 LazyHStack anchor 卡 `.background { GeometryReader { .preference(SelectedCardFramePreference, geo.frame(in: .global)) } }` → PreferenceKey → `.onPreferenceChange` → `state.selectedCardWindowRect` → `preview.show(cardRectInGlobal:)`。三个 latent race 都已修，**不要回退任何一层**：

1. **anchor vs scrollTo 不一致**——panel show 时 scrollTo 滚到 `results.first`，但 `previewAnchorID = selectedIDs.last ?? results.first?.id` 可能指视口外卡。LazyHStack 不渲染视口外 cell → GeometryReader 不挂载 → 永远不 publish。**修法**：`SearchPanelController.show()` 入口 `state.selectedIDs = []` 让 anchor 落到 results.first
2. **PreferenceKey cache vs 外部 @Observable state 不同步**——同 anchor 卡再 publish 同样 frame → SwiftUI cache 没变不 fire → state 永久 stuck `.zero`。**修法**：GeometryReader 上挂 `.id(state.openPulse)` 每次 panel show 强制重新实例化清空 cache
3. **anchor 切换时 P3 reset 跟 onPreferenceChange 时序撞车**——历史 P3 reset 在 `.onChange(previewAnchorID)` 把 state.rect=.zero。但 SwiftUI 异步顺序常是新卡 publish → state=新 rect → **之后** P3 reset 抹回 .zero。**修法**：删 P3 reset。新卡不在视口的边角退化成"短暂错位一帧"，scrollPulse 滚进视口后自动修正

**教训**：依赖 framework 隐式副作用做"自然 fix"是定时炸弹。审 PreferenceKey / Observable 跨边界路径，如果某条 fix 依赖"反正某地方会再 fire 一次"——显式 trigger 比依赖隐式好。

**paste 路径调 `panel.hide(immediate: true)` 同步 orderOut**，不走 140ms 淡出动画。动画期间 panel 仍在 windowserver window list 中被当 key window，CGEvent Cmd+V 路由到 panel 而非目标 app（Zed Preview / Claude for Desktop 类 app 易触发）。Esc / 点空白 / windowDidResignKey 等非 paste 关闭路径默认 `immediate=false` 保留淡出。**不要回退**：paste 路径改回默认动画立刻让 Cmd+V 注入失效

**self-write 防回环不需额外改动**——`CGEvent.post` Cmd+V 让目标 app 自己读 pb，`changeCount` 不变 watcher 直接跳过；`pasteBack` 内 `suppressUpToCurrent` 已推过 self-write 跳变。**不要**叠"以防万一"防御层。

**macOS 钥匙串密码框被 Secure Event Input 拦 CGEvent 是期望行为**——密码框本就不该被剪贴板管理器自动粘，不修。

### SwiftUI TextField + 列表导航——NSEvent local monitor

TextField 抢焦点后吞箭头键，父视图 `.onKeyPress(.upArrow/.downArrow)` 不触发。

`SearchPanelController.installKeyMonitor` panel show 时装 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`，按 keyCode（126↑ / 125↓ / 36,76 Return / 53 Esc）拦截返 nil 吞掉，路由到 `AppState.navigate(by:)` / `onPaste`。

注意：NSEvent 非 Sendable，进 `MainActor.assumeIsolated` 闭包前先取 `Int(event.keyCode)` 出来再用，否则 Swift 6 严格并发不过。

### onTapGesture(count:1) + (count:2) 的 500ms 延迟

并存让单击必须等"会不会有第二击"消歧 500ms。当前方案：双击挂 `.gesture(TapGesture(count: 2))`，单击挂 `.simultaneousGesture(TapGesture(count: 1))` 跳出消歧立即触发。

### 鼠标点击不触发滚动

`.onChange(of: selectedID) { proxy.scrollTo }` 会让鼠标点击的 selection 变化也强制居中滚。`AppState.scrollPulse` 计数器只在键盘导航时 `&+= 1`；`SearchView .onChange(of: scrollPulse)` 触发 `proxy.scrollTo`。点击只改 `selectedID` 不动 scrollPulse。

### VACUUM INTO 必须 writeWithoutTransaction

GRDB `pool.write { ... }` 自动包事务，SQLite 禁止事务内 VACUUM。要用 `pool.writeWithoutTransaction { ... }`。位置：`Snapshot.takeSnapshot`、`Exporter.writeSQLite`。

### Watcher 自身实现的两个轮询事实

- NSPasteboard 没有 KVO/通知 API，只能 200ms 轮询 `changeCount`
- 类型优先级：`file > image > rtf > html > url > string`
- concealed/transient 类型直接 skip（密码管理器约定）

### HMAC 签名：path-encoded body sha256，middleware 不读 body

签名输入：`<ts_ms>\n<METHOD>\n<path_with_query>\n<sha256_hex(body)>`，hex 在 header `X-DP-Body-SHA256`。中间件**只**校验 header hex 跟签名匹配——**不读 body**（让 multi-MB blob 不占中间件内存）。Handler 读完 body 必须**自己**再 sha256 跟 header 对比，否则攻击者可伪造合法签名 + 任意 body。`/blob` 的 handler 还多校验 path sha = body sha = header sha 三方一致。

### Worker 不能用共享 AsyncStream.Iterator 跨 Task

Swift 6 strict concurrency 拒绝同一 iterator 实例 capture 进多个 child task。`PullWorker` 持 `currentSleep: Task<Void, Error>?`，每 tick 起新 sleep task，`wake()` nonisolated 调用 actor method 取消让 sleep 提前结束。`wake()` 必须 `nonisolated`，否则外部回调（WSNotificationClient.onCursorAdvanced）拿不到非阻塞接口。

### Server 序列化 Item：pinned 必须是 Bool

`Item.Codable.pinned: Bool` 期望 JSON true/false。误用 `pinned ? 1 : 0` 会让对端 decode 报 typeMismatch。位置：`Server.itemToJSON`。

### CLI 子命令在 SwiftUI 接管之前 exit

`@main DuoPasteApp.init()` 第一行调 `CLI.dispatchAndExitIfApplicable()`。命中子命令直接 `exit(0|1)`，根本不让 SwiftUI 拉起 NSApp。无参 / 未识别参数返回，daemon 流程照常。子命令实现住在 `DuoPasteCore.Admin`（纯函数便于单测），CLI 只做 argv 解析 + exit。

### 空格预览浮窗：SwiftUI 子树 + `.id(kindKey)` 切换

`PreviewPanelController` 是独立 `NonKeyHUDPanel`，hostingView 里 SwiftUI 子树按 `media` 路由到 `PDFPreviewBody` / `Image` / `TextPreviewBody` / `FilePreviewBody`。kind 切换靠 `contentBody().id(kindKey)` 强制 SwiftUI clean swap。代价：切回同 PDF 时 PDFView 重建首页重渲，肉眼"封面闪一下"——**接受这个 trade-off**，user 已确认。

**不要回退到** "所有 kind NSView 全 lazy 挂在一个 container 只 toggle isHidden" 方案——`NSImageView` / `PDFView` 的 `intrinsicContentSize` 会通过 macOS 14+ `NSHostingView.updateAnimatedWindowSize` 私有路径推回 NSWindow 触发 auto-grow，panel 涨到图片像素值（497×706 → 1440×906）。所有拦截方案试过都无效（`contentMinSize/contentMaxSize` / `sizingOptions=[]` / `intrinsicContentSize` override / `setFrame` override / `didResizeNotification + revert`——后者跟 windowDidLayout 同步死循环 NSException 崩 daemon）。

唯一守得住的路径是**不让 NSImageView / PDFView 持续挂在 hosting view 的 SwiftUI 子树里**——`.id(kindKey)` 切 kind 时 SwiftUI 整体 tear down NSViewRepresentable，AppKit 没东西可推就不 auto-resize。位置：`PreviewOverlay.swift` 的 `PreviewPanelContent.contentBody` + `kindKey`。

### Settings 窗口 traffic lights 自管 placement（macOS 26）

Paste 风格 Settings：sidebar 卡片视觉上**包住** traffic lights（红绿灯漂在 sidebar 卡片内部 ~14px 处）。macOS 26 上**不要**通过 SwiftUI 让卡片扩到 titlebar 区——所有 `safeAreaInsets / safeAreaRegions=[] / .ignoresSafeArea() / wrapper topAnchor 负偏移 / .padding(.top, -32)` 路径都验证失败。根本原因：macOS 26 NSHostingView 在 `fullSizeContentView` 窗口里把 SwiftUI **渲染**硬剪到 `window.contentLayoutRect`（=contentView.frame 减 titlebar 32px），跟 hostingView frame / SwiftUI 报告的 safeArea 都没关系。

**正确姿态**（位置：`AppDelegate.showSettings` + `positionSettingsTrafficLights`）：
- NSWindow styleMask 含 `.fullSizeContentView`，`titlebarAppearsTransparent = true`，`titleVisibility = .hidden`，**不含** `.resizable`（`maxSize = win.frame.size` 锁尺寸）
- contentView = `FullBleedHostingView`（NSHostingView 子类 override `safeAreaInsets` 为 0；单靠它**不够**但仍要保留让 SwiftUI 内部布局正确）
- **关键**：拿 `window.standardWindowButton(.closeButton / .miniaturizeButton / .zoomButton)` 三个按钮，`contentView.addSubview(button, positioned: .above, relativeTo: nil)` 从 frameView 重新挂到 contentView，再 `setFrameOrigin` 手动定位（topInset=40 / leftInset=34 / spacing=25）
- 补 `TrafficLightGlyphOverlay` 自定义 NSView 覆盖三按钮上方 hover 时自画 ×/-/+ glyph（按钮 reparent 后系统 hover-glyph 路径断了）。`hitTest` 返 nil 让点击穿透到真按钮
- `windowDidResize` hook 重 position

**不要回退**：`positionSettingsTrafficLights(in:)` 看起来 hacky ~30 行函数但所有 SwiftUI 层"干净方案"都验证过失败。

## 已知环境坑

### SwiftPM 克隆 GRDB.swift 弱网必断

GRDB.swift 仓库 ~200MB / 113k objects，弱网下 `swift package resolve` 死在 ~130MB。应对：(1) 再试一次；(2) 手动 shallow `git clone --depth 1 --branch v7.x.y https://github.com/groue/GRDB.swift.git .local-deps/GRDB.swift` 改 `.package(path: ".local-deps/GRDB.swift")`；(3) **不要**急着换库或自己写 sqlite3 wrapper；(4) **不要**改全局 git config `http.postBuffer`。

### Swift Testing 在 macOS 26 SDK 上的"假错"

报错形如 `macro expansion @Test:26: error: '@const' value should be initialized with a compile-time value` / `global variable must be a compile-time constant to use @section attribute`——**几乎都是自家代码错误的下游表现**，最常见 **Int64 字面量溢出**（上限 ≈ 9.22e18；`10_000_000_000_000_000_000` 即超界）。

排查：`swift test 2>&1 | grep -E "error:" | head`，自家错排在 @Test 宏错前。修了那个宏错自动消失。**不要**搜 swift-testing issue 或回退 XCTest。

### GRDB 7 在 async 上下文挑 async 重载

`async throws` 测试里调 `db.pool.read { ... }` 必须 `try await`。sync 重载在 async 上下文编译不过。

### SwiftPM 6.3 / macOS 26 partial-mirror bug——"no versions match" 假阳性

**症状**：fresh clone 后 `swift build` 报 `no versions of '<pkg>' match`，但 `Package.resolved` 锁的版本存在，错误一个个轮流冒。

**根因**：Swift 6.3 把 mirror 搬进了 `./.build/repositories/<pkg>-<hash>/`（**不在** `~/Library/Caches/org.swift.swiftpm/` 了），且 macOS 26 SDK 上对某些依赖创建的 bare mirror 配置不完整——坏 mirror 缺 `fetch = +refs/*:refs/*` + `mirror = true` → refs/ 空只拉到 main HEAD → SPM 看不到任何 tag。判别：坏 mirror `git -C <dir> fsck` 报 `invalid HEAD` + `No default references`。

**修法**——bulk patch + refetch，不动 `Package.swift` / `Package.resolved` / 全局缓存：

```sh
cd .build/repositories
for d in */; do
  grep -q "mirror = true" "$d/config" 2>/dev/null && continue
  git -C "$d" config remote.origin.fetch '+refs/*:refs/*'
  git -C "$d" config remote.origin.mirror true
  git -C "$d" fetch origin --quiet && echo "fixed: ${d%/}"
done
cd ../..; swift build
```

**不要走的歧路**（均试过无效）：`--force-resolved-versions` / 清 `~/Library/Caches/org.swift.swiftpm/...` / 清 manifest.db / `rm -rf .build` 单独清（SPM 重建仍是 partial config 立刻复发）/ 改 `Package.swift` 缩版本范围。

fix 不持久——每次 `rm -rf .build` / `swift package clean` 后按上面 bulk patch 跑一遍。

## 构建 / 测试

`swift build` / `swift test` / `swift build -c release`（install 脚本自动跑）。PullWorker / BlobLazyPull 偶发 flake，单跑 `--filter` 必绿。

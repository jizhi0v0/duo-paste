- **同步路径**：每个 peer 一对 `(PullWorker, WSNotificationClient)`。PullWorker 周期 `/since` 拉对端增量到本机 item 表（origin=对端 device_id）；WSNotificationClient 订 `/sync/ws` cursor_advanced 帧 → 收到 `worker.wake()` 跳过 sleep（< 1s 延迟）。WS 断了退化为周期 pull
- **HTTP routes**：`GET /health` + `GET /blob/<sha>` + `GET /since` + `GET /app_icon/<bundleID>` + `GET /search` + `GET /endpoints` + `GET /auth/revocations` + `POST /bump/<id>` + `POST /pin/<id>` + `POST /pair/<pin>` + `DELETE /item/<id>`；WebSocket = `/sync/ws`。无 push/ingest 路径
- **CaptureService**：永远走 `Database.nextIngestNs` stamp（writer tx 内）；merge candidate 带 `origin_device == selfDeviceID` 过滤防 bump 对端行；commit 后回调 `onCursorAdvanced` 让 server 端 `WSBroadcaster` fan-out
- **Pin/unpin owner routing**：pin 是带稳定 `operation_id` 的绝对值命令。只有 `item.origin_device` owner 能 canonical 修改 `item.pinned + ingested_at_ns`；非 owner 只做 optimistic UI + 写 v13 `pin_operation`，绑定 owner 的 PullWorker 投递。owner 的 `pin_operation_receipt` 保证重试不二次执行；requester 看到达到 receipt cursor 的 `/since` canonical replay 才清“等待同步”。禁止回退到 mirror 整行广播、wall-clock LWW 或 pinned OR merge（OR 会吞 unpin）
- **Search**：`SearchProvider` 每次刷新只调一次 `SearchAPI.searchSummary`。非空/时间范围只做一次 content fold 后派生 list/total/facets；空查询走 v16 `search_fold` projection。fold 契约不变：文本跨 origin 同 text_full；blob 同 SHA 仅折叠 15s 内跨 origin 副本；qualifier/pinnedOnly 后置过滤。非空排序为 `(prefix_match DESC, captured_at_ns DESC)`，空搜索为 `(pinned DESC, captured_at_ns DESC)`。**list / total / chip 同一 snapshot、同一 fold 口径**是硬不变量。Mac/iOS 都只搜本机 SQLite，不调用远端 `/search`
- **跨设备 dedup**：两层防御——capture 层（同 origin 同 text 永久合并，merge candidate 加 origin 过滤）+ search fold 层（跨 origin 兜底）。Blob 的物理文件本来就按 SHA 内容寻址只存一份；不同设备产生的 metadata 行为保持 mesh 对称不删库，UI 将 15s 内跨 origin 同 SHA 折为一张卡并保留最早的原始文件名。同 origin 主动重复 copy 不折叠
- **Blob**：内容寻址 BlobStore（linkItem 不 moveItem，见 §"BlobStore 并发竞态"）；`mesh.storage_mode=full`（默认）同步元数据后拉齐字节，`optimized` 才在 paste/preview 时按需 GET `/blob/<sha>`（TaskGroup 30s 超时 race，见 §"blob 懒拉的不变量" #8）
- **HMAC + device credential 认证**：canonical string 仍是 `<ts>\n<METHOD>\n<path>\n<body_sha256_hex>`。可信 Mac 可用 mesh 根 secret；iOS 用独立 request secret 签名并携 `X-DP-Credential` 密封 token。请求一旦带 token 就只能走 credential 验证，任何失败都不得降级根 secret。middleware 不读 body，handler 读完后必须复核 body hash；WS upgrade 同模板，upgrade 后 frame 不签
- **iOS pairing channel binding**：Mac QR v2 只含 endpoint + 当前 TLS leaf DER SHA-256，PIN 仍独立显示；iOS `/pair` 必须用 `PinnedCertificateDelegate` 在发送 PIN 前精确匹配 leaf。Bonjour 只发现/引导扫码，v1/HTTP/无 pin 不得降级直配。leaf 轮换使旧 QR 失效但不撤销已有 credential；QR cache key 必须跟证书内容变化
- **OCR**：本机 own-origin image 跑 Vision OCR 写 `text_full` 进 FTS5；markDone 触发 onCursorAdvanced 让对端 < 1s 同步 OCR 结果（共享 wsBroadcaster fan-out 路径），peer FTS5 trigger 自动重 index
- **mesh-doctor CLI**：探 /health (deviceID + skewMs vs expected) + pull_cursor + max(ingested_at_ns) + missing blob，并检查本机 leaf certificate 的 DNS SAN、not-before/not-after 与 30/7/1 天 inclusive warning；`--json` 输出 Codable schema。只读。任一 peer/blob/TLS 异常退出 1
- **安全诊断包**：`diagnostics-export` 与 Settings → 关于共用 `DiagnosticBundleExporter` 固定白名单，只含 mesh doctor JSON、只读 `quick_check`、版本、重新编码的脱敏 config、manifest 和白名单运维日志。禁止接入历史 `Exporter`、SharedSecret、device credential/token、BlobStore 或私钥；目录 0700、文件 0600
- **WS auth rotation**：`WSBroadcaster.rotationIntervalSec` 内部默认 4h（已不从 config 暴露）并周期主动 close 所有连接；单设备撤销或收到新撤销 tombstone 时也立即 rotate。合法 client backoff 重连并重新认证，被撤销 credential 不能恢复连接
- **依赖**：GRDB 7 + Hummingbird 2 + HummingbirdTLS + hummingbird-websocket（具体版本看 Package.resolved）
- **测试**：HTTP/WS 集成测试统一使用系统分配端口和真实 bind readiness；`TestSyncServerFixture` 负责隔离 DB/blob、超时与 graceful shutdown。禁止重新引入随机端口或 readiness sleep
- **百万行 benchmark**：R4.1/R4.2 只由 `duo-pasted benchmark-library --workspace ...` 显式 manual/nightly 触发，普通 `swift test` 禁止生成 10 万/100 万行。workspace 必须远离默认 Application Support，`--rebuild` 只删带版本 marker 的目录。8GiB 默认是 sparse placeholder，报告必须同时写 logical/allocated bytes；`cold_fts` 只保证 connection-cold，不能宣称清过 macOS page cache；`first_screen_render` 必须从按键开始，引用生产 `SearchRefreshPolicy.delayNanoseconds`，再走真实 `AppState + SearchView + NSHostingView`。`count_by_kind` 现代表生产空查询完整 summary，并有 p95 `<150ms` gate。baseline 见 `benchmarks/results/`
- **灾难恢复**：`snapshot-list` / `snapshot-verify` 只读；`snapshot-restore` 永远先在 `.snapshot-recovery-*` staging 库跑 migration、`integrity_check` 和可选 peer catch-up，daemon 未 bootout 时拒绝真实提交。提交前保留 `snapshots/recovery-safety-*/db`，DB 目录用同卷 `RENAME_SWAP` 原子换入，换入后重开验证，失败 swap 回旧库。只有一次性 `DisasterRecovery.refill` 可接收 active own-origin；普通 PullWorker guard 禁止放宽
- **iOS 端**：
  - **WS zombie 检测**：URLSessionWebSocketTask 没协议层 PING，走应用层 `WSMessage.ping/.pong`——`PeerWebSocket.pingLoop` 每 30s ping，10s 内没 pong 抛 `WSError.pongTimeout` 重连。`PeerSyncCoordinator` 5s tick + 90s heartbeat staleness 兜底降级到 `.error("链路无响应")`
  - **POST /bump 客户端**：`HistoryCellView.triggerCopy` 先 `store.bumpToFront` 乐观顶 + UCB 写 pasteboard，**再** `coordinator.bumpItemOnServer` async 让 Mac DB 也顶。404/410 swallow
  - **POST /pin 客户端**：一次用户动作对所有 Mac route fan-out 同一个 operation ID。owner 返回 applied 即清 pending；非 owner 返回 pending 时卡片显示“等待同步”，后续 canonical `/since` 行确认目标值再清。旧 daemon 2xx 无 `state` 按 applied 兼容
  - **Bonjour + QR 配对**：Mac `BonjourAdvertiser` publish `_duopaste._tcp` 仅供发现；Settings QR v2 含 host/port/tls + `cert_sha256`，6 位 PIN 独立显示且 60s 轮换，secret/PIN/token 绝不进 QR。iOS `PeerDiscovery` 只引导 `QRScannerView` 扫码，`PinnedCertificateDelegate` 验 leaf 后才提交 PIN。Info.plist 需 `NSBonjourServices=_duopaste._tcp` / `NSCameraUsageDescription` / `NSLocalNetworkUsageDescription`
  - **每设备凭据**：新 PIN body 带 stable device ID/name/platform，response 只给独立 request secret + AES-GCM token，不返回 mesh 根 secret。secret/token 仅存 `ClientCredentialKeychain`（AfterFirstUnlockThisDeviceOnly）；旧 `sharedSecretHex` 只作一次迁移源，迁移成功必须清 UserDefaults。所有 HTTP probe/request 与 WS upgrade 必须同时透传 token
  - **完整 metadata mirror**：`Caches/HistoryStore/mirror.sqlite` 保存完整 item + FTS + `ios-metadata-mirror` cursor；`HistoryStore.items` 只加载最近 1000 条作为 bounded UI projection，不是同步上限。非空 query 和 qualifier-only 都在 detached task 里走本机 `SearchAPI`，断网时语义不降级为 contains
  - **iOS strict sync 状态**：每页进度只能在 item/source ledger/cursor 同一 writer transaction 提交后发布。`has_more=false` 且 source count audit 通过后，才把 strict checkpoint 原子写到 `Application Support/DuoPaste/metadata-sync-checkpoint.json`；它必须与可清理的 `Caches/HistoryStore/mirror.sqlite` 分离。checkpoint 存在但 mirror 缺失、行数或 cursor 落后时必须显示 rebuilding/“当前结果不是全集”，不能伪装 ready。取消保留逐页 cursor；用户 pause 同时禁止前台自动 pull 与 BGAppRefreshTask，直到显式继续/立即刷新
  - **BlobCache 磁盘 + LRU**：`Caches/Blobs/v1/<ab>/<cd>/<sha>.bin` 三层目录持久化跨启动。500MB cap 按 mtime 升序 evict。Detached IO 避免大图同步读卡 main actor
  - **前后台统一 pull**：前台 WS 只唤醒 `/since`；`PeerSyncCoordinator` 与 BGAppRefreshTask（id `io.duopaste.ios.background-pull`）都调用 `MetadataMirrorStore.applyPage`，item rows + 二元 cursor 在同一个 writer transaction 提交，cursor 只单调前进。app 回前台从 SQLite 刷新 bounded projection；WS 后台不能跑（iOS 限制）时降级周期 HTTP pull
  - **旧 JSON 一次性迁移**：升级时 `items.json` 只做 `INSERT OR IGNORE`，逐 ID 校验 SQLite 成功后才删除。旧 `cursor.json` 绝不沿用——它可能已经越过被 1000 条 cap 丢掉的历史，SQLite 首轮必须从 zero 全量重拉。blob 仍由独立 500MB LRU 管理

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
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted --help
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted init-secret
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted mesh-init --peer URL...
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted mesh-doctor
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted mesh-doctor --json
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted diagnostics-export ~/Desktop
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted snapshot-list
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted snapshot-verify latest
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted snapshot-restore latest --peer URL --dry-run
~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted retry-failed-ocr
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
- `snapshots/recovery-safety-*/db/` 恢复提交前的原 DB 安全副本（不会被 snapshot prune）
- `device-id` 本机稳定 UUID

部署产物：`~/Applications/DuoPaste.app` (`…/Contents/MacOS/duo-pasted`) + `~/Library/LaunchAgents/io.duopaste.agent.plist` + 日志 `~/Library/Logs/duo-paste/duo-pasted.{out,err}.log`。

签名：Developer ID Application: BO LI (`RS59HDH7Y3`) + hardened runtime，Bundle ID = `io.duopaste.daemon`。macOS TCC 按 Team ID + Bundle ID 判 Accessibility 权限——`install-agent.sh` 重装 cdhash 变但 DR 不变，权限自动跟。**禁止回退 adhoc 签名**：adhoc 让 Accessibility 列表旧 cdhash 失效，每次 install 都得重勾。

### launchctl 速查

```sh
launchctl print    gui/$UID/io.duopaste.agent      # 状态
launchctl bootout  gui/$UID/io.duopaste.agent      # 停
launchctl kickstart -k gui/$UID/io.duopaste.agent  # 强重启
```

### CI 发布链（Sparkle）+ self-hosted runner

`.github/workflows/release.yml`：触发 = **push 到 main**（自动出 beta）或 **打 `vX.Y.Z` tag**（出 stable）或 **workflow_dispatch**（手动，默 beta）。三段 job：`prepare`（ubuntu，定 version/channel + build 号）→ `build/sign/notarize`（self-hosted mac）→ `publish`（self-hosted mac，发 GitHub release 到 `jizhi0v0/duo-paste-releases` + 写 appcast.xml）。version 规则：tag→剥 `v` 当 stable version；main push→`0.1.<commitcount+1000>-beta+<sha>`。CFBundleVersion(build)=`git rev-list --count + 1000`，跟 tag 字符串无关，Sparkle 按它单调比新旧。

**mac job 跑在 self-hosted runner 上**（`runs-on: [self-hosted, macOS, ARM64]`）——签名/公证要 GUI session 的 login keychain，GitHub 托管 runner 给不了。**repo 级 runner 只绑一个仓库不能跨仓共享**：duo-paste 和 claude-usage 各需自己的 runner 实例。mini 上是 `~/actions-runner`（claude-usage）+ `~/actions-runner-duopaste`（duo-paste），各装成用户态 LaunchAgent service（`actions.runner.<owner>-<repo>.<name>`，跑在 GUI session）。新增实例：另起目录 → `./config.sh --url .../duo-paste --token <一次性> --labels self-hosted,macOS,ARM64` → `./svc.sh install && ./svc.sh start`。

**三个 self-hosted-on-dev-machine 特有的坑（都已解，别回退）**：

1. **runner service 缺代理 → git checkout 直连 github 超时**。LaunchAgent 不 source shell profile，拿不到 `HTTPS_PROXY=127.0.0.1:6152`（Surge）。**修法**：runner 根目录放 `.env` 注入 `HTTPS_PROXY/HTTP_PROXY=http://127.0.0.1:6152` + `NO_PROXY=localhost,127.0.0.1,.apple.com,.icloud.com`。**这是机器本地配置、不在仓库里**——换机/重装 runner 必须重建。notarytool 走 NSURLSession 用系统网络设置不认这俩 env，不受影响（apple 走 NO_PROXY 直连）。
2. **codesign 按名字签报 ambiguous**。开发机 login.keychain 已装同名 Developer ID 证书，签名搜索列表含 build.keychain + login 两张同名 → codesign 拒签。**修法**（release.yml 已实现）：从 build.keychain 抽证书 SHA-1 指纹按指纹签（`SIGN_IDENTITY_HASH`），唯一锁定 CI 导入那张 + 保留 login 在列表不打断本机。GitHub 托管 runner 不撞（login 没那证书）。
3. **`SPARKLE_ED_PRIVATE_KEY` secret 必须填**。Sparkle EdDSA 私钥在 MBP login keychain（`generate_keys --account duopaste` 生成，service `https://sparkle-project.org`，account `duopaste`），对应嵌客户端的公钥 `5Ws5rSunj3IH...`。导出：`security find-generic-password -w -a duopaste -s 'https://sparkle-project.org' | gh secret set SPARKLE_ED_PRIVATE_KEY --repo jizhi0v0/duo-paste`。**必须 `-a duopaste`**——不带 account 的 `security` 可能抓到 default `ed25519` account 的老密钥（public key 不同），签出的 DMG 客户端校验 "improperly signed" 失败。

**SU 公钥两处对齐**：`release.yml` env `SU_PUBLIC_ED_KEY` + `install-agent.sh:26` 必须同一个值，换密钥对要一起改 + 重装 daemon。发版前 secret 清单：`SPARKLE_ED_PRIVATE_KEY` / `MACOS_CERT_P12_BASE64`+`_PASSWORD` / `MACOS_SIGN_IDENTITY` / `KEYCHAIN_PASSWORD` / `APPLE_ID`+`APP_SPECIFIC_PASSWORD`+`APPLE_TEAM_ID` / `RELEASES_REPO_TOKEN`。

## 开发工作流

LaunchAgent 装好后常驻 release daemon。**不能** `swift run` 直接调试——双进程重复捕获、抢全局快捷键、SQLite WAL 多写者竞争。流程：改代码 → `swift build && swift test` → `./scripts/install-agent.sh` 重装（幂等）。跑 dev 二进制前先 `launchctl bootout gui/$UID/io.duopaste.agent`，跑完恢复。日志 `tail -f ~/Library/Logs/duo-paste/duo-pasted.err.log`（含 "UI ready" / "snapshot ok" / `[HummingbirdCore] Server started` 正常诊断，不全是错误）。

bootstrap 报 `5: Input/output error` → sleep 2s 后手动 `launchctl bootstrap ... && launchctl kickstart -k ...`。**launchd "languishing"**：反复 bootout/bootstrap 触发速率限制，`launchctl print` 显示 `state = languishing`——等 10-30s 到 `launchctl print` 返回 `Could not find service`（彻底 boot out）再重新 bootstrap。不要 sudo / 不要改 plist。

## 关键设计决策（不要回退）

### daemon 退出码 / KeepAlive gate（Sparkle 方案 A 前提）

plist `KeepAlive={SuccessfulExit:false}` + `ThrottleInterval=30`（install-agent.sh 写出）。退出码语义是硬契约——改动 daemon 退出路径前先对齐：

| 退出码 | 来源 | launchd 行为 | 用途 |
|---|---|---|---|
| `0`（clean） | `NSApp.terminate`（StatusBar「退出」/ Sparkle 装更新后宿主自退） | **不重启**（SuccessfulExit:false gate） | 用户主动退 = 真停；Sparkle 让位安装 |
| `1`（fatal） | `applicationDidFinishLaunching` bootstrap `AppDependencies()` 失败 | 重启（≥30s/次，ThrottleInterval 压 tight loop） | bootstrap 多为 transient（DB 临时被占 / snapshot 中），重试自愈 |
| `173`（restart） | `AppDelegate.restartDaemon`（Settings「立即重启」） | 重启 | 重读 config；数值仅为日志区分 fatal，launchd 只认 0 vs 非 0 |

要点：
- **bootstrap 失败必须 `exit(1)` 不能 `NSApp.terminate`**——后者走 exit 0 被 gate 当正常退出永不重启，daemon 就此死掉。
- **Settings 重启必须 exit 非 0**（用 173）——exit 0 会被 gate 吃掉，重启按钮失效。
- **`ThrottleInterval=30` 只节流「上次启动后 30s 内」的 respawn**——正常运行数小时后的崩溃自愈 / 重启按钮不受影响，只压 bootstrap 持久失败的 tight loop（exit 1 立刻又被拉起）烧 CPU + 灌日志。`launchctl kickstart -k`（含 relaunch helper）强制重启不走 throttle。
- 「退出」菜单弹 NSAlert 确认——讲清 daemon 真停、恢复要 kickstart / install-agent.sh，避免误以为只是关窗。

### Capture 字节守门（防意外 Cmd+C 巨物）

`config.capture.{max_blob_mb=32, max_text_kb=512}`。超 cap → CaptureService 跳过入库返 `.skippedTooLarge`，**NSPasteboard 自身不受影响**（Cmd+V 仍正常）。文件路径走 `.file` kind + 字符串形式（< 1KB）永远过文本 cap，Finder 复制 50GB 工程文件夹零受影响。

UI 反馈：AppState.recentSkip + SearchView orange skipBanner（✕ 关闭 + 5 分钟自动消失）。文案明确说"剪贴板本身正常可直接 Cmd+V 粘贴"——防止用户以为 daemon 挂了。

**作用域**：per-device capture policy 不是 sync-wide invariant。peer 间 HMAC + 共享 secret = 已认证内部边界，不重校单字段大小。

### Capture app 排除 + 临时暂停（隐私双 gate）

`config.capture.excluded_bundle_ids` 是 per-device 列表，bundle ID 匹配忽略大小写；Settings 支持从当前运行 app 选或手填，并热重载。暂停只存当前 daemon 进程，菜单栏支持 5 分钟 / 30 分钟 / 直到手动恢复；有限期暂停由 `AppState` timer 自动清，daemon 重启也恢复捕获。

必须保留两道门：

1. `PasteboardWatcher.capture()` 在读取 `pasteboard.types` / body 和可疑正文诊断日志**之前**调用动态 gate。
2. `CaptureService.ingest` 在任何 DB/blob 写入前再次跑 `CapturePolicy`，防未来调用方绕过 watcher。

excluded/paused outcome 不 refresh、不 wake OCR，`CaptureService.broadcastIfNeeded` 不推进 cursor，因此不进入 mesh。任何跳过都不改写 NSPasteboard，Cmd+V 始终正常。concealed/transient marker 对允许捕获的 app 继续在 extract 前跳过；不要把隐私 gate 移到正文读取或日志之后。

回归测试：`CapturePolicyTests.swift`（config、匹配、暂停边界、DB/blob 零写入）与 `PasteboardWatcherCaptureGateTests.swift`（真实 named pasteboard gate 拒绝）。

### SearchProvider 永远走本机 fold-aware（chip 总数对齐）

`SearchProvider.search` 永远只走一次 `SearchAPI.searchSummary`——内部 fold-aware（文本跨 origin 同 text_full；blob 按近时间跨 origin 同 SHA），无 list/count/facet 四次重复查询，也无 "raw count vs fold count" 双路径。

**核心不变量**：mesh 拓扑下 `item` 表混存本机 own + 对端 peer 行，跨 origin 同 text 是常态。raw count 会把 ToDesk/Continuity 副本算一遍跟对端口径不齐——回归测试 `searchProviderTotalCountMatchesFoldedRowCount`。

### 自定义日期范围必须按本地 Calendar 切日界线

`SearchTimeRange.custom` 的起点是较早选中日期的本地 00:00，终点是较晚选中日期的**下一本地 00:00 减 1ns**，再交给 `SearchQuery` 现有的 inclusive `>= fromNs` / `<= toNs`。不能用固定 `24h * 天数` 推导自定义日期边界——DST 会有 23/25 小时日。预设“最近 24h/7d/30d”仍保持滚动时长语义。

`AppState.refresh()` 必须先产生同一份 `SearchTimeBounds`，再把它的 `fromNs/toNs` 同时传给 SearchProvider；列表、真实总数、kind chip 和 file sub-kind chip 都从这一个 `SearchQuery` 派生，不能各自重算日期。

### 空查询 fold projection：item 是真源，dirty refresh 后才读

v16 的 `search_fold` / `search_fold_dirty` 是可重建的本机派生索引，不进入 Item Codable、`/since` 或 mesh。item trigger 只记录 old/new group key；空查询前 `Database.refreshSearchFoldProjection` 必须在 writer transaction 内精确重算 dirty group，随后 reader 才能读 projection。正常 capture/pin/bump/delete 只重算受影响 content group；dirty 超过 1000（初次同步、restore、benchmark bulk load）才流式全量 rebuild。

projection 的 display 行仍由 `Item.foldByTextFull` 产出，不能在 trigger/SQL 里另写一份 blob cluster 算法。文本 bulk rebuild 的 winner/pin 可用 window SQL，但 blob 必须按 SHA 流式喂同一个 fold 真源；file sub-kind 必须走 `ItemClassifier.fileSubKind`。自定义时间范围会改变“哪些 sibling 参与 fold”，因此不得读全局 projection，必须回退一次 Swift fold summary。

### 保存搜索视图：独立本机文件 + 写盘后发布

命名搜索视图住 `~/Library/Application Support/duo-paste/saved-search-views.json`，不塞进 `config.json`，也不进入 DB/mesh。原因：SettingsModel 会持有启动时 Config 快照；若视图是 Config 字段，用户保存新视图后再应用旧 Settings 快照会把它静默覆盖。独立文件是 per-device 单一真相，顶层 schema version 必须先于完整 payload 解码检查，未来版本拒绝降级覆盖。

`AppState.saveCurrentSearchView` / `deleteSavedSearchView` 必须保持 `local library mutation → SavedSearchViewStore atomic write + 0600 → savedSearchViews publish → StatusBar callback` 顺序。**写盘失败绝不能先改内存数组或菜单栏**，否则 UI 显示已保存、重启后却消失。菜单栏只保存稳定 view ID，点击时回 AppState 查当前数组、应用完整 filter 后再打开 panel。

### 搜索排序契约：非空 relevance-first；空查询 pin-first

- 非空 query：`(prefix_match DESC, captured_at_ns DESC)`。preview 或 text_full 任一以完整 query 起始都算同一个 prefix tier；其余 FTS 命中属于 contains tier。没有 24h 窗，pin 不参与搜索排序。
- 空 query：`(pinned DESC, captured_at_ns DESC)`，保留剪贴板首页的置顶语义。

SQL 端 `fetchHitsRaw` 内 `instr(LOWER(IFNULL(col, '')), LOWER(?)) = 1` 算布尔 `_prefix` 列。prefix 占位符必须 `args.insert(at: 0)`（SELECT 列表 `?` 在 WHERE/LIMIT 之前）。Swift 端 `fetchHitsFolded.prefixScore` 跟 SQL 口径**必须**一致——fold 后 SQL 算的 `_prefix` 列已丢，必须重算。

回归测试 `SearchPrefixBoostTests.swift`：prefix 胜过 pinned contains / 老 prefix 不失效 / pin 不打乱 contains 组 / preview 与 text_full 同 tier / 空查询仍 pin-first / fold 后保持 relevance。

### 文本永久 dedup（capture + search 双层）

文本 kind（`text/url/file`，即 `blob_sha256 IS NULL`）走永久 dedup：

1. **Capture 层**（`CaptureService.ingestText`）：`config.capture.text_merge_window_sec` 默认 `null` = 永久。同 kind + 同 `text_full` + 未删 + **同 origin** 再次 capture，合并 bump `captured_at_ns + ingested_at_ns` 让对端 /since 看到刷新。**merge candidate 必须加 origin_device 过滤**——不然合表后 bump 对端行（等于本机改了别人数据）。`0` = 禁用，`N>0` = 固定窗口。`blob mergeWindowSec` 独立保留 300s
2. **搜索层**（`Search.fetchHitsFolded`）：oversample 后按 `text_full` 跨 origin fold。Winner = `max(capturedAtNs)`，**pinned OR 聚合**（任一条 pinned → fold 结果 pinned=true）。`count` / `countByKind` 同源 fold 保证 list / total / chip 口径一致

为什么要两层：Capture 层不够 —— ToDesk/Continuity 把 mini pasteboard 同步到 MBP，两台 watcher 各抓一条 own-origin 行（不同 origin_device），mini 行通过 PullWorker 进 MBP 的 item 表，搜索时跨 origin 同 text 仍要 fold。Fold 层不够 —— 同设备短时重复 copy 仍插多行，存储白浪费。

Blob 不做永久 SHA fold：相同图片可能被用户在同一设备主动复制多次，时间线应保留。仅当同 SHA、不同 `origin_device`、UUIDv7 原始 capture 时间差 ≤ 15s 时，判定为 Continuity / 跨设备回环副本。展示代表取最早行以保留 CleanShot 等原始文件名，排序时间取组内最新；删除展示卡必须 tombstone 整个 blob fold group，避免 peer 行立即复活。`captured_at_ns` 会在 paste 后 bump，分组时间必须优先从 UUIDv7 id 取。

**不要回退到固定窗口默认值**：5 分钟窗口在 ToDesk 场景下两端时间错位常超窗，再现"同文本并排两条"问题。

### `preview` vs `text_full` 字段语义：UI 必须读 textFull

`item.preview` = `CaptureService.makePreview` 截到 **280 字符 + `…`** 的网络短预览（给 `/since` 列表省 payload）。`item.text_full` = 原始可粘贴完整内容（受 `config.capture.max_text_kb` 守门，默 512KB）。两个字段 server 端**同时**写入 DB + 通过 `/since` JSON **同时**下发（无截断）。

**UI 端必须用 textFull**——fallback 到 preview 会让卡片末尾出现 server 加的 `…` 截断符，且文本短于 lineLimit 时填不满 frame。

**统一入口**：`Item.cardPreviewSource(maxChars:)` (Sources/DuoPasteCore/Item.swift) —— textFull 优先 + `prefix(maxChars)` 防御性截断。macOS 卡片传 512，iOS HistoryCellView 传 300。

**规则范围 = 卡片/列表 cell 展示路径**。其它路径（详情大预览、导出、open-with、paste-merge、本地 contains 过滤等）**允许** `item.textFull ?? item.preview`。受约束的卡片/列表调用点（不要再加新的 `item.preview ??` fallback）：
- `Sources/duo-pasted/SearchView.swift` 的 `previewAttributedForTextCard` else 分支
- `Sources/duo-pasted/SearchView.swift` 的 `previewText` else 分支
- `iOS/DuoPaste/Models.swift` 的 `displayPreview`

**iOS 升级边界**：旧 `items.json` 可能缺 `textFull`，只用于 SQLite 首屏 continuity；cursor 从 zero 重拉后 canonical `/since` 行会覆盖它。不得恢复 JSON 持久化或迁移旧 cursor，否则 1000 条 cap 之外的历史会形成永久缺口。

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
7. **保留无关字段**——hotkey / capture / ocr 不动；Config.write 走 nested merge 让未来未知字段保留，但会显式洗掉废弃的 `shared_secret_keychain_account`。回归测试 `meshInitPreservesUnrelatedConfigFields`

### blob 懒拉的不变量

`mesh.storage_mode`（`full` 默认，`optimized` 懒拉）+ `AppDelegate.pasteBack` lazy 路径 + `PullWorker.fetchBlobsEager` 三处协同。`eager_blobs` 只作为老配置 decode 兼容键，写盘时会被清除：

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

**不要回退到无条件 +1**：旧实现配合 WSBroadcaster 默认 4h 的内部 rotation 主动 close 所有连接，约 60h 后所有长连接 consecutiveFailures 累到 budget=15，触发 `exit(1)`，launchd 重启——每隔几天来一次而没人知道为啥。

回归测试：`longLivedConnectionResetsFailureCounter`。

### /pair TLS-only 护栏

`SyncServer.requirePairingTLS`（默 true）+ `tls == nil` 时 `/pair/<pin>` handler 在 PIN 校验**之前**返 503。daemon 启动期若不满足且 `pairingService != nil`，stderr 立刻打 WARN。测试用 `requirePairingTLS: false` 显式 opt-out。

**为什么硬护栏**：`/pair` response body 含独立 request secret + credential token（legacy 空 body 仍可能返回 mesh root secret）。Tailscale 路径 WG 加密兜底 OK，但 iOS 配对常走 `.local` / 直连 IP——不进 tailnet，纯 HTTP 会把认证能力暴露给被动 LAN 监听者。PIN 单次 + 5 次封锁挡不住“监听一次成功配对”。

**现有边界**：iOS `TrustAnyDelegate` 为兼容 `.local` hostname / 私有 CA 接受任意 leaf，TLS 当前只提供加密，不提供 server identity；PIN 方案不抵抗能终止并实时转发配对请求的主动 MITM。不要把 TLS-only 护栏描述成证书校验或 channel binding。若要收紧，需另做 QR 携带 leaf fingerprint / PAKE 等配对协议升级，不能直接打开系统默认校验而破坏现有 `.local` 与 Ponte 部署。

**不要回退**：未来 daemon 跑 plain HTTP 时必须升级到 TLS 才能用 iOS 配对，不是放宽这条。回归测试 `pairReturns503WhenTLSRequiredButMissing`。

### TLS 到期检查与安全诊断包

`TLSCertificateInspector` 只读取 leaf certificate 公共字段：DNS SAN、not-before、not-after；不接收也不打开 `tls_key_path`。expiry 阈值是 inclusive：剩余 `<=30d` / `<=7d` / `<=1d` 逐级告警，expired 与 not-yet-valid 同样让 `mesh-doctor` 非零退出。时间必须通过 `now` 注入测试，不能用会随年月失效的断言。

`DiagnosticBundleExporter` 是与历史内容导出器完全独立的安全边界：输出文件名固定白名单，config 从已解析的 `Config` 重新编码并移除 URL credentials / 私钥路径，日志只保留明确运维前缀，其他行整行替换。API 不接收 shared secret、device credential/token、私钥 bytes 或 BlobStore，也不复制 DB；SQLite 只执行 read-only `PRAGMA quick_check`。新增输出必须先扩充 sentinel 扫描测试，确认剪贴板正文、blob、root/request secret、credential token 和 PEM 私钥均无法进入包内。回归测试：`TLSCertificateInspectorTests.swift`、`DiagnosticBundleTests.swift`。

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

**第一层** 所有程序化写回都必须走 `watcher.pasteBack { ... }` actor barrier —— barrier 先 flush pending 的真实用户复制，写入期间 `isPasteBackInFlight=true` 挡 polling tick，写后内部 `suppressUpToCurrent()` 把 `lastChangeCount` 推到当前 `pasteboard.changeCount`。普通粘贴、R3.3 纯文本粘贴和预览选区复制都走这条入口。**不要**直接从 AppDelegate 调 private suppression，也不要重新引入 `lastSelfWriteChangeCount` 静态比较方案（实测不稳，写多 type 或时机错位会漏）。

**第二层** `Watcher.extract()` 顶端 `frontApp.pid == self.pid → return nil`。suppressUpToCurrent 只挡程序化写回；用户在搜索框 / Settings 文本框**手动** Cmd+C 时 changeCount 真实自增 suppressUpToCurrent 来不及介入——只有 self-pid 过滤能拦下来，否则触发"复制 → 入库 → 又出现 → 再复制"回环。

已知副作用接受：self frontmost 期间所有 changeCount 自增被吃掉。这是期望行为，跟"在 search 框敲字然后 Cmd+C 整段当新条目入库"二者只能选一，已选不污染。

### 纯文本粘贴：只写 `.string`，两层 suppression 都保留

R3.3 的“粘贴为纯文本”只支持 `.text/.rtf/.html`；URL、图片、文件不显示该动作。快捷键是 `⇧⌘V`，多选时必须全部符合白名单才执行，不能静默跳过其中的非文本项。资格、decoder 路由和多选 all-or-nothing 语义统一在 `PlainTextPaste`；RTF/HTML decoder 失败必须返回 nil，绝不能把 raw markup 当纯文本兜底。

`Copyback.writePlainText` 用 `NSAttributedString` 解码富文本后只写一个 `.string` representation，再由 `PasteInjector` 向目标 app 注入普通 `Cmd+V`。**不要**向目标 app 转发 `⇧⌘V`——各 app 对该快捷键的实现不一致，写 plain pasteboard + 普通 paste 才是稳定协议。

写回必须走 `watcher.pasteBack` 防本机 watcher self-capture；成功后还要按**实际解码后的 pasted text**记录 `PasteSuppressionSet.fingerprint(text:)`，挡 Universal Clipboard 在其他 Mac 捕获后反弹回来的 mirror echo。原 RTF/HTML item 的 raw `textFull` 指纹与纯文本输出不同，不能复用 `fingerprint(forItem:)`。

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

### Settings 窗口由 SettingsWindowPresenter 持有（不是 SwiftUI Settings scene）

页面内容仍是系统 `TabView` + `Form` + `Section` + `LabeledContent`（拆在 `Sources/duo-pasted/Settings/`），**不要**自绘 sidebar / 卡片、也不要隐藏系统 traffic lights 后自画——窗口材质、标题栏、交通灯交给系统。但**承载窗口**是 `SettingsWindowPresenter` 里的 AppKit `NSWindow`，不是 SwiftUI `Settings` scene：accessory app 在别的 app 活跃时，scene 会声称 `showSettingsWindow:` 已处理却根本不 materialize `NSWindow`。

三条硬不变量：

1. **`App.body` 不得注册任何会产生窗口的 scene** —— 空 `Settings {}` 占位也不行。它是可恢复窗口，`NSQuitAlwaysKeepsWindows=1`（默认）下每次启动被系统重开成空白 900×450 "DuoPaste Settings" 并抢 key。当前写法是 `MenuBarExtra(isInserted: .constant(false))`，什么都不渲染；真状态栏是 AppKit `StatusBarController`
2. **永远保持 `.accessory`，用 `activate(ignoringOtherApps: true)`** —— accessory app 本来就能持 key 窗口（见 `NSApplicationActivationPolicyAccessory` 头文件）。**不要**回退到"提升 `.regular` → 轮询 20 次等 `isActive && isKeyWindow` → 兜底 `.floating` → 关窗恢复 `.accessory`"那套：提升会插 Dock 图标 + app 菜单（菜单栏 extras 跳动），give-up 路径的 `setActivationPolicy(.accessory)` 反而把刚显示的窗口藏掉——这就是用户看到的"设置窗口闪一下就消失"。裸 `NSApp.activate()` 是**协作式**的、文档明说不保证成功，别换
3. **激活必须留在触发它的用户事件内** —— `StatusBarController.openSettings` 直接调 `AppDelegate.showSettings()`，**不要**再包 `DispatchQueue.main.async` "等菜单 tracking loop 结束"：macOS 14+ 协作激活会拒绝这种延迟到事件之外的请求

测量注意：焦点是全局状态，用脚本驱动打开 Settings 时别的 app 正持焦点会污染 `isKeyWindow` / `isActive` 读数（实测给出自相矛盾的结果）。手动点开看标题栏，别信脚本轮询。

### 预览浮窗上屏必须脱离 SwiftUI layout pass

`SearchPanelController` 的 `onPreviewChange` 是 SwiftUI value action，**同步**跑在 `SearchView` 的 `NSHostingView.layout()` 里。在那里面直接 `PreviewPanelController.show` → `panel.orderFront` 会重入 ViewBridge，搜索框 `TextField` 背后 NSTextField 的跨进程补全列表抛未捕获 NSException：

```
'<NSRemoteView: com.apple.SafariPlatformSupport.Helper SPCompletionListServiceViewController>
 notified of <duo_pasted.NonKeyHUDPanel> but expected (null)'
in -[NSRemoteView containingWindowWillOrderOnScreen:]
```

崩过两次（2026-07-22 SIGABRT；2026-07-24 AppKit 改走 `_crashOnException` 后表现为 EXC_BREAKPOINT SIGTRAP，crash log 里 `asiBacktraces` 才有真因）。修法是 `DispatchQueue.main.async` 推到下一个 runloop turn 再 order，并在 async 闭包内**重读** `previewShown / currentItem / selectedCardWindowRect`——期间可能已被 hide 或箭头切卡换了目标。**不要**改回同步调用；同理任何新的"布局回调里开窗/上屏"路径都要走同一条 defer。

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

`swift build` / `swift test` / `swift build -c release`（install 脚本自动跑）。

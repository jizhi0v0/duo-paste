# iOS / Mesh Sync 待办 plan 集

每节自包含 — 拿一节扔进新 session 让 Claude 干。优先级由上至下,合作做 (1+3) → (2) → (4) → (5/6)。

最后更新:2026-05-17 · 提出场景:iOS 端 tap 复制"不顶到最前 + 图片无即时反馈"两个症状根因调查。当时已落地的本机修(乐观顶 + 图片 badge)只解决体感,根因(WS 真活检测、跨设备一致 bump 机制、UCB 可观测性)仍在。

---

## 1. iOS WebSocket 僵尸检测 + 主动 ping(优先级 P0)

### 问题
URLSession `URLSessionWebSocketTask` 在 iOS 上有老毛病:server 真死了 / 链路 NAT 重写 / iOS 锁屏后,client 端 `receive()` 不抛错继续阻塞,状态机一直停在 `.connected`,UI 显示绿色 antenna 但实际链路死了。今天用户复制"WS 绿但不通"大概率是这个 — 而不是真的 WS 失败。

参考 memory `feedback_urlsency_ws_no_readiness_ping.md`:"URLSession WS transport 不做 readiness ping ... 靠 receive throw 报错"。这条 memory 是 macOS 端总结的,iOS 端同样适用且更严重(iOS 后台 / 锁屏路径多)。

### 现状
- `iOS/DuoPaste/PeerWebSocket.swift` 内 `connectOnce()` 阻塞在 `task.receive()`,没主动心跳
- `Sources/DuoPasteSync/WSBroadcaster.swift` 也没主动 ping(检查一下,可能也得改)
- `Sources/DuoPasteCore/WSProtocol.swift`(refactor 后挪到 Core)里 `WSMessage.ping` / `.pong` 类型已定义,但当前 client/server 都只在 `handle` 里 `break` 不处理 — 没人发也没人响

### 做法
**iOS 端主动 ping**:
1. `PeerWebSocket` 加 `pingInterval: TimeInterval = 30` 常量
2. `connectOnce` 起两个并发 task:
   - 一个跑现有 `receive()` 循环
   - 一个定时 `task.send(.string(WSMessage.ping(now: ...).encodeJSON()))` 每 30s 一次
3. 收 pong 时更新 `lastPongAt`;另一个 task 在 ping 后 sleep 10s 检查 `lastPongAt > pingSentAt`,否则 `task.cancel(with: .abnormalClosure)` 强制重连
4. 用 `withThrowingTaskGroup` race 两 task,任一抛错 → 整个 connectOnce 抛 → 进 backoff 重连

**server 端配合**:
- `WSBroadcaster` 收到 `ping` 帧应回 `pong`。检查现有 `handle` 路径,如果没回就加
- 也可以让 server 主动 ping(双向都加),但单向已够检测半死链路

**还要做**:`coordinator.status` 在长时间没 advance / pong 时降级显示橙色 warning(目前只看 ws.state,所以 zombie 时一直绿)。`PeerSyncCoordinator` 加 `lastHeartbeatAt`,定时 check,> 90s 没 heartbeat → status = .error("链路无响应")

### 文件清单
- `iOS/DuoPaste/PeerWebSocket.swift` — 加 ping task + lastPongAt + zombie 检测
- `iOS/DuoPaste/PeerSyncCoordinator.swift` — 加 lastHeartbeatAt + UI 降级
- `Sources/DuoPasteSync/WSBroadcaster.swift` — 确认 / 加 pong 回响
- `Sources/DuoPasteCore/WSProtocol.swift` — `ping/pong` 类型应已存在,确认 encode/decode 完整
- 测试:`Tests/DuoPasteSyncTests/WSProtocolTests.swift` 加 ping/pong roundtrip

### 验收
- Mac 端 `pkill -9 duo-pasted` 杀掉 daemon → iOS 30-40s 内状态从绿降到橙(原先一直绿)
- iOS 后台 5 分钟回前台 → 要么 WS 已重连(状态绿),要么至少看到一次 `.backoff` 切换日志
- 修改后 iOS 复制文本 → Mac 真 capture → WS 推 cursor_advanced → iOS 收到 → 顶到前面延迟 < 3s(原先可能无穷大)

### 范围
半天 ~ 1 天

---

## 2. 服务端 `POST /bump/<id>` endpoint(架构决策,优先级 P1)

### 问题
iOS 端"乐观顶"(已落地)只是本机视觉欺骗 — 对端 Mac / 另一台 iOS 看不到这次 bump,因为 Mac DB 没改。要做**跨设备一致的"复制即顶"**,得在 Mac 加 mutating endpoint 让 iOS push bump 请求。

### 架构冲突
CLAUDE.md 明写:
> **HTTP routes**:仅剩 `GET /health` + `GET /blob/<sha>` + `GET /since` + `GET /sync/ws`(HTTP Upgrade)。`POST /ingest` + `PUT/HEAD /blob` + `GET /search` 都已删(PR 4 + PR 6)

加 `POST /bump` 打破"mesh peer 间只 GET pull"约定。需要回到设计层重新讨论:
- mesh 拓扑下 mutating 操作的语义?(iOS 是不是 mesh peer,还是 client-only?)
- origin_device 怎么处理 — iOS bump Mac 上 origin=Mac 的行,bump 之后 origin 改吗?(应该不改,只 bump 时间戳)
- 多 iOS 设备并发 bump 同一行的竞争?(写串行 ok,但需要明确语义)
- POST 是不是只能针对自己 origin 的行,还是可以 bump 任意行?(剪贴板语义:任意行都能 bump,只要 caller 通过 HMAC 认证 = 同一 trusted mesh)
- 跟现有 `Item.pin/unpin`(已有 mutating 操作但是本机,不通过 HTTP)的关系

### 设计选项
- **A 加 POST /bump/<id>**:写新行,broadcast cursor_advanced,/since 拉回。Mac 端 `Database.bumpCapturedAt(id, ownDeviceID)` 改 captured_at_ns + ingested_at_ns 在写 tx 内
- **B 加更通用的 POST /item/<id>/touch**:不只能 bump,还能 pin / unpin。语义统一为"修改单行元数据"
- **C 设计反向 capture endpoint**:iOS 把自己的"复制动作"作为新 capture 推过去,Mac 走正常 ingestText 路径(命中已有同 text 行 → bump)。问题:这是 PR 4 删掉的 `POST /ingest` 复活,跟"mesh pull-only"冲突更深

选 A 最小化,选 B 最有扩展性。先讨论。

### 文件清单
- `Sources/DuoPasteSync/Server.swift` — 加 POST /bump/:id route + HMAC body 校验
- `Sources/DuoPasteCore/Database.swift` — 加 `bumpCapturedAt(id:, ownDeviceID:)` 方法
- `Sources/DuoPasteCore/CaptureService.swift` 或新建 — 调用 + onCursorAdvanced 触发
- `iOS/DuoPaste/PeerClient.swift` — `bumpItem(id:)`
- `iOS/DuoPaste/HistoryCellView.swift` — `triggerCopy` 内 `store.bumpToFront` 后 push 给 Mac
- CLAUDE.md "HTTP routes" 段更新
- 测试:`Tests/DuoPasteSyncTests/BumpHTTPTests.swift` + 跨设备集成测试

### 风险 / 非目标
- **不要走全功能 mutating API** — POST /bump 是定向单行单字段,不开 "POST /item/<id>/update" 全字段编辑(那是另一个 architectural shift)
- HMAC body 签名要包含 id + ts,防 replay
- Mac 端写 tx 内必须用 nextIngestNs 保 commit 顺序 = ingested_at_ns 顺序(/since cursor 正确性前提,见 CLAUDE.md "ingested_at_ns 必须在 writer tx 内 stamp")
- WSBroadcaster fan-out 让其他 peer 秒同步

### 验收
- iOS A tap 复制条 → iOS A 顶到最前(原已 work)+ Mac 顶到最前(< 2s)+ iOS B 顶到最前(< 2s)
- 删 iOS 端"乐观顶"代码改成纯 server-driven?或保留乐观顶作 fallback。讨论时定

### 范围
1-2 天,含设计 review + CLAUDE.md 文档更新

---

## 3. iCloud UCB(Universal Clipboard)通不通的诊断 + 文档(优先级 P0,跟 #1 并做)

### 问题
今天验证"复制不顶"很可能不只是 WS 问题 — UCB(iOS↔Mac iCloud Universal Clipboard)根本没透过去,Mac watcher 完全没 capture 到 iOS 那次复制,自然没行可 bump。如果 #2 (`POST /bump`) 做了,UCB 就不是关键路径;但 #2 没做之前 UCB 是唯一让 Mac 端 reflect iOS copy 的路径。

### 诊断步骤(每个跑一次,记录结果)
1. **iOS 设备 + Mac 同一 iCloud 账户 + 同一 Wi-Fi + 蓝牙开**(UCB 物理前提)
2. iOS 任意 app(Notes)复制一段文本 → Mac 任意 app(TextEdit)Cmd+V → 应能粘贴。**这条不通 = UCB 本身没开,跟 daemon 无关**
3. iOS DuoPaste app tap 复制 → Mac `tail -5 ~/Library/Logs/duo-paste/duo-pasted.err.log`,几秒内应看到 capture 相关日志(`capture inserted` / `capture merged`)。**这条不通 = UCB 通但 Mac NSPasteboard 监听没看到 / 看到了但 CaptureService 跳过**
4. Mac 端确认 `Watcher` 抓 UCB:开 macOS Notes app → Cmd+C 一段;iOS app tap 复制不同内容;再回 Mac Notes Cmd+V → 应粘到 iOS 那段。证明 Mac NSPasteboard.general 收到了 UCB

### 修法分支
- 步骤 2 失败 → 用户配置问题,不在代码层。**写文档** `docs/ucb-prerequisites.md` 列前提条件
- 步骤 3 失败但步骤 4 通过 → CaptureService 跳过了某条件(可能 `suppressMarkerTypes` 误伤,或 changeCount 时机错位)。要排查 Watcher → CaptureService.ingestText 路径
- 步骤 3 通过 → UCB 链路其实是通的,问题在 WS 推 / iOS pull 那段 → 跟 #1 合并解决

### 文件 / 输出
- `docs/ucb-prerequisites.md`(新建)列前提 + 验证步骤
- 如果发现是 Watcher 跳过,改 `Sources/DuoPasteCapture/PasteboardWatcher.swift`
- 如果发现是 CaptureService 误判,改 `Sources/DuoPasteCore/CaptureService.swift`

### 验收
- 文档存在,任一用户照 4 步走能定位自己卡哪
- 如果有代码层 bug,iOS 复制后 Mac 端 5s 内 log 出现 capture 行

### 范围
0.5 ~ 1 天(主要是诊断,代码改动看发现结果)

---

## 4. iOS Settings 真做 Bonjour / mDNS 自动发现(优先级 P2,onboarding 体验)

### 问题
当前 iOS Settings 要求手填 peer URL + 64 字符 hex secret。普通用户接受度差。最早讨论 AppIconStore 时用户就问过"能否做成 discover",当时为聚焦延后。

### 设计
- **Mac daemon**:`NWListener` 起 `_duopaste._tcp` Bonjour 广播,TXT record 含 `device_id` + `port` + 可选 `tls=1`
- **iOS Settings**:`NWBrowser` 浏览 `_duopaste._tcp`,列出本网段 Mac peers → 用户 tap 选择
- **secret 配对**:三个候选
  - **a) Mac 显示 6 位数字 + 倒计时**(类似 iOS Continuity pairing),iOS 输数字 → Mac 走临时 channel 把 secret 发给 iOS
  - **b) QR 码** — Mac 弹 Settings 弹出 QR 包含 secret hex,iOS 摄像头扫
  - **c) ASA(Apple Setup Assistant style)** — 太复杂,跳过

推荐 b 简单可靠;a 最像原生 Apple 体验但需要临时 token endpoint;c 不做。

### 文件清单
- `Sources/duo-pasted/BonjourAdvertiser.swift`(新建)— NWListener 广播,daemon 启动时跑
- `Sources/duo-pasted/SettingsView.swift` — 加 "配对 iOS"按钮 → 显示 QR(用 CoreImage CIFilter.qrCodeGenerator)
- `iOS/DuoPaste/PeerDiscovery.swift`(新建)— NWBrowser + Observable list
- `iOS/DuoPaste/SettingsView.swift` — 新加 discover sheet:"扫描附近 Mac" tab + "扫 QR 配对" tab
- iOS Info.plist 加 NSCameraUsageDescription + NSBonjourServices `_duopaste._tcp`

### 风险 / 非目标
- secret 暴露 — QR 只在 Mac Settings 用户主动点"配对"时显示,默认不显示。倒计时 60s 自动消失
- 不做 cross-tailnet 发现 — Bonjour 限本网段,符合"不走公网"原则
- 旧 Settings 手填路径**保留**(高级用户 / 不同网段场景)

### 验收
- iOS 新装 app → Settings → "扫描附近 Mac" → 看到本机 daemon → tap → 弹 QR 扫码界面 → 扫 Mac 显示的 QR → 自动填好 URL + secret → 连接成功 < 10s
- daemon 停了 → iOS Settings discover 列表实时移除

### 范围
1-2 天,含 iOS 摄像头权限 + QR 生成 + Bonjour 双端

---

## 5. iOS 后台自动 pull(优先级 P3,可选)

### 问题
iOS app 被后台挂起 → WS 断 → 重新打开 app 要等 reconnect + pull 才看到新条目。Mac 端实时,iOS 体感"打开等一下"。

### 做法
- `URLSession backgroundConfiguration` 起后台 pull task
- `BGAppRefreshTask` 注册 iOS 后台周期任务(`Info.plist` `BGTaskSchedulerPermittedIdentifiers`)
- 后台 pull 拿到新行 → 本地存(用 GRDB iOS 走 SwiftPM 加进来,或先简化:存 UserDefaults / 文件)
- 打开 app → 内存 store 从持久化恢复 → 立即显示最新

### 风险
- iOS 后台权限严格,`BGAppRefreshTask` 调度是 best-effort,系统决定何时跑
- 后台跑 WS 不现实(iOS 不允许长连接后台),只能改成"后台周期 HTTP pull"
- 加持久化(磁盘 cache items)是另一坨工作,牵连 HistoryStore 改架构

### 验收
- iOS 后台 30 分钟后打开 app → 历史里包含至少最近 5 分钟的 Mac 端新 capture(看 iOS 系统给的实际后台调度频率,可能更慢)

### 范围
中等,~ 2 天。先验证用户痛点优先级,iOS 后台限制大,改善可能有限

### 非目标
- 不做 push notifications(需 APNs server + 后端,大改)
- 不做 Live Activities(只适合特定场景如直播)

---

## 6. iOS BlobCache 永久 dedup + 磁盘 cache(优先级 P3)

### 问题
- Mac 端 `BlobStore` 是内容寻址持久化的(`blobs/<ab>/<cd>/<sha>.<ext>`),自然 dedup
- iOS 端 `BlobCache` 是 append-only 内存字典,只有 `resetAll()` 才清。同 sha 多次 `fetch` 走 inflight 去重 OK,但**重启 app 全丢**,且**大量 image 历史**会堆爆内存(OOM)

### 做法
跟 `AppIconCache`(已落地的磁盘持久化)同款:
- `Caches/Blobs/<sha[0..2]>/<sha[2..4]>/<sha>.bin` 三层目录避免单目录文件数过多
- `BlobCache.fetch(sha)` 先查内存 → 查磁盘 → 网络
- 加 LRU size cap(e.g. 500MB),超出删旧文件
- 磁盘格式版本号(类似 AppIconCache `diskFormatVersion = 2`),encoder 改了能 bump 失效

### 文件清单
- `iOS/DuoPaste/BlobCache.swift` — 加磁盘读写 + LRU
- 不动 `PeerClient`(已经原子 fetchBlob)

### 验收
- iOS 复制图片 → kill 重启 app → 同图再 tap 复制 → 不发网络请求(磁盘命中)
- 200 张大图后 `Caches/Blobs/` 总大小 ≤ 500MB(LRU 生效)

### 范围
~ 半天

---

## 优先级综合建议

| Plan | 优先级 | 估时 | 依赖 |
|---|---|---|---|
| #1 WS ping | P0 | 0.5-1d | 无 |
| #3 UCB 诊断 + 文档 | P0 | 0.5-1d | 无 |
| #2 POST /bump | P1 | 1-2d | 跟用户对齐架构方向 |
| #4 Bonjour discover | P2 | 1-2d | 无 |
| #5 iOS 后台 pull | P3 | ~2d | #6 磁盘持久化先做 |
| #6 iOS BlobCache 磁盘 | P3 | ~0.5d | 无 |

**推荐顺序**:1 + 3 并行(诊断 + 真修)→ 跟用户对齐 2 → 4 → 6 → 5。

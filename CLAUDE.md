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
  - `SearchAPI.searchUnion` + `fetchHitsMirror`：item + item_mirror 各超量取 limit+offset，**先按 id dedupe（取 capturedAtNs 最大那份，无视 pinned 状态）**，再按 (pinned DESC, captured_at_ns DESC) 排序，最后裁 limit/offset
  - `SearchProvider.Mode.localMirror(stalenessSec:)`：`mirrorLastPullNs()` 非 nil → 直接走 `searchUnion`，**不**打远端
  - UI banner：`.localMirror` 灰色「本地镜像 · 更新于 Xs/m/h 前」；`.remoteFallback` 黄色保留
- **Capture 字节守门 完成**：`config.capture.{max_blob_mb=32, max_text_kb=512}` 默认。意外复制超大对象跳过入库（NSPasteboard 自身不受影响，Cmd+V 仍正常）。UI 端 orange skipBanner 5 分钟自动消失 + 手动 ✕ 关闭。详见下文设计决策段
- **M3 第三刀 未开始**：`promote-to-primary` / `audit-push` / `migrate-primary` / blob 懒拉 / 时钟偏移检查
- **测试**：107/107 通过（`swift test`）。新增 PullWorkerTests 含同进程 server + 真 HTTP 全链路；SearchUnionTests 覆盖排序/dedup/pinned/软删/FTS；SearchProviderTests 含 mirror-skip-remote 回归保护
- **依赖**：GRDB 7.10.0 + Hummingbird 2.22.0 + HummingbirdTLS（SwiftPM 远程依赖）
- **下一站**：**M3 第三刀**——DR 运维子命令 (`promote-to-primary` / `audit-push` / `migrate-primary`) + blob 懒拉 + 时钟偏移 sanity check。详细拆解见 plans/...moonlit-wave.md

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
~/Applications/duo-paste/duo-pasted --help          # 子命令列表
~/Applications/duo-paste/duo-pasted init-secret     # 首次部署：生成 32 字节 shared secret
~/Applications/duo-paste/duo-pasted retry-failed    # 把 push_state=failed 全部重置回 pending
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

`pull.enabled=true` 才会跑 mirror（DR + 离线全集搜索；M3 才真实现 pull worker，目前只是 schema 占位）。`shared-secret` 文件三台机同份（`scp` 过去 + `chmod 600`）。

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
swift test               # 跑 13 个测试
swift build -c release   # release（install 脚本自动跑）
```

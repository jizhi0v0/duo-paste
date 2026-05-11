# duo-paste

替换 Paste.app 的自托管剪贴板管理器，Apple-only。M1（单机 Mac）已通过 LaunchAgent 上线 daily-driver；M2（multi-Mac primary/client）所有代码路径已完工，等真上 Mac mini + Tailscale 联调。

正式架构计划：`plans/https-pasteapp-io-macos-ios-paste-moonlit-wave.md`。

## 项目当前状态

- **M1 完成**：捕获 + SQLite/FTS5 + 内容寻址 blob + SwiftUI 搜索窗（NSPanel HUD）+ ⌥⌘V 全局快捷键 + 菜单栏 + LaunchAgent + 小时级 snapshot
- **M2 代码完成 + primary 已上线 mini（HTTPS）**（client 端待 MBP 联调）：
  - Schema migration v2_mirror（item_mirror / item_mirror_fts / pull_cursor 预留）
  - `config.json` + `serve` / `primary_url` / `pull.*` 配置
  - HMAC-SHA256 签名 + 反 replay（5min 窗口）
  - Hummingbird 2 server：`/health` `/ingest` `/blob` (HEAD/GET/PUT) `/search`，可选 TLS（`tailscale cert` 签发的 PEM）
  - Client push worker（actor）+ blob 先于 ingest 顺序保证 + 退避重试
  - SearchProvider 远端优先 + 本地降级 + UI banner
  - CLI 子命令：`init-secret` / `retry-failed` / `--help`（SwiftUI App.init 拦截）
  - 集成测试：同进程 server + worker 真 HTTP roundtrip 全覆盖
- **M3 未开始**：mirror pull worker / `promote-to-primary` / `audit-push` / `migrate-primary`
- **测试**：63/63 通过（`swift test`）
- **依赖**：GRDB 7.10.0 + Hummingbird 2.22.0 + HummingbirdTLS（SwiftPM 远程依赖）
- **下一站**：把 MBP（`100.68.44.27`）作为 client 加入联调（拷 shared-secret + 配 primary_url 即可，详见 `docs/deploy-multi-mac.md`）；或动手 M3 mirror

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

### NSPasteboard 自写回环——双层防御

剪贴板管理器自己粘回内容会触发自己的监听器看到 changeCount 变化。曾试过"记 `pb.changeCount` 再等值比较"方案，实测**不稳**（写多 type 或写时机微妙错位都会漏）。当前两层：

1. **写后立刻** `watcher.suppressUpToCurrent()`——把 watcher 内部 `lastChangeCount` 推到当前 `pasteboard.changeCount`，下一 tick 自然 `cc == lastChangeCount` 跳过。位置：`AppDelegate.pasteBack(_:)`
2. **Watcher.extract() 顶端**：`frontApp.pid == ProcessInfo.processInfo.processIdentifier → return nil`——搜索面板打开期间任何剪贴板活动都不入库（用户在搜索框 Cmd+C 也不污染）

**不要**重新引入 `lastSelfWriteChangeCount` 静态比较方案；**不要**删 self-pid 过滤。

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

# duo-paste Roadmap

最后更新：2026-07-17。

这份文件是**未来工作的唯一入口**。`CLAUDE.md` 只记录已经落地的不变量、best practice 和硬护栏；`plans/` 下的文件是历史实现计划，不能直接当成当前 backlog。

## 当前基线

- macOS 已可 daily-driver：本机捕获、SQLite/FTS5、OCR、slash qualifier、置顶/删除、多选、预览/Open With、导出、Sparkle 更新、snapshot 与 blob 水位回收均已落地。
- 多 Mac 已是对称 mesh：每个 peer 本地写入，通过 `/since` pull + WebSocket 通知同步；支持 Tailscale/Surge Ponte、full/optimized blob、本地 fold-aware 搜索和 `mesh-doctor`。
- iOS 已不是“只读概念版”：已有 Bonjour 发现、QR leaf binding + PIN 配对、完整 SQLite/FTS metadata mirror、离线搜索、复制 bump、置顶、删除、后台 pull、独立 Blob LRU 和 WS zombie 检测。
- 当前已知真实缺口：滚动升级期仍接受不带 device token 的 legacy HMAC，旧 iOS 需重新配对后才具备单设备撤销能力；搜索仍缺自定义时间窗和保存视图。

## 优先级规则

| 级别 | 含义 |
|---|---|
| P0 | 可能造成数据状态不可信、恢复路径不可用或 CI 不能稳定给结论 |
| P1 | 明显影响隐私、日常可靠性或核心跨端体验 |
| P2 | 高频体验优化，允许在 P0/P1 清完后推进 |
| P3 | 产品探索；先验证需求，不默认进入实现 |

规模约定：S = 约 1 天内，M = 2–4 天，L = 1–2 周，XL = 需要拆成多个独立 plan。

## 总览

| ID | 工作项 | 类型 | 优先级 | 规模 | 状态 |
|---|---|---|---|---|---|
| R0.1 | 消灭网络集成测试 flake | bug fix | P0 | M | ✅ done |
| R0.2 | 跨 origin 置顶最终一致 | bug fix | P0 | L | ✅ done |
| R0.3 | 可验证的 snapshot / mesh 恢复流程 | reliability | P0 | L | ✅ done |
| R0.4 | README / 部署文档切到现行 mesh 架构 | docs | P0 | M | ✅ done |
| R1.1 | 按 app 排除捕获 + 临时暂停 | privacy / feature | P1 | M | ✅ done |
| R1.2 | TLS 到期预警 + 可脱敏诊断包 | ops | P1 | M | ✅ done |
| R1.3 | 每设备凭据与撤销 | security | P1 | L | ✅ done |
| R1.4 | iOS 配对通道绑定 | security | P1 | M | ✅ done |
| R2.1 | iOS 本地 SQLite/FTS mirror | feature / perf | P1 | L | ✅ done |
| R2.2 | iOS 首次同步进度与离线状态 | UX | P2 | M | ✅ done |
| R3.1 | 自定义起止时间筛选 | feature | P2 | S | ready |
| R3.2 | 保存搜索视图 | feature | P2 | S | proposed |
| R3.3 | 纯文本粘贴动作 | feature | P2 | S | proposed |
| R4.1 | 8GB / 百万行搜索基准与回归门槛 | optimization | P1 | M | proposed |

## R0 — 可靠性与可恢复性（Now）

### ✅ R0.1 消灭网络集成测试 flake

**完成记录（2026-07-16）**：所有 `SyncServer` 集成测试已改用 `port: 0` + channel 实际监听端口；统一 fixture 负责临时 DB/blob、bind readiness、超时和 graceful shutdown。另修复 `MeshSupervisorReconcileTests` 脱离结构化并发的异步记账竞态。`swift test` 连续 20 次全绿，定向 flake 用例 50/50 全绿，测试目录无随机/固定监听端口与 readiness sleep。2026-07-17 R2.2 最终门又捕获到 PullWorker actor 测试用固定 200–300ms 睡眠猜 tick 完成的长尾；现改为等待单调 tick fence/可选 blob hydration，完整全集通过，相关 36 项再连续 10 轮（360/360）全绿。

**问题**：`PullWorkerTests` / `BlobLazyPullTests` 等仍使用随机固定端口，全集并发时可能撞端口或共享生命周期；“单跑必绿”不能作为长期质量门槛。

**已完成**：

- 所有同进程 HTTP/WS server 改用 `port: 0`，从 channel 读取实际监听端口。
- 抽一个统一的 test server fixture，负责 readiness、graceful shutdown、临时 DB/blob 目录和超时。
- 去掉 `Int.random(in:)` 端口和依赖 sleep 猜 server ready 的测试。

**验收（已通过）**：

- [x] `swift test` 本机连续 20 次全绿；CI 连续 5 次由合入后的流水线继续观察。
- [x] 测试目录无固定/随机端口分配；失败时能定位到具体 request，不留下 server task。
- [x] 删除 `CLAUDE.md` 中“已知偶发 flake”的豁免说明。

### ✅ R0.2 跨 origin 置顶最终一致

**完成记录（2026-07-16）**：v13 增加持久化 operation queue 与幂等 receipt；pin/unpin 已改为带稳定 operation ID 的 owner-routed 绝对值命令。非 owner 只做不推进 cursor 的乐观更新并显示“等待同步”，PullWorker 向 owner 投递后以 `/since` canonical replay 收敛；Mac/iOS 都沿用同一 operation ID 重试。定向 Core/HTTP/真实 HTTP A↔B 收敛测试覆盖 pin、unpin、快速反向、owner bump/OCR/reopen、离线队列与重复 receipt；完整 `swift test`（246 + 544 + 9）及 iOS simulator build 均通过。

**问题**：在非 origin Mac 或 iOS 上置顶一条 mirror item 后，origin 设备不会收到该修改；origin 后续 bump/OCR/delete 产生的整行回放可能把 `pinned=true` 静默覆盖掉。

**设计倾向**：保持“每条 item 单一归属”，把 pin/unpin 做成带幂等 operation ID 的 owner-routed 元数据命令；origin 暂时离线时本地乐观更新并排队重试。不要用 wall-clock LWW，也不要用只会让 unpin 失效的简单 OR merge。

**验收（已通过）**：

- [x] A(origin)、B(mirror)、iOS 三端任意一端 pin/unpin，三端最终一致。
- [x] pin 后 origin 再发生 bump、OCR 更新或 daemon 重启，pin 不丢。
- [x] origin 离线时 UI 明确显示“等待同步”；恢复后自动收敛，重复重试不二次翻转。
- [x] 旧客户端仍可读新数据；迁移有回滚路径。

### ✅ R0.3 可验证的 snapshot / mesh 恢复流程

**完成记录（2026-07-16）**：新增 `snapshot-list`、`snapshot-verify`、`snapshot-restore [--peer] [--dry-run]`。恢复始终先在 staging candidate 跑 migration、`integrity_check`、DR-only `/since` 全量回填和 blob sha 校验；仅一次性恢复器允许 active own-origin，普通 PullWorker guard 未放宽。真实提交要求 daemon bootout，先保留 safety backup，再以同卷原子目录 swap 换库，换入后重开验证且失败自动 swap 回旧库。临时双库 + 真 HTTP 测试完成“损坏 DB → snapshot → own-origin/tombstone/blob peer 补齐 → 重启”，重复恢复统计稳定；端到端用例连续 10/10 通过，完整 `swift test`（248 + 548 + 9）全绿。

**问题**：当前会定时生成并 prune snapshot，但没有产品化的 verify/restore 流程。直接替换 DB 还会遇到“peer 默认跳过自己的 origin 行”，无法靠普通 pull 补回灾后缺失的 own-origin 数据。

**方向**：

- 增加 `snapshot-list`、`snapshot-verify` 和带 `--dry-run` 的恢复子命令。
- 恢复前强制确认 daemon 已停，并再做一份安全副本；恢复后跑 `PRAGMA integrity_check`、migration 和 blob 缺失统计。
- 增加显式 disaster-recovery 模式，允许从健康 peer 找回本机 own-origin 行；普通 PullWorker 不放宽现有 guard。

**验收（已通过）**：

- [x] 在临时目录完成“损坏 DB → snapshot 恢复 → peer 补齐 → 重启”的自动化测试。
- [x] 双 Mac 模拟演练能给出恢复前后 item/tombstone/blob 数量报告，重复执行幂等。
- [x] 任一步失败都保留原 DB，不出现半替换状态。

### ✅ R0.4 文档切到现行 mesh 架构

**完成记录（2026-07-16）**：README 与多设备部署指南已按运行代码重写为 standalone / 对称 pull mesh，覆盖 Tailscale HTTP-over-WireGuard 基线、Ponte 双 SAN HTTPS、shared secret、reciprocal `mesh-init`、iOS QR + 独立 PIN、snapshot DR、升级与卸载。两份部署 JSON 由 `Config.load` 契约测试直接解码并验证互指；18 份历史 plan 全部带“已归档/不可作为部署说明”警示。真实 CLI help、隔离临时 HOME 的 `init-secret` / `snapshot-list`、0600 权限、脚本语法和静态漂移检查通过；`swift test`（248 + 549 + 9 = 806）、`swift build`、iOS simulator build 与 `git diff --check` 全绿。

**问题**：`README.md` 和 `docs/deploy-multi-mac.md` 仍混有 M2 primary/client 叙述，跟当前对称 mesh、现行 CLI 和 iOS 能力冲突。

**验收（已通过）**：

- [x] 新用户只看 README + deploy guide 能完成 standalone、双 Mac mesh、iOS 配对和卸载。
- [x] 文档命令在隔离临时 HOME smoke test；历史 plan 顶部标明“已归档/不可作为部署说明”。
- [x] 测试数、路由、目录、签名/TLS 方案与当前代码一致。

## R1 — 隐私、安全与运维（Next）

### ✅ R1.1 按 app 排除捕获 + 临时暂停

**完成记录（2026-07-16）**：新增 per-device `capture.excluded_bundle_ids`，Settings 可从当前运行 app 选择、手填和删除并热重载；菜单栏支持暂停 5 分钟、30 分钟、直到手动恢复，图标/菜单/搜索面板同步显示状态且有限期暂停自动恢复。Watcher 在读取 pasteboard 类型/正文/诊断日志前执行隐私 gate，CaptureService 在 DB/blob 前二次守门；跳过路径不 refresh、不 OCR、不广播 mesh，系统剪贴板与 Cmd+V 不受影响。定向 Core/Capture 5 项测试、完整 `swift test`（248 + 553 + 10 = 811）、`swift build`、iOS simulator build 与 `git diff --check` 均通过。

**范围**：

- `capture.excluded_bundle_ids`，Settings 支持从当前运行 app 选择，也保留手填 bundle ID。
- 菜单栏提供暂停 5 分钟 / 30 分钟 / 直到手动恢复；菜单栏图标和搜索面板都显示暂停状态。
- excluded/paused 内容在 capture 入口直接跳过，不写 DB/blob、不 OCR、不进入 mesh。

**验收（已通过）**：

- [x] excluded/paused 在正文 extraction 与持久化前双重跳过，不写 DB/blob、不 OCR、不进入 mesh；Cmd+V 正常。
- [x] 5 分钟 / 30 分钟暂停自动恢复，“直到手动恢复”可显式恢复；菜单栏图标、菜单和搜索面板状态一致。
- [x] Settings 运行中 app 选择、手填 bundle ID、删除与热重载可用；密码管理器 concealed/transient 规则保持生效。

### ✅ R1.2 TLS 到期预警 + 可脱敏诊断包

**完成记录（2026-07-16）**：新增只读 `TLSCertificateInspector`，`mesh-doctor` 文本/JSON 与 Settings → 关于均展示 leaf DNS SAN、有效期和 inclusive 30/7/1 天状态，warning、expired、not-yet-valid 均影响 CLI 退出码。新增与历史内容导出完全隔离的 `DiagnosticBundleExporter` 和 `diagnostics-export`：固定白名单只含 doctor JSON、read-only `quick_check`、版本、重新编码的脱敏 config、manifest 与白名单运维日志，目录/文件权限为 0700/0600。真实双 SAN PEM fixture 覆盖全部时间边界，seeded sentinel 自动扫描证明 secret、私钥、剪贴板正文和 blob 不会进入包；定向 5/5、完整 `swift test`（248 + 558 + 10 = 816）、`swift build`、真实 CLI JSON、iOS simulator build 与脚本语法均通过。

**范围**：

- `mesh-doctor` 和 Settings 展示 leaf certificate 的 SAN、到期日以及 30/7/1 天 warning。
- 导出诊断包：`mesh-doctor --json`、SQLite `quick_check`、最近日志、版本和脱敏后的 config。
- 明确禁止打包 shared-secret、证书私钥、剪贴板正文和 blob。

**验收（已通过）**：

- [x] 真实双 SAN PEM fixture 可解析 SAN/not-before/not-after，并通过注入时间稳定覆盖 valid、30d、7d、1d、expired 与 not-yet-valid。
- [x] `mesh-doctor` 文本/JSON 和 Settings 状态一致，证书 warning 会使 CLI 非零退出。
- [x] 诊断包固定白名单与 0700/0600 权限生效；自动扫描确认不含 shared secret、TLS 私钥、剪贴板正文、数据库副本或 blob 字节。

### ✅ R1.3 每设备凭据与撤销

**完成记录（2026-07-16）**：v14 新增 device credential claims/activity 与单调 revoke tombstone；新 PIN 配对为每台 iOS 签发独立 request secret 和根密钥 AES-GCM 密封 token，只存 ThisDeviceOnly Keychain，Mac DB 不落 secret/token。HTTP/WS 共用 dual-stack middleware，带 token 时禁止失败降级；Settings 可查看最后活跃并单独撤销，撤销会旋转现有 WS，并经 `/auth/revocations` + PullWorker 在 Mac 间传播。旧 iOS/旧 Mac rolling wire 保持兼容，安全诊断包继续排除所有 credential/token。定向 Core/HTTP/WS/pairing/gossip 测试、完整 `swift test`（252 + 560 + 10 = 822）、`swift build`、release build、真实 CLI、iOS simulator build、脚本语法与 `git diff --check` 均通过。

**问题**：当前整个 mesh 共用一份 HMAC secret；任一设备遗失时只能全网同时换 secret。

**方向**：配对时签发绑定 device ID 的独立凭据，存 Keychain；Settings 能查看设备、最后活跃时间并单独 revoke。升级期允许 shared-secret 与 device credential 双栈，完成迁移后再关闭旧凭据。

**验收（已通过）**：

- [x] iOS A/B 各持独立凭据；Mac Settings 展示稳定设备 ID、平台、最后活跃时间与撤销状态。
- [x] 撤销 A 后，A 的 HTTP 与新 WS upgrade 均为 401，已有 WS 经 rotation 断开且不能重连；B 与 legacy Mac HMAC 不受影响。
- [x] 撤销 tombstone 在双 DB 真 HTTP gossip 后收敛；旧 peer 404 不阻塞 item pull。
- [x] 新 pairing 不返回 mesh 根 secret；旧 iOS 空 body 与新 iOS 对旧 Mac response 均可滚动升级，无需同时停机。
- [x] DB 与诊断包均不含 request secret/token；iOS 旧 UserDefaults secret 一次性迁入 Keychain 后删除。

### ✅ R1.4 iOS 配对通道绑定

**完成记录（2026-07-16）**：Mac 配对 QR 升为 v2，仅携 endpoint 与当前 TLS leaf DER SHA-256；iOS 用共享 `PinnedCertificateDelegate` 在发送 PIN 前精确匹配 leaf。Bonjour 降为只发现/引导扫码，v1、HTTP、缺失/非法 pin 均明确拒绝且不再 trust-any 降级。leaf 轮换会让旧 QR 安全失败并要求重扫，已有 device credential 不受影响；新 Mac/旧 iOS 与旧 Mac/新 iOS 的滚动升级矩阵已写入部署指南。真实双 TLS server 测试证明 attacker leaf 无法消费 PIN 或取得 credential，随后相同 PIN 连正确 leaf 可取得 `dpc1` token。定向测试先红后绿；完整 `swift test`（253 + 565 + 10 = 828）、Mac debug/release、iOS simulator、iPhone 17 Pro 签名 build/install/launch、真实 CLI、脚本语法、静态 QR 敏感字段扫描与 `git diff --check` 全绿；同时修掉 OCR wake 测试以 recognizer 调用代替 DB 最终状态的竞态，定向重复 20/20 通过。

**问题**：为兼容 `.local` hostname 与私有 CA，iOS pairing client 当前接受任意 TLS leaf。HTTPS 能挡被动监听，但主动 MITM 可终止 TLS、读取用户提交的 PIN，再实时转发给真实 Mac 并截获新签发的 credential。

**方向**：把 leaf fingerprint 放进 Mac 屏幕上的 QR，并在签发 credential 前做 channel binding；只通过 Bonjour 选择 peer + 手输 PIN 的路径不再允许。精确 pin 保持 `.local`、Ponte 与私有 CA 部署可用，无需依赖系统默认 trust。

**验收（已通过）**：

- [x] 真实 TLS attacker server 持另一张 leaf 时，正确 PIN request 在 HTTP 发出前被拒，PIN 未消费且拿不到 credential。
- [x] 正常 QR leaf pin + PIN 能取得独立 `dpc1` credential；QR 不含 PIN/secret/token。
- [x] leaf 轮换后旧 QR 拒绝、新 QR 接受，已有 credential 不受影响。
- [x] Bonjour 仅发现；新 iOS 拒绝旧 Mac v1 QR，新 Mac v2 对旧 iOS 保持 JSON wire 可解析并明确记录其无 binding 的降级边界。

## R2 — iOS 真离线（Next）

### ✅ R2.1 iOS 本地 SQLite/FTS mirror

**完成记录（2026-07-16）**：新增 `MetadataMirrorStore`，完整 metadata/FTS/cursor 落 iOS
SQLite；前台 WS 唤醒 pull 与 BGAppRefreshTask 共用原子 page writer，cursor 二元组只单调
前进。History 首页只加载最近 1000 条 projection，但文本/qualifier 搜索覆盖完整本地历史且
不调用 Mac `/search`。旧 JSON 经逐 ID 校验后删除，旧 cursor 强制丢弃并从 zero 补全。
10 万条冷开/FTS/稀疏 qualifier 性能门、离线 1500 条越界历史、Mac/iOS fold ID parity、
并发前后台 writer 均有回归测试。2026-07-16 真机追踪又修复两条长尾：full mirror 的 blob
hydration 改为后台队列，不再阻塞 metadata 下一页；`/since` 增加 raw `total_count` 与稳定
`source_device_id`，iOS v15 用 `(source,id)` ledger 逐 peer 核对覆盖，不能再被本地多 peer
union 的额外行掩盖。发现 source 曾补入落在旧 cursor 之前的迟到行时，从 zero 做非破坏
backfill，既不清库也不回退持久化 cursor；正常新行只增量记账，不反复全拉。前台与 BG pull
共用该修复。完整 841 tests、Mac release 与 iOS simulator 全绿，最终 server 已部署双 Mac。
2026-07-17 最终 v15 client 已覆盖安装到 iPhone 17 Pro 并保留原 app container；真机
SQLite `integrity_check=ok`，20,436 条 metadata 与 FTS row 一致，ID 集精确等于
mini ∪ MBP（双向缺失 0），相对两台 Mac 最新 revision 的旧版本数与用户可见关键字段
不一致数均为 0。当前 source ledger 19,350 条，精确等于 MBP `/since.total_count=19,350`。

**问题**：iOS 目前最多持久化 1000 条 `items.json`；非空查询优先依赖 Mac `/search`，断网时只能对缓存做 `contains`，不等价于 Mac FTS/fold 语义。

**已完成**：

- [x] iOS 使用本地 SQLite/FTS 保存完整元数据 cursor，后台 pull 和前台 WS 唤醒写同一条持久化路径。
- [x] 复用 `DuoPasteCore.SearchAPI` / fold / qualifier 语义；本地 mirror ready 后搜索不再打 Mac。
- [x] 首次升级一次性导入旧 JSON cache，校验成功后删除旧文件；blob 继续由现有 500MB LRU 独立管理。

**验收**：

- [x] 无可用 peer 时仍能从本地 FTS 搜索超过旧 1000 条上限的完整已同步历史；源码契约保证 UI 不调用远端 `/search`。
- [x] 10 万条 metadata 冷启动最近页、FTS 和稀疏 qualifier 查询通过可交互性能门。
- [x] Mac/iOS 对同 query + qualifier 的 fold 后 ID 集与 pin 聚合一致。
- [x] source 在 client cursor 之后补入更老时间戳的行时，per-source ledger 自动触发
  zero-cursor 非破坏 backfill；最终 v15 真机验证 ledger 与 source total 精确一致，且
  iPhone ID 集覆盖 mini ∪ MBP 全集。

### ✅ R2.2 首次同步进度与离线状态

**完成记录（2026-07-17）**：Core metadata sync 增加逐页 post-commit progress，明确区分
incremental/backfill；iOS 常驻状态卡展示本机条数、per-source 覆盖、当前 peer、最后成功时间
和严格追平状态。首次/重建同步可取消并从 SQLite cursor 恢复，用户暂停同时约束 WS 自动 pull
和 BGAppRefreshTask；立即刷新会显式恢复。严格完成 checkpoint 只在 `has_more=false` 且 source
count audit 通过后原子写入 Application Support，mirror 仍在 Caches；cache 被清理或回退时据此
进入“正在重建，当前结果不是全集”。完整 `swift test` 848/848、Mac release、iOS simulator、
iPhone 17 Pro 签名 build/install/launch 均通过；真机状态卡显示 20,449 条、当前 peer 覆盖
19,363/19,363 并“已严格追平”，设备上的 durable checkpoint 与 UI 数字一致。

**验收（已通过）**：

- [x] 展示已同步条数、当前 peer、最后成功时间、是否已严格追平。
- [x] 首次全量同步可取消/恢复；提供“立即刷新”和可读的失败原因。
- [x] cache 被系统清理后明确进入“正在重建”，不把局部结果伪装成全集。
- [x] iPhone 17 Pro 保留原 app container 覆盖安装，真实 mirror 完成 strict source-count audit
  并在 Application Support 写出 checkpoint。

## R3 — 搜索与粘贴体验（Later）

### R3.1 自定义起止时间筛选

复用已经存在的 `SearchQuery.fromNs/toNs`，在“全部/24h/7d/30d”之外加入自定义 DatePicker。验收要覆盖时区、跨日、清除筛选、chip count 与结果总数一致。

### R3.2 保存搜索视图

把 query、qualifier、kind、时间窗和 pinned-only 保存为本机命名视图，支持菜单栏快速打开。第一版只做 per-device 配置，不引入新的跨设备元数据同步。

### R3.3 纯文本粘贴动作

对 text/rtf/html 提供“粘贴为纯文本”菜单项和快捷键；图片/文件不显示。必须复用现有 paste suppression，不能让 app 自写内容重新被 watcher 捕获。

## R4 — 大库性能门槛（并行测量，按结果优化）

### R4.1 8GB / 百万行基准

- 增加可重复生成的合成数据集：100 万 metadata 行、混合 kind/OCR、8GB blob 仓库。
- 记录 cold/warm FTS、空 query、qualifier、countByKind、深分页、首屏渲染的 p50/p95 和峰值内存。
- 初始目标：Apple Silicon 上 warm FTS p95 < 100ms、键入到首屏 p95 < 150ms；若不达标，优先优化 fold oversample/count 和分页，不先堆 UI 动画。
- benchmark 不进入每次 `swift test`，放 nightly/manual，保存基线防回退。

## P3 产品探索（不承诺实现）

- **标签 / Collections**：比单一 pinned 更适合长期资料，但要先复用 R0.2 的元数据同步机制。
- **iOS Share Extension**：从其他 app 主动存入 duo-paste；需要先决定 iOS item 的归属与离线写入协议，不能靠 UCB 假装可靠写通道。
- **per-app paste profile**：给 Terminal、IDE、Office 分别记住 plain/rich paste 偏好；先用埋点/手动反馈确认收益。

## 明确不进入 roadmap

- 公网 SaaS、中转云和 iCloud 加密备份。
- 自动 leader election、共识算法或重新引入 primary/client 单点。
- 为共享字段做通用“最后写入者获胜”冲突系统；只为明确的用户动作设计窄协议。
- iOS 后台静默监听全局剪贴板（平台限制且隐私心智不成立）。

## 执行约定

- 开工前把对应 ID 展开成独立 plan，写清 schema/API、迁移、回滚和测试矩阵。
- 每个 PR 只解决一个 roadmap ID 或其中一个可独立回滚的切片。
- 落地后把新不变量移入 `CLAUDE.md`，从本文件 active 表删除；完成记录以 git/PR 为准。
- 任何 mesh schema/API 改动至少验证 standalone、双 Mac、Mac+iOS、peer 离线重连四条路径。

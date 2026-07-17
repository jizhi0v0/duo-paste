# duo-paste

自托管的 Apple-only 剪贴板管理器：Mac 原生、本地 SQLite/FTS5 全文搜索，多台 Mac 通过 Tailscale / Surge Ponte 组成对称 mesh，并提供 iOS 客户端。

## 当前能力

- macOS daily-driver：剪贴板捕获、按 app 排除与临时暂停、OCR、全文/类型/时间筛选、保存搜索视图、预览与 Open With、`⇧⌘V` 纯文本粘贴、置顶/删除、导出和 Sparkle 更新。
- 对称多 Mac mesh：每台 Mac 都写本机数据、pull 其他 peer，WebSocket 只负责低延迟唤醒；没有 primary/client 单点。
- 本地优先：搜索始终走本机 FTS；blob 可完整 mirror，也可在查看时按需拉取。
- iOS：完整 metadata + cursor 持久化到本机 SQLite/FTS，断网搜索不依赖 Mac；Bonjour 仅发现附近 Mac，配对必须扫描含当前 TLS leaf SHA-256 的 QR，再输入同屏 6 位 PIN。每台 iOS 使用独立凭据，可在 Mac Settings 单独撤销。
- 可恢复：小时级 snapshot，提供 verify、dry-run、peer 补齐和原子 restore。
- 可诊断：Settings 与 `mesh-doctor` 主动报告 leaf certificate 的 SAN、到期日和 30/7/1 天预警；安全诊断包只导出脱敏运维信息。
- 882 个 Swift 测试通过；后续工作与验收标准只看 [`docs/roadmap.md`](docs/roadmap.md)。

## 要求

- macOS 14 或更高版本。
- Xcode / Swift 6.2 toolchain。
- iOS 客户端当前 deployment target 为 iOS 26.5。
- 安装脚本默认使用项目的 Developer ID。其他开发者先用 `security find-identity -v -p codesigning` 找到自己的签名身份，再通过 `DP_SIGN_IDENTITY` 传入。不要使用 ad-hoc 签名：重装后 Accessibility/TCC 授权会漂移。

## Standalone 快速开始

不创建 `config.json` 时就是 standalone：只捕获和搜索本机历史，不监听网络，也不连接 peer。

```sh
git clone git@github.com:jizhi0v0/duo-paste.git
cd duo-paste

# 项目维护者可直接运行；其他开发者覆盖为自己的证书名称。
DP_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install-agent.sh
```

脚本会构建 release、组装并签名 `~/Applications/DuoPaste.app`、安装 LaunchAgent 并启动 daemon。首次使用按系统提示授予 Accessibility 权限。

| 按键 | 行为 |
|---|---|
| ⌥⌘V | 唤出搜索面板 |
| ↑ / ↓ | 移动选择 |
| Enter | 把选中项粘回当前 app |
| Esc | 关闭面板 |

两台或更多 Mac、TLS/Ponte 以及 iOS 配对的完整步骤见 [`docs/deploy-multi-mac.md`](docs/deploy-multi-mac.md)。使用 Universal Clipboard 时还需满足 [`docs/ucb-prerequisites.md`](docs/ucb-prerequisites.md)。

### 捕获隐私

Settings → 常规 → 应用排除可从当前运行的应用选择，也可手填 bundle ID；保存后立即生效。等价配置为：

```json
{
  "capture": {
    "excluded_bundle_ids": ["com.1password.1password"]
  }
}
```

菜单栏的“捕获中”子菜单可暂停 5 分钟、30 分钟或直到手动恢复。排除或暂停只阻止内容进入 duo-paste 历史、blob、OCR 与 mesh，不修改系统剪贴板，Cmd+V 始终正常。

## 架构

每条 item 归属捕获它的设备（`origin_device`）。本机事务提交后，其他 peer 通过 `GET /since` 增量拉取；`/sync/ws` 仅通知 cursor 前进，断线时自动退回周期 pull。置顶等跨 owner mutation 以幂等 operation 路由回 owner，再由 canonical `/since` 回放收敛。删除 tombstone、snapshot 和 blob 都保留可验证的恢复路径。

```text
Mac A (own write + local FTS)  ←── /since + /sync/ws ──→  Mac B (own write + local FTS)
             ↑                                                   ↑
             └──────────── HMAC over Tailscale/Ponte ────────────┘
```

服务端现行路由：

| 方法 | 路由 | 用途 |
|---|---|---|
| GET | `/health` | 设备与服务状态 |
| GET | `/since` | cursor 增量同步 |
| GET | `/search` | 兼容/诊断远端搜索（现行 iOS UI 不调用） |
| GET | `/blob/:sha256` | 内容寻址 blob |
| GET | `/app_icon/:bundle_id` | app 图标 |
| POST | `/bump/:id` | 复制后更新时间 |
| POST | `/pin/:id` | owner-routed pin/unpin |
| DELETE | `/item/:id` | 软删除 |
| POST | `/pair/:pin` | iOS 一次性 PIN 配对 |
| GET | `/endpoints` | mesh endpoint 聚合 |
| GET | `/auth/revocations` | Mac 间撤销 tombstone gossip |
| WebSocket | `/sync/ws` | cursor 前进通知 |

除首次配对的 `/pair/:pin` 外，HTTP/WS 请求都需要 HMAC。可信 Mac mesh 继续共用根 secret；新 iOS 配对只取得独立 request secret 与根密钥密封 token，二者仅存 iOS Keychain。`/pair` 返回认证能力，因此生产路径强制 HTTPS；QR v2 还携带当前 leaf DER 的 SHA-256，iOS 在发送 PIN 前精确校验该 leaf，主动 MITM 不能靠实时转发 PIN 截获 credential。滚动升级期间仍接受不带 token 的 legacy HMAC；带 token 的请求失败时绝不降级。

## 运维 CLI

安装后的真实入口：

```sh
DP="$HOME/Applications/DuoPaste.app/Contents/MacOS/duo-pasted"
"$DP" --help
```

常用子命令：

```sh
"$DP" init-secret
"$DP" mesh-init --peer 'http://peer.tailnet.ts.net:8443,DEVICE_ID' --no-serve-tls
"$DP" mesh-doctor
"$DP" mesh-doctor --json
"$DP" diagnostics-export "$HOME/Desktop"
"$DP" mesh-fetch-missing --dry-run
"$DP" snapshot-list
"$DP" snapshot-verify latest
"$DP" snapshot-restore latest --dry-run
"$DP" retry-failed-ocr
"$DP" refill-image-blobs
"$DP" ponte-self
```

`mesh-init` 和真实 `snapshot-restore` 要求先停 daemon；完整参数以 `"$DP" --help` 为准。

Settings → 关于会显示本机 leaf certificate 的 DNS SAN、有效期、已配对设备及最后活跃时间；可单独撤销设备，也可导出安全诊断包。CLI 的 `diagnostics-export` 会在目标目录下创建时间戳子目录，固定只含 `mesh-doctor.json`、SQLite `quick_check`、版本、脱敏 config、manifest 与白名单运维日志，目录权限为 0700、文件为 0600。它不会复制 shared secret、device credential/token、TLS 私钥、数据库/剪贴板正文或 blob 字节。

## 数据与部署路径

| 内容 | 路径 |
|---|---|
| 主 DB（含 FTS5） | `~/Library/Application Support/duo-paste/db/main.sqlite` |
| Blob | `~/Library/Application Support/duo-paste/blobs/<ab>/<cd>/<sha256>.<ext>` |
| Snapshot | `~/Library/Application Support/duo-paste/snapshots/` |
| 配置 | `~/Library/Application Support/duo-paste/config.json` |
| Shared secret | `~/Library/Application Support/duo-paste/shared-secret` |
| 本机稳定 UUID | `~/Library/Application Support/duo-paste/device-id` |
| Release app | `~/Applications/DuoPaste.app` |
| LaunchAgent | `~/Library/LaunchAgents/io.duopaste.agent.plist` |
| 日志 | `~/Library/Logs/duo-paste/duo-pasted.{out,err}.log` |

卸载应用但保留数据：

```sh
./scripts/uninstall-agent.sh
```

## 开发

```sh
swift build
swift test               # 882 tests
swift build -c release
```

百万行性能基准是显式 manual/nightly 命令，不随 `swift test` 执行：

```sh
swift run -c release duo-pasted benchmark-library \
  --workspace .benchmark/r4-1 \
  --rows 1000000 --blob-gib 8 --samples 20 --rebuild
```

它只接受隔离且带 marker 的 workspace；默认 8GiB blob 是 sparse 逻辑规模，并在报告中
同时记录 allocated bytes。指标口径、复用方式与已保存 baseline 见
[`benchmarks/README.md`](benchmarks/README.md)。

LaunchAgent 运行时不要直接 `swift run`：双进程会重复捕获、抢快捷键并竞争 SQLite writer。调试前先执行：

```sh
launchctl bootout "gui/$UID/io.duopaste.agent"
```

代码结构：`DuoPasteCore` 负责数据库、搜索、blob、snapshot 与共享模型；`DuoPasteCapture` 负责 macOS pasteboard；`DuoPasteSync` 负责 HTTP/WS/mesh；`duo-pasted` 是 macOS daemon + UI；`iOS/DuoPasteApp` 是 iOS Xcode 工程。

已落地的不变量和开发环境坑记录在 [`CLAUDE.md`](CLAUDE.md)。`plans/` 是归档实施记录，不是当前部署说明或 backlog。

主要依赖：GRDB 7.10.0、Hummingbird 2.23.0、Hummingbird WebSocket 2.6.0、Sparkle 2.9.2。

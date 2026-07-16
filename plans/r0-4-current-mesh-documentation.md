# R0.4 README / 部署文档切到现行 mesh 架构

> [!CAUTION]
> **已归档；不可作为部署说明。** 本文件只记录 R0.4 的实施与验证证据；现行部署见
> [`README.md`](../README.md) 与 [`docs/deploy-multi-mac.md`](../docs/deploy-multi-mac.md)，
> 未来工作只看 [`docs/roadmap.md`](../docs/roadmap.md)。

状态：✅ 完成（2026-07-16）

## 代码真相矩阵

- 拓扑：所有 Mac 是平等 peer；每台本机写 own-origin，再以 `/since` pull 对端；
  `/sync/ws` 只负责唤醒。不存在 primary/client、push、promote 或 audit-push。
- 配置：`peers[] + mesh + serve_*`；`mesh-init` 清掉 `primary_url/pull`。默认无配置是
  standalone（不 serve、不主动连 peer）。
- release CLI：`~/Applications/DuoPaste.app/Contents/MacOS/duo-pasted`。
- TLS：Tailscale + Surge Ponte 双路径部署必须用同时包含 tailnet 与 sgponte 的双 SAN
  leaf；单 SAN `tailscale cert` 不能作为 Ponte 部署说明。Tailscale-only 最简部署可显式
  使用 HTTP-over-WireGuard。
- iOS：Bonjour `_duopaste._tcp` 发现，QR 只带 host/port/tls，PIN 由用户另行输入；配对
  成功返回 shared secret + mesh endpoints。
- 路由：HTTP `/health`、`/blob/:sha`、`/app_icon/:bundle`、`/bump/:id`、
  `/item/:id`、`/pin/:id`、`/pair/:pin`、`/endpoints`、`/since`、`/search`；
  WebSocket `/sync/ws`。只有 `/pair/:pin` 不要求既有 HMAC。
- 最终测试基线：`swift test` 三个 runner 共 248 + 549 + 9 = 806。

## 文档改动

- README：给出 standalone 快速开始、现行功能/架构、部署指南入口、iOS 构建配对入口、
  当前 CLI 路径、806 测试与真实目录。
- `docs/deploy-multi-mac.md`：完全重写为双向 mesh；覆盖 Tailscale-only HTTP 基线、可选
  Ponte 双 SAN TLS、shared secret、双端 `mesh-init`、验证、iOS、升级、恢复与卸载。
- `CLAUDE.md`：修正 release CLI 路径；继续只保存已落地硬护栏，不复制整份用户指南。
- `plans/*.md`：每份顶部统一标明已归档、不可作为部署说明，并链接现行文档。
- 修正直接误导文档工作的少量代码注释（Config/Server），不改变运行逻辑。

## Smoke / 回归矩阵

- [x] `bash -n scripts/install-agent.sh scripts/uninstall-agent.sh`。
- [x] release/debug `duo-pasted --help` 的子命令与 README/deploy 列表一致。
- [x] 临时 HOME 执行 `init-secret`、`snapshot-list`，不依赖已有用户数据。
- [x] 部署配置 JSON 由 `Config.load` 自动化测试 decode/validate；双端 peer 方向不写反。
- [x] 文档静态检查无 `primary_url`、`promote-to-primary`、`audit-push`、旧 CLI 路径和
  把 `tailscale cert` 当 Ponte 证书的命令。
- [x] `swift test`、`swift build`、iOS simulator build、`git diff --check` 通过。

## 完成条件

- [x] roadmap R0.4 三条验收全部有证据并打勾。
- [x] README + deploy guide 足以完成 standalone、双 Mac mesh、iOS 配对、卸载。
- [x] 本计划与 `docs/roadmap.md` 同步标为完成。

## 验证记录

- `swift test`：DuoPasteSync 248 + DuoPasteCore 549 + DuoPasteCapture 9，合计 806，0 failure。
- `swift build` 与 `xcodebuild ... -scheme DuoPasteApp ... build`：成功。
- `bash -n`、真实 `--help`、隔离 HOME one-shot CLI、配置契约、归档计数、静态旧口径扫描与 `git diff --check`：通过。

# 多设备部署：现行对称 mesh

本文是当前可执行的部署说明。所有 Mac 都是平等 peer：各自捕获并写入 own-origin item，再通过 `/since` 拉取其他 Mac；`/sync/ws` 只负责及时唤醒。不存在需要接管的中心节点。

## 0. 选择部署方式

| 目标 | 传输 | 说明 |
|---|---|---|
| 单 Mac | standalone | 不需要配置、secret 或网络 |
| 两台以上 Mac，先跑通 | HTTP over Tailscale | HTTP 内容位于 WireGuard 加密隧道内；最少证书运维 |
| Tailscale + Surge Ponte / iOS 配对 | HTTPS | 每台 Mac 使用包含 tailnet 与 sgponte 两个 SAN 的 leaf |

`/pair` 会把独立 request secret 与密封 credential token 交给 iOS，因此 daemon 在纯 HTTP 下会主动禁用配对路由。mesh 根 secret 不再发给新 iOS。要配 iOS，必须先完成 HTTPS 章节。

以下命令默认仓库已 clone。所有 Mac 都先安装：

```sh
cd /path/to/duo-paste
DP_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install-agent.sh

DP="$HOME/Applications/DuoPaste.app/Contents/MacOS/duo-pasted"
DATA="$HOME/Library/Application Support/duo-paste"
AGENT="gui/$UID/io.duopaste.agent"
```

项目维护者可省略 `DP_SIGN_IDENTITY`；其他开发者用 `security find-identity -v -p codesigning` 查自己的身份。不要用 ad-hoc 签名。

## 1. Standalone

安装后不创建 `config.json` 即为 standalone：`serve=false`、无 peers，只捕获和搜索本机历史。验证：

```sh
launchctl print "$AGENT"
tail -20 "$HOME/Library/Logs/duo-paste/duo-pasted.err.log"
```

按 ⌥⌘V 能打开搜索面板即可。后续切 mesh 不需要迁移 DB。

## 2. 双 Mac：HTTP over Tailscale 基线

示例设备叫 Mac A / Mac B。先确保两台加入同一 tailnet，并且 MagicDNS 互通：

```sh
tailscale status
tailscale ping mac-b.example-tailnet.ts.net   # A 上执行
tailscale ping mac-a.example-tailnet.ts.net   # B 上执行
```

### 2.1 停 daemon，取得 device ID

`mesh-init` 包括 `--dry-run` 都会拒绝修改正在运行的部署。两台都执行：

```sh
launchctl bootout "$AGENT"
cat "$DATA/device-id"
```

记下 `MAC_A_ID` 和 `MAC_B_ID`。如果 launchd 暂时显示 `state = languishing`，等待 10–30 秒，直到 `launchctl print "$AGENT"` 返回找不到服务，再继续。

### 2.2 建立同一份 shared secret

只在 Mac A 生成一次：

```sh
"$DP" init-secret
```

通过 SSH、AirDrop 或其他可信通道把 `$DATA/shared-secret` 原样复制到 Mac B，然后在 B 执行：

```sh
chmod 600 "$DATA/shared-secret"
```

不要在 B 再生成一份；所有可信 Mac 共用完全相同的 32 字节根 secret。它只用于 Mac mesh HMAC、签发/解封 iOS credential token，不应复制到新 iOS。

### 2.3 双向写入 peer

Mac A 指向 B，先 dry-run，再真实写入：

```sh
"$DP" mesh-init \
  --peer "http://mac-b.example-tailnet.ts.net:8443,$MAC_B_ID" \
  --serve-host 0.0.0.0 --serve-port 8443 --no-serve-tls --dry-run

"$DP" mesh-init \
  --peer "http://mac-b.example-tailnet.ts.net:8443,$MAC_B_ID" \
  --serve-host 0.0.0.0 --serve-port 8443 --no-serve-tls
```

Mac B 反向指向 A：

```sh
"$DP" mesh-init \
  --peer "http://mac-a.example-tailnet.ts.net:8443,$MAC_A_ID" \
  --serve-host 0.0.0.0 --serve-port 8443 --no-serve-tls --dry-run

"$DP" mesh-init \
  --peer "http://mac-a.example-tailnet.ts.net:8443,$MAC_A_ID" \
  --serve-host 0.0.0.0 --serve-port 8443 --no-serve-tls
```

`device_id` 可省略让首次 `/health` 自动学习，但显式填写能在 URL 指错机器时立即报错。`mesh-init` 会保留 hotkey/capture/OCR 等本机设置，并移除旧拓扑键。

如果预检报告本机缺 blob，先排查或执行 `"$DP" mesh-fetch-missing`。只有明确接受该设备暂时不能提供那些历史 blob 时，才使用 `--allow-missing-blobs`。

### 2.4 重启与验证

两台都执行：

```sh
launchctl bootstrap "gui/$UID" "$HOME/Library/LaunchAgents/io.duopaste.agent.plist"
launchctl enable "$AGENT"
launchctl kickstart -k "$AGENT"
"$DP" mesh-doctor
"$DP" mesh-doctor --json   # 给脚本/监控使用
```

随后做一次双向数据验证：

1. A 复制唯一文本，B 按 ⌥⌘V 搜到它。
2. B 复制另一段唯一文本，A 搜到它。
3. 任一端置顶/取消置顶，等 owner 恢复在线后两端最终一致。
4. 停掉一个 peer，另一端仍可搜索已经 mirror 的历史；重新启动后 `mesh-doctor` 恢复全绿。

## 3. HTTPS + Surge Ponte

这一节用于双路径 mesh，也为 iOS 配对提供加密 transport。关键不变量：每台 Mac 的 leaf 必须同时包含自己的 tailnet hostname 和 `*.sgponte` hostname。只包含 tailnet SAN 的证书会让 Ponte hostname 校验失败。

### 3.1 收集两类 hostname

每台 Mac 分别执行并记录结果（需要 `jq`）：

```sh
TAIL_HOST=$(tailscale status --json | jq -r '.Self.DNSName | sub("\\.$"; "")')
PONTE_HOST=$("$DP" ponte-self)
printf 'tailnet=%s\nponte=%s\n' "$TAIL_HOST" "$PONTE_HOST"
```

`ponte-self` 失败表示 Surge 未安装、Ponte 未启用或本机条目无法匹配；先修复 Surge 配置，不要猜 hostname。

### 3.2 用一个私有 CA 签两张双 SAN leaf

在受信任的证书管理 Mac 上安装 `mkcert`，创建一个 DuoPaste 专用 CA，并为 A/B 各生成一张 leaf。下面的 hostname 替换成上一步真实值：

```sh
brew install mkcert
CA_DIR="$HOME/Library/Application Support/duo-paste-ca"
mkdir -p "$CA_DIR"
CAROOT="$CA_DIR" mkcert -install

CAROOT="$CA_DIR" mkcert \
  -cert-file mac-a-duopaste.crt -key-file mac-a-duopaste.key \
  mac-a.example-tailnet.ts.net mac-a.sgponte

CAROOT="$CA_DIR" mkcert \
  -cert-file mac-b-duopaste.crt -key-file mac-b-duopaste.key \
  mac-b.example-tailnet.ts.net mac-b.sgponte
```

向每台设备只分发它自己的 `.crt` / `.key` 和 `rootCA.pem`。绝不复制 `rootCA-key.pem`。在两台 Mac 上：

```sh
mkdir -p "$DATA/tls"
chmod 700 "$DATA/tls"
chmod 600 "$DATA/tls/duopaste.key"
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain "$DATA/tls/rootCA.pem"
```

### 3.3 切换双端配置

先停两台 daemon。A 使用 A 的证书、peer URL 仍写 B 的 tailnet hostname：

```sh
launchctl bootout "$AGENT"
"$DP" mesh-init \
  --peer "https://mac-b.example-tailnet.ts.net:8443,$MAC_B_ID" \
  --serve-host 0.0.0.0 --serve-port 8443 --serve-tls \
  --tls-cert "$DATA/tls/duopaste.crt" \
  --tls-key "$DATA/tls/duopaste.key" --dry-run

"$DP" mesh-init \
  --peer "https://mac-b.example-tailnet.ts.net:8443,$MAC_B_ID" \
  --serve-host 0.0.0.0 --serve-port 8443 --serve-tls \
  --tls-cert "$DATA/tls/duopaste.crt" \
  --tls-key "$DATA/tls/duopaste.key"
```

B 用 B 的证书反向执行同样命令，把 peer 改成 A。然后按 2.4 重启并运行 `mesh-doctor`。报告里的 TLS 项应列出两个 DNS SAN、not-after 且状态为 valid；daemon 会从 `/health` 学到 `ponte_host` 并为 pull/blob 选择可用快路径，WebSocket 保持走 tailnet URL。

## 4. 配置契约

优先使用 `mesh-init` 写配置。下面两份是双端 HTTP 基线写盘后的等价最小形态；测试会直接用 `Config.load` 解码并检查方向，防止文档与代码再次漂移。

Mac A：

<!-- config-contract:mac-a:start -->
```json
{
  "serve": true,
  "serve_host": "0.0.0.0",
  "serve_port": 8443,
  "serve_tls": false,
  "peers": [
    {
      "url": "http://mac-b.example-tailnet.ts.net:8443",
      "device_id": "22222222-2222-4222-8222-222222222222"
    }
  ],
  "mesh": {
    "enabled": true,
    "pull_interval_sec": 30,
    "storage_mode": "full",
    "ws_enabled": true,
    "cross_device_dedup_window_ns": 0,
    "delete_cascade_enabled": true
  }
}
```
<!-- config-contract:mac-a:end -->

Mac B：

<!-- config-contract:mac-b:start -->
```json
{
  "serve": true,
  "serve_host": "0.0.0.0",
  "serve_port": 8443,
  "serve_tls": false,
  "peers": [
    {
      "url": "http://mac-a.example-tailnet.ts.net:8443",
      "device_id": "11111111-1111-4111-8111-111111111111"
    }
  ],
  "mesh": {
    "enabled": true,
    "pull_interval_sec": 30,
    "storage_mode": "full",
    "ws_enabled": true,
    "cross_device_dedup_window_ns": 0,
    "delete_cascade_enabled": true
  }
}
```
<!-- config-contract:mac-b:end -->

`storage_mode`：

- `full`（默认）：同步元数据时也拉齐 blob，适合灾难恢复。
- `optimized`：只同步元数据，预览/粘贴时懒拉 blob，适合小盘设备；切回 full 后运行 `"$DP" mesh-fetch-missing` 补历史。

`peers[].pull_url` 可手动指定仅供 pull/blob 使用的快路径；不填时使用 `url`，或由 smart transport 根据对端 `/health` 自动发现 Ponte。修改 `config.json` 后要重启 daemon。

## 5. iOS 构建与配对

1. 打开 `iOS/DuoPasteApp/DuoPasteApp.xcodeproj`，选择 `DuoPasteApp` scheme、开发团队和真机后运行。
2. 确保 iPhone 与任一启用 HTTPS/`serve=true` 的 Mac 在同一局域网；Bonjour 服务名为 `_duopaste._tcp`。
3. Mac 打开 DuoPaste 设置 → iOS 配对 → 显示配对码。
4. iOS 设置里点“扫描 Mac 配对码”。Bonjour 列表只确认附近有哪些 Mac，不能直接提交 PIN。
5. 扫描 Mac 同屏 QR，再输入同屏显示的 6 位 PIN。QR v2 只包含 endpoint 与当前 TLS leaf DER 的 SHA-256，不包含 PIN、secret、credential 或 token；iOS 会在发送 PIN 前精确校验握手 leaf。
6. 配对成功会原子取得独立 request secret、credential token 和 mesh endpoints；request secret/token 只存本机 ThisDeviceOnly Keychain。可与任一 Mac 配对，不依赖固定中心节点。
7. Mac Settings → 关于 → 已配对设备可查看平台与最后活跃时间并单独撤销。撤销后该设备的 HTTP/WS 都会被拒，其他 iOS 与 Mac 不受影响。

精确 leaf pin 不依赖系统信任 `.local` hostname 或私有 CA。攻击者若用另一张证书终止 TLS，即使能实时转发正确 PIN，也会在 iPhone 发出 pairing request 前被拒。

滚动升级与证书轮换边界：

- 新 Mac + 新 iOS：使用 QR v2 leaf binding。
- 新 Mac + 旧 iOS：旧 decoder 会忽略 QR 的新增字段，仍可配对，但不具备 leaf binding；应尽快升级 iOS 并重新配对。
- 旧 Mac + 新 iOS：新 iOS 明确拒绝 v1/无指纹 QR，也不允许 Bonjour + PIN 降级直配；先升级 Mac。
- 已配对设备升级前后继续使用原 credential。轮换 leaf 不会注销已有 credential，但旧 QR 会安全失败；重新打开 Mac 配对页生成新 QR 并重扫。

Bonjour 发现只覆盖同一 LAN。iOS 点选历史后若希望 Apple Universal Clipboard 把内容送回 Mac，还必须满足 [`ucb-prerequisites.md`](ucb-prerequisites.md) 的 Apple ID、Wi-Fi、蓝牙和 Handoff 条件；这与 DuoPaste mesh 是两条独立链路。

## 6. Snapshot 与灾难恢复

日常只读检查：

```sh
"$DP" snapshot-list
"$DP" snapshot-verify latest
```

恢复前先做完整演练。`--peer` 会进入仅限 DR 的全量回填模式，从健康 peer 找回 snapshot 后缺失的 own-origin item、tombstone 和 blob：

```sh
"$DP" snapshot-restore latest \
  --peer 'https://mac-b.example-tailnet.ts.net:8443' \
  --expected-device-id "$MAC_B_ID" --dry-run
```

确认报告后停 daemon，再去掉 `--dry-run`。真实恢复会先生成 safety backup，在 staging DB 上迁移并跑 `integrity_check`，最后同卷原子换库；任何阶段失败都会保留或换回原 DB。恢复完成后重新 bootstrap，并运行 `mesh-doctor`。

## 7. 升级与卸载

每台 Mac 依次滚动升级：

```sh
git pull --ff-only
DP_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install-agent.sh
"$DP" mesh-doctor
```

卸载 app/LaunchAgent，但保留 DB、blob、snapshot 和日志：

```sh
./scripts/uninstall-agent.sh
```

确认不再需要恢复后才做全量数据清理：

```sh
rm -rf "$HOME/Library/Application Support/duo-paste"
rm -rf "$HOME/Library/Logs/duo-paste"
```

## 8. TLS 检查与安全诊断导出

Settings → 关于会展示本机 leaf certificate 的 DNS SAN、not-before/not-after 和当前状态。CLI 等价检查：

```sh
"$DP" mesh-doctor
"$DP" mesh-doctor --json
```

证书剩余时间进入 30 / 7 / 1 天边界时逐级预警，已过期或尚未生效也算异常，并使 `mesh-doctor` 退出 1。mkcert leaf 不会由 duo-paste 自动续期；重新签发相同双 SAN leaf、替换 `tls_cert_path` / `tls_key_path` 指向的文件后重启 daemon，再确认 doctor 全绿。

需要提交故障信息时，可在 Settings → 关于点击“导出安全诊断包”，或使用 CLI：

```sh
"$DP" diagnostics-export "$HOME/Desktop"
```

命令会在目标目录下创建 `duo-paste-diagnostics-YYYYMMDD-HHmmss/`。包内固定只有 mesh doctor JSON、SQLite `quick_check`、版本、脱敏 config、manifest 和白名单运维日志；目录权限为 0700、文件为 0600。它不会包含 shared-secret、device credential/token、TLS 私钥、数据库/剪贴板正文或 blob。仍建议分享前自行复核文件内容。

## 9. 故障排查

| 症状 | 处理 |
|---|---|
| `mesh-init` 报 daemon running | `launchctl bootout "$AGENT"`，等服务完全消失后重试 |
| `mesh-init` 报 missing blobs | 先跑 `mesh-fetch-missing --dry-run` / `mesh-fetch-missing`；不要无条件跳过守门 |
| peer connection refused | 检查对端 LaunchAgent、`serve_host=0.0.0.0`、8443 和 Tailscale ACL |
| Mac peer unauthorized / HMAC failed | 对比各 Mac `shared-secret` 内容与 0600 权限 |
| 只有一台 iOS 持续 401 | 在 Mac Settings 检查该设备是否已撤销；已撤销需取消配对并重新签发 |
| HTTPS hostname mismatch | leaf 的 SAN 必须同时覆盖本机 tailnet 和 sgponte hostname |
| iOS 报 pairing requires HTTPS | 当前 Mac 仍是 HTTP；完成第 3 节后再配对 |
| iOS 报 TLS leaf 与 QR 不一致 | 证书可能已轮换，或连接被另一张 leaf 截获；关闭旧配对页，在目标 Mac 重新显示 QR 后重扫 |
| `mesh-doctor` 退出 1 | 按报告逐项处理 unreachable、device ID mismatch、cursor/blob 缺失或 TLS 到期/尚未生效 |
| bootstrap 报 I/O error / languishing | 等 10–30 秒直到旧 service 消失，再 bootstrap；不要 sudo 修改 plist |

日志：`~/Library/Logs/duo-paste/duo-pasted.{out,err}.log`。`Server started`、`UI ready`、`snapshot ok` 出现在 stderr 属于正常诊断。

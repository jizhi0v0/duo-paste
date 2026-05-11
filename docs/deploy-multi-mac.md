# 多 Mac 部署（M2，HTTPS-over-Tailscale）

本文是 `plans/...moonlit-wave.md` 的落地配方。代码 M2 完成度足以跑通"两台 Mac 互推、统一搜索"的核心流程，外加 `tailscale cert` 签发的真 TLS 证书。

TLS 是可选的（`serve_tls=false` 走 HTTP-over-Tailscale，Tailscale 本身已加密）。推荐开 TLS——defense-in-depth + cert chain 已经被 macOS 根信任，client 不需要额外信任配置。

## 拓扑速记

```
┌──────────────────────────┐
│   Mac mini (primary)     │  100.x.x.x : 8443
│   serve = true           │  bobbys-mac-mini.tailXXXX.ts.net
│   serve_host = 0.0.0.0   │
│   serve_tls = true       │  (tailscale cert 签发)
└──────────────────────────┘
            ▲  HTTPS + HMAC（双层：TLS + WG）
            │
   ┌────────┴────────┐
   │                 │
┌──────┐         ┌──────┐
│ MBP  │         │ 主 Mac│
│client│         │client │
└──────┘         └──────┘
   primary_url = https://bobbys-mac-mini.tailXXXX.ts.net:8443
```

## 前置：每台 Mac 上 Tailscale 跑起来 + 加入同一 tailnet

```sh
tailscale status        # 自己 + 其他设备都在
tailscale ip            # 拿到 100.x.x.x
tailscale status --json | grep MagicDNSSuffix
                        # 抄下 tailnet 后缀，比如 tail69730a.ts.net
```

## 步骤 1 — Primary（mini）首次部署

### 1a. Tailscale admin console 开 HTTPS Certificates

去 https://login.tailscale.com/admin/dns，"HTTPS Certificates" 一栏点 **Enable HTTPS**。这是用 `tailscale cert` 的前置——免费开关，不开会报 `500 your Tailscale account does not support getting TLS certs`。

### 1b. Daemon + secret + cert

```sh
# clone 仓库 + build + install LaunchAgent
git clone <repo> ~/dev/duo-paste && cd ~/dev/duo-paste
./scripts/install-agent.sh

# 生成 shared-secret（32 字节随机 hex，0600 权限）
~/Applications/duo-paste/duo-pasted init-secret

# 生成 TLS cert（cert + key 一对，注意要在文件存放目录里执行——
# tailscale cert 把文件写到当前目录）
mkdir -p ~/Library/Application\ Support/duo-paste/tls
cd       ~/Library/Application\ Support/duo-paste/tls
tailscale cert $(hostname -s).$(tailscale status --json | jq -r .MagicDNSSuffix)
ls -la    # 应该有 .crt 和 .key
cd -

# 写 primary config（注意 tls 路径必须 absolute）
HOST_FQDN=$(hostname -s).$(tailscale status --json | jq -r .MagicDNSSuffix)
cat > ~/Library/Application\ Support/duo-paste/config.json <<EOF
{
    "serve": true,
    "serve_host": "0.0.0.0",
    "serve_port": 8443,
    "serve_tls": true,
    "tls_cert_path": "$HOME/Library/Application Support/duo-paste/tls/$HOST_FQDN.crt",
    "tls_key_path":  "$HOME/Library/Application Support/duo-paste/tls/$HOST_FQDN.key"
}
EOF

# 重启 daemon 让新 config 生效
launchctl bootout gui/$UID/io.duopaste.agent
sleep 10    # 避开 launchd languishing 速率限制
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/io.duopaste.agent.plist

# 验证
tail -3 ~/Library/Logs/duo-paste/duo-pasted.err.log
# 应该看到: mode=primary @ 0.0.0.0:8443
#          [HummingbirdCore] Server started and listening on 0.0.0.0:8443
```

### Primary 自检（在 primary 本机）

```sh
SECRET=$(cat ~/Library/Application\ Support/duo-paste/shared-secret)
TS=$(($(date +%s) * 1000))
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
SIG=$(printf "%s\nGET\n/health\n%s" "$TS" "$EMPTY" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$SECRET" -hex | awk -F'= ' '{print $2}' | tr -d ' \n')

# 走 MagicDNS hostname（cert SAN 上的名字必须一致才 OK，IP 直连会 cert mismatch）
curl -sS -H "X-DP-Timestamp: $TS" -H "X-DP-Body-SHA256: $EMPTY" -H "X-DP-Auth: $SIG" \
  https://$(hostname -s).$(tailscale status --json | jq -r .MagicDNSSuffix):8443/health
```

注意：HTTPS 的 hostname **必须**用 `tailscale cert` 签的 FQDN（即 MagicDNS 名字）。直接用 `100.x.x.x:8443` 会因为 cert SAN 不匹配 fail。Tailscale MagicDNS 解析在所有 tailnet 设备上自动工作（前提：`tailscale set --accept-dns=true`）。

## 步骤 2 — Client（主 Mac / MBP）部署

```sh
# 同 primary：build + install
git clone <repo> ~/dev/duo-paste && cd ~/dev/duo-paste
./scripts/install-agent.sh

# 不要在 client 上跑 init-secret——secret 三台机必须同份。
# 从 primary 拷过来：
scp bobbys-mac-mini.tail69730a.ts.net:'~/Library/Application\ Support/duo-paste/shared-secret' \
    ~/Library/Application\ Support/duo-paste/shared-secret
chmod 600 ~/Library/Application\ Support/duo-paste/shared-secret

# Client config（注意 https）
cat > ~/Library/Application\ Support/duo-paste/config.json <<'EOF'
{
    "primary_url": "https://bobbys-mac-mini.tail69730a.ts.net:8443"
}
EOF
# 把 tail69730a 换成你自己 tailnet 的 suffix

# 重启 daemon
launchctl bootout gui/$UID/io.duopaste.agent
sleep 10
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/io.duopaste.agent.plist

tail -3 ~/Library/Logs/duo-paste/duo-pasted.err.log
# 应该看到: mode=client→http://...
#          push worker → http://...
```

### Client 自检

```sh
# 复制一段文本（比如在 Safari / 终端里 Cmd+C）
# 然后看 client 的 push log：
tail -f ~/Library/Logs/duo-paste/duo-pasted.err.log
# 该出现: push: tick acked=1 rejected=0 transient=0

# 在 primary 上验证 item 到达了：
sqlite3 ~/Library/Application\ Support/duo-paste/db/main.sqlite \
  "SELECT id, origin_device, preview FROM item ORDER BY captured_at_ns DESC LIMIT 5"
# 应该看到 origin_device != primary 自己 device-id 的行
```

### UI 验证

在 client 上按 ⌥⌘V，search panel 显示的应该是来自 primary 的聚合视图（含 primary 自己 origin 的项）。停掉 primary（`launchctl bootout`）后再搜索，顶部出现黄色 banner "primary 离线，使用本地结果"，且只看到本机 origin 的项。

## 故障排查

| 症状 | 排查 |
|---|---|
| client log: `transport: connection refused` | primary 没起 / 端口不对 / Tailscale 没连 |
| client log: `rejected: ... unauthorized` 或 `hmac verify failed` | secret 文件三台机不一致 |
| primary log: `auth reject: missing or malformed auth headers` | client 没装 HMAC headers——多数是用 curl 调试时拼错 |
| client log: `rejected: body sha256 不匹配` | 路上中间件改了 body（不应发生在 HMAC 配置下） |
| MagicDNS 解析失败 | `tailscale set --accept-dns=true`；或直接用 `100.x.x.x` IP |
| Push 卡 `failed` | 修底层问题后 `~/Applications/duo-paste/duo-pasted retry-failed` 重置队列 |

## 当前未完成的事

| 项目 | 阻塞影响 | 等什么 |
|---|---|---|
| Mirror 模式（M3） | client 无 DR、primary 死了就丢 primary origin 的历史 | M3 milestone |
| `promote-to-primary` / `audit-push` | 不能在 client 接管 primary | M3 milestone |
| Snapshot 在非默认路径的可配置性 | 无 | 不计划做 |
| Cert 自动续期 | Tailscale cert 90 天到期；到期后 client 会 TLS 失败 | 加个 crontab 重跑 `tailscale cert` + `launchctl kickstart`，M3+ 时一并做 |

## 升级 / 换 primary 流程（暂时手动）

参见 plans/...moonlit-wave.md 的 "Primary 生命周期" 章节。M2 阶段没有自动化命令，靠 `rsync DB + blobs` + 改 config + 重启的人工流程。M3 加 `migrate-primary` 子命令把这些步骤封装起来。

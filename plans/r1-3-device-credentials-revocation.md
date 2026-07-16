# R1.3 每设备凭据与撤销

> [!IMPORTANT]
> **完成后归档。** 当前 backlog 与验收状态只以
> [`docs/roadmap.md`](../docs/roadmap.md) 为准。

状态：已完成并归档（2026-07-16）

## 信任与兼容边界

- `shared-secret` 从“发给所有客户端的通用 bearer key”收口成可信 Mac mesh 的根密钥；
  新 PIN 配对绝不再把它返回给 iOS。
- 新配对设备拿三件套：`credential_id`、32 字节随机 request secret、由 mesh 根密钥
  AES-GCM 密封的 credential token。token 绑定 device ID、显示名、平台、issuer 和签发时间；
  任一升级后的 Mac 都可解封验证，不需要复制设备 secret 到多份 DB。
- HTTP 与 WebSocket 使用同一 middleware：请求带 token header 时只能走 device credential，
  不允许失败后降级 shared-secret；不带 token 才走 legacy HMAC。
- 撤销是永久、单调的 credential ID tombstone。每个 PullWorker 从 peer 拉完整小集合并 merge，
  新增撤销后旋转本机 WS，迫使所有连接重新认证；离线 peer 恢复后自然收敛。
- 服务端 DB 只存公开 claims、last active 与 revoke tombstone，不存设备 request secret/token；
  iOS request secret + token 存 Keychain。升级时把旧 `@AppStorage` secret 一次性迁进 Keychain
  并删掉 UserDefaults 明文。
- 滚动升级：旧 iOS（空 pairing body）仍取得 legacy shared-secret；新 iOS 对旧 Mac 返回形态
  自动降级 legacy，但同样只存 Keychain。新 credential 连到旧 Mac 得 401 后，其余已升级
  endpoint 仍可用；全部 Mac 升级后自动恢复全 endpoint。

## Schema / wire

- [x] v14 `device_credential`：公开 claims、issued/last_active；不含 request secret/token。
- [x] v14 `device_credential_revocation`：credential ID PK、revoked_at、revoked_by，单调 merge。
- [x] Header `X-DP-Credential`；签名 canonical string 不变。
- [x] 新 pairing JSON body：`client_device_id/client_name/platform`；response 新增
  `credential {id, secret, token}`，legacy `secret` 变 optional。
- [x] `GET /auth/revocations` + PullWorker gossip；旧 peer 404 视为 unsupported，不阻塞 item pull。

## 测试先行

- [x] token 加密 round-trip、篡改/错根拒绝，claims 绑定稳定。
- [x] v14 不存 request secret/token；last active 与 revoke merge 单调。
- [x] A/B 两凭据 + legacy 同时可访问；撤销 A 后 HTTP A=401、B/legacy 保持 200。
- [x] 撤销 A 后新 WebSocket upgrade 被拒，B 仍可连接；已有连接经 rotation 重新认证。
- [x] 新 pairing 不返回 shared-secret；老 pairing wire 保持兼容。
- [x] 双 DB revocation gossip 后同一凭据在两台 server 都被拒。

## 实现

- [x] Core token / metadata / v14 migration。
- [x] Sync authenticator、dual-stack middleware、pairing、revocation route + gossip。
- [x] macOS Settings 设备列表、最后活跃、单设备 revoke，撤销触发 WS rotation。
- [x] iOS stable device identity、Keychain、pairing wire 与所有 HTTP/WS header。
- [x] 文档与安全诊断边界同步；诊断包仍不含任何 credential/token。

## 验证

- [x] 定向 Core + HTTP + WS + pairing + gossip 测试先红后绿。
- [x] `swift build`、完整 `swift test`、iOS simulator build、真实 CLI、脚本语法、diff check。
- [x] roadmap R1.3 验收逐项勾选，本计划完成并归档。

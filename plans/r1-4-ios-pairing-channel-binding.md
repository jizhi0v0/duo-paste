# R1.4 iOS 配对通道绑定

> [!IMPORTANT]
> **完成后归档。** 当前 backlog 与验收状态只以
> [`docs/roadmap.md`](../docs/roadmap.md) 为准。

状态：已完成并归档（2026-07-16）

完成记录：Mac QR v2 + iOS leaf pin 已上线；真实 attacker/genuine 双 TLS server 验证了
request-before-PIN gate。完整 828 tests、Mac debug/release、iOS simulator、iPhone 17 Pro
签名 build/install/launch、CLI/脚本/diff/静态敏感字段扫描全部通过。

## 信任与兼容边界

- Mac 屏幕上的 QR 是高熵可信光学通道：v2 payload 在 `host/port/tls` 外加入当前
  TLS leaf DER 的 SHA-256（`cert_sha256`）；PIN 继续独立显示，不进 QR。
- iOS pairing TLS 只接受 leaf 指纹与 QR 完全相同的连接；攻击者 leaf 即使实时转发正确
  PIN，也会在 PIN request 发出前被拒。精确 pin 后不要求 `.local` hostname 或私有 CA
  进入系统 trust store。
- channel binding 只用于签发 credential 的 onboarding。配对后的 HTTP/WS 仍以 R1.3
  request secret + credential token 为身份，可跨 endpoint 使用，也不因 leaf 轮换失效。
- 证书轮换会改变 QR；旧 QR 安全失败，用户重新打开 Mac 配对码并重扫。QR cache key
  必须包含证书内容 fingerprint，不能只看文件路径。
- 新 iOS 拒绝旧 v1/无指纹 QR，也不允许 Bonjour + PIN 无绑定直配；Bonjour 仅用于发现并
  引导扫码。新 Mac 的 v2 QR 对旧 iOS 是向后兼容的额外 JSON 字段，但旧 iOS 不具备本项保护。
- plain HTTP / 缺失或不可读 leaf 时 Mac 不生成 PIN/QR 安全配对会话，并给出可读错误。

## 测试先行

- [x] 合法 leaf pin 匹配；攻击者 leaf 即使持有相同 PIN 也在请求前被拒。
- [x] v2 QR round-trip 包含规范化 `cert_sha256`，PIN/secret/token 均不进入 QR。
- [x] v1/缺指纹、HTTP、非法 fingerprint 明确拒绝 channel binding。
- [x] leaf 轮换后旧 pin 拒绝、新 pin 接受，已有 device credential 不受影响。

## 实现

- [x] Core 提供 certificate pin 规范化/常量时间比较与 v2 QR wire model。
- [x] macOS QR 从配置 leaf 内容生成指纹，cache 随证书内容轮换；无安全条件时不生成 PIN。
- [x] iOS pairing 使用 pinned TLS delegate，只有 QR 路径能提交 PIN。
- [x] Bonjour / v1 / TLS mismatch UI 给出明确安全错误，绝不静默 trust-any 降级。
- [x] README、部署指南、CLAUDE 与 roadmap 同步滚动升级和轮换行为。

## 验证

- [x] 定向 channel-binding 测试先红后绿。
- [x] 完整 `swift test`、macOS debug/release、iOS simulator build 与真机 build/install。
- [x] 连接的 iPhone 17 Pro 上确认 app 可启动；实际重配对需用户在 Mac/iPhone 同屏完成扫码/PIN。
- [x] CLI、脚本语法、diff check 与静态 secret-in-QR 扫描通过。
- [x] roadmap R1.4 验收逐项勾选，本计划完成并归档。

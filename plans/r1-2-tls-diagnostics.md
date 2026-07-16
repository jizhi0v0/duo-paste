# R1.2 TLS 到期预警 + 可脱敏诊断包

> [!IMPORTANT]
> **完成后归档。** 当前 backlog 与验收状态只以
> [`docs/roadmap.md`](../docs/roadmap.md) 为准。

状态：已完成并归档（2026-07-16）

## 安全边界

- 证书报告只读取 leaf certificate 公共信息：DNS SAN、not-before、not-after；绝不读取或
  复制 `tls_key_path` 指向的私钥。
- 30/7/1 天阈值按 `notAfter - evaluatedAt` 判定，边界为 inclusive；已过期和尚未生效均
  算 unhealthy，`mesh-doctor` 返回非零。
- 诊断包使用固定白名单文件，不复用历史导出器，不接收 BlobStore/shared-secret/private-key
  输入；不得包含数据库副本、item 正文、preview、blob 字节。
- 最近日志只保留明确的运维前缀；`capture suspect`、preview、未知行整行替换为占位符，
  防日志里的剪贴板正文被带出。
- config 从已解析的 `Config` 重新编码；TLS key path 与 URL credentials 脱敏，未知字段不透传。

## 测试先行

- [x] 真实双 SAN PEM fixture 能解析 SAN / not-before / not-after。
- [x] 同一 fixture 注入 now，稳定覆盖 valid、30d、7d、1d、expired、not-yet-valid。
- [x] mesh-doctor JSON 可解码且包含证书状态。
- [x] 诊断包自动扫描确认不含 seeded secret、私钥、剪贴板正文或 blob 字节。
- [x] 定向测试先红，实现后转绿。

## 实现

- [x] Core：TLSCertificateInspector + expiry severity + Codable report。
- [x] mesh-doctor：文本增加证书信息，支持 `--json`，证书 warning 影响退出码。
- [x] Core：DiagnosticBundleExporter 固定白名单、quick_check、脱敏 config/log、版本 manifest。
- [x] CLI：`diagnostics-export [OUTPUT_DIR]`。
- [x] Settings：展示证书 SAN/到期/30·7·1 天状态，提供诊断包导出入口。
- [x] 文档：README/CLAUDE/deploy/roadmap 同步命令、安全边界和测试计数。

## 验证

- [x] 定向 TLS / diagnostics 测试。
- [x] `swift build`、`swift test`、iOS simulator build、脚本语法、`git diff --check`。
- [x] roadmap R1.2 验收逐项打勾，本计划标为完成并归档。

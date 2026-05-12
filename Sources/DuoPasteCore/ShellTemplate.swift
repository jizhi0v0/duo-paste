import Foundation

/// CLI 子命令打印 shell 命令模板时用的安全工具。
///
/// `migrate-primary` 输出的 `scp` / `rsync` 命令会被操作员复制到自己 terminal 跑——
/// 如果路径或 hostname 含 shell 元字符，不做处理直接拼字符串会让"模板看起来像命令但
/// 实际是攻击载荷"成为可能（host = `"mini; rm -rf ~"` 之类）。即使**当前**所有输入都
/// 来自本机（Paths.makeDefault 在 ~/Library/Application Support 下、`--new-primary-host`
/// 是操作员自己输入的），让默认输出"复制即安全"是命令行工具的合理姿态。
public enum ShellTemplate {
    /// hostname 白名单校验：只允许 A-Z a-z 0-9 . - _ （含 IPv4 / hostname /
    /// Tailscale MagicDNS）。拒绝空字符串、超长输入（> 253，FQDN 上限）和任何 shell
    /// 元字符（; $ ` " ' / \ 空格 等）。
    ///
    /// **不**允许 `:`——`ssh user@host:port` 不是有效语法（scp 会把 :port 当成路径
    /// 分隔符），端口应该走 `ssh -p` / `scp -P`。当前模板不支持自定义端口，操作员
    /// 如果新机不在 22 端口需要手改命令；不在 `--new-primary-host` 入口接受 host:port
    /// 形式避免暗中生成错误命令
    ///
    /// 不做 RFC 1123 / hostname 语义校验——本工具的目的是"把 host 嵌进打印的命令
    /// 模板里安全"，不是"判断 host 合法可达"。后者由实际的 ssh/rsync 报错
    public static func isSafeHost(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        return s.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// POSIX shell single-quote 转义：内部 `'` → `'\''`，整体外加单引号。
    /// 单引号内 shell 不解释任何元字符（除 `'` 本身），是把任意字符串放进 shell
    /// 命令最安全的方式
    public static func singleQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

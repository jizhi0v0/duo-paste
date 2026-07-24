import Foundation

/// argv[1] 落在已知子命令之外时该怎么办。
///
/// 历史行为是**一律放行**走 daemon 流程（注释写着"launchctl 这种无参调用走这里"），但无参
/// 调用早在 `args.count >= 2` 那一步就返回了，`default` 分支实际只接得到**打错的**参数。
/// 结果 `duo-pasted --version` 不报错，反而静默拉起第二个 daemon 实例——重复捕获、抢全局
/// 快捷键、跟常驻实例抢 SQLite WAL 写锁（CLAUDE.md 开发工作流明令禁止的双进程状态）。
///
/// 但也不能见到未知参数就退：daemon 由 LaunchServices / launchd 拉起时，系统和调试器会塞
/// 自己的参数进来（`-psn_0_…` 进程序列号、`-NSDocumentRevisionsDebugMode YES`、
/// `-AppleLanguages (en)` 等 NSUserDefaults 风格覆盖）。这些一律是**单** `-` 前缀，拦下它们
/// 会让 daemon 在某些启动路径下起不来——比崩溃更糟。
///
/// 所以按前缀分流：单 `-` 放行给系统，`--long-flag` 和裸 token（子命令拼错）拦下。
public enum CLIInvocation {
    public enum Unrecognized: Equatable, Sendable {
        /// 大概率是系统/调试器注入的参数，照常走 daemon 流程
        case runDaemon
        /// 大概率是人在终端里打错了，打 usage 后非零退出
        case refuse
    }

    public static func classifyUnrecognized(_ argument: String) -> Unrecognized {
        if argument.hasPrefix("--") { return .refuse }
        if argument.hasPrefix("-") { return .runDaemon }
        return .refuse
    }
}

import Foundation

/// 决定「刚启动的这个 duo-pasted 进程该不该把长期运行权交回 LaunchAgent」。
///
/// ## 为什么需要它
///
/// daemon 平时由 LaunchAgent 托管，崩溃自愈完全依赖 plist 的
/// `KeepAlive={SuccessfulExit:false}`。但有多条路径会让**installed app 的进程跑在 launchd
/// 之外**：Sparkle 装完更新用 LaunchServices 重开 .app、RelaunchHelper 超时没 kickstart、
/// 用户直接在 Finder 双击 DuoPaste.app。这类孤儿进程功能上一切正常，唯独 launchd 那边
/// `state = not running`——**它一崩就彻底死了，没人拉起**。
///
/// 2026-07-24 的现场就是这样：LaunchAgent `last exit code = 0`（宿主为装更新自退，被
/// `SuccessfulExit:false` gate 正确地判为"别重启"），随后 Sparkle 重开的进程接管运行；
/// 19 小时后它崩在 NSRemoteView 断言上，launchd 手里没有任何东西可重启，用户只能手动开。
///
/// Sparkle 的 marker 文件和 RelaunchHelper 都是**事件驱动**的补救——只覆盖它们各自知道的
/// 那条更新路径，任一环节静默失败（marker 没写、helper 超时、用户手动双击）就漏。这里改成
/// **状态驱动**：每次 daemon 启动都问一句"我是 launchd 起的吗？如果不是，launchd 那边有没有
/// 一个指向同一个二进制的 job 在等着？"——不关心是谁、经由哪条路径把我拉起来的。
public enum LaunchdAdoption {
    public enum Decision: Equatable, Sendable {
        /// 就地继续跑（我就是 launchd job / 没装 agent / dev 二进制 / 信息不足）
        case continueRunning
        /// 让 launchd 起真正的 job，本进程随后退出
        case handOffToLaunchd
    }

    /// - Parameters:
    ///   - xpcServiceName: 本进程环境里的 `XPC_SERVICE_NAME`。launchd 给自己起的 job 一定
    ///     注入这个变量，值即 job label——这是判断"我是不是 launchd 亲生的"最可靠的信号，
    ///     比拿 `launchctl print` 的 pid 跟 `getpid()` 比要好：kickstart 刚返回时 launchd
    ///     可能还没记上 pid，pid 比较会假阴性并把新 job 又 kickstart 一遍。
    ///   - label: LaunchAgent label
    ///   - jobIsLoaded: job 是否已 bootstrap（`launchctl list <label>` exit 0）。**不是**
    ///     "是否正在跑"——exited 但 loaded 的 job 正是我们要 kickstart 的对象
    ///   - executablePath: 本进程二进制路径
    ///   - jobProgramPath: job plist 里的 `program`。对不上说明我是 dev build 或另一份
    ///     安装，kickstart 会启动一个**不是我**的二进制——那属于用户没 bootout 的已知
    ///     dev 场景（见 CLAUDE.md 开发工作流），不接管
    public static func decide(
        xpcServiceName: String?,
        label: String,
        jobIsLoaded: Bool,
        executablePath: String?,
        jobProgramPath: String?
    ) -> Decision {
        if xpcServiceName == label { return .continueRunning }
        guard jobIsLoaded else { return .continueRunning }
        guard let executablePath, let jobProgramPath else { return .continueRunning }
        guard normalize(executablePath) == normalize(jobProgramPath) else { return .continueRunning }
        return .handOffToLaunchd
    }

    /// symlink / `..` / 尾斜杠差异不该让同一个二进制看起来像两份安装。
    /// `~/Applications` 在部分机器上是 symlink，`resolvingSymlinksInPath` 把两边拉平。
    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

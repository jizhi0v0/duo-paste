import Foundation

/// LaunchAgent 状态查询。CLI 入口（promote-to-primary / migrate-primary）用它拦下
/// daemon 仍 loaded 的情况——这两条路径都不能容忍 daemon 在命令执行**期间或之后**
/// 还会跑：
/// - promote：daemon 仍以 client 角色 capture 出 ingested_at_ns=nil 的新行，那些行
///   不被后续 push、不再 stamp，/since 永远过滤掉
/// - migrate：daemon 在 VACUUM INTO 之后继续以 primary 角色 ingest，rsync 完成时
///   新机数据落后老机一段时间 = 静默丢数据
///
/// 检测方式：`launchctl list <label>` 在 service 已 bootstrap（loaded）时 exit 0，
/// 已 bootout（unloaded）时 exit non-zero。我们**只看 exit code 不看 PID**——
/// KeepAlive=true 的 LaunchAgent 在 daemon crash / 速率限制 / SIGTERM 之间的窗口里
/// "PID 字段暂时缺失但 service 仍 loaded"，launchd 会自动重启它。如果只看 PID 字段
/// 这种 idle 窗口会被误判为 "不在跑"，命令放行后 daemon 立刻被 launchd 复活继续
/// capture/ingest。**load 即 refuse** 才是正确语义
///
/// 任何执行错误（命令不存在、parse 失败）都返回 false 放行 dev 场景——`swift run`
/// 起的 daemon 不在 launchctl 管理下，CLAUDE.md 已写"跑 dev 二进制前先 launchctl bootout"
/// 是用户责任
enum LaunchAgent {
    static func isRunning(label: String) -> Bool {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = ["list", label]
        // 不读 stdout/stderr——只关心 exit code。Pipe 占位防止子进程的输出污染父进程
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return false
        }
        p.waitUntilExit()
        // exit 0 = service loaded（含 idle）→ daemon 随时可能（或正在）跑 → refuse
        // exit non-zero = service 未 bootstrap 或已 bootout → 安全
        return p.terminationStatus == 0
    }

    static func servicePID(label: String) -> pid_t? {
        printField(label: label, key: "pid").flatMap { pid_t($0) }
    }

    /// job plist 里的 `program`(即 launchd 会执行的二进制)。用来判断"launchd 手里那个 job
    /// 跟我是不是同一份安装"——见 LaunchdAdoption.decide。
    static func programPath(label: String) -> String? {
        printField(label: label, key: "program")
    }

    private static func printField(label: String, key: String) -> String? {
        let uid = getuid()
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = ["print", "gui/\(uid)/\(label)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        // readDataToEndOfFile 必须在 waitUntilExit 之前——`launchctl print` 的输出远超
        // pipe buffer(64KB),先 wait 会让子进程阻塞在写、父进程阻塞在 wait,直接死锁
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "\(key) = "
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// - Parameter force: `true` 走 `kickstart -k`(有实例就 kill 后重起),给"立即重启"这类
    ///   显式动作用。`false` 走裸 `kickstart`,只在 job 没跑时启动——接管路径必须用它:
    ///   万一自我识别失灵形成"接管→退出→再接管"环,`-k` 会变成无限 kill/respawn 风暴,
    ///   裸 kickstart 最坏只是 no-op。
    @discardableResult
    static func kickstart(label: String, force: Bool = true) -> Int32 {
        let uid = getuid()
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = force
            ? ["kickstart", "-k", "gui/\(uid)/\(label)"]
            : ["kickstart", "gui/\(uid)/\(label)"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return 127
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// duo-pasted LaunchAgent 的固定 label，定义在 scripts/install-agent.sh 写出的 plist 里
    static let duoPastedLabel = "io.duopaste.agent"
}

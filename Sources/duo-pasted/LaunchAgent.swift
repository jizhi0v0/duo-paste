import Foundation

/// LaunchAgent 状态查询。CLI 入口（promote-to-primary 等）用它把 daemon 在跑的情况
/// 拦下来——promote 期间 daemon 仍在 client mode 跑，会在 stamping 完成后窗口里继续
/// capture 出 ingested_at_ns=nil 的新行，那些行不会被后续 push、也不会再次 stamp，
/// /since 永远过滤掉。
///
/// 检测方式：`launchctl list <label>` 在 service 存在时输出含 `"PID"` 字段当且仅当
/// 实际有进程在跑（idle/未启动的 LaunchAgent 不输出 PID）。任何错误（命令不存在、
/// service 没 bootstrap 过、parse 失败）都返回 false，把 promote 放行——dev 场景
/// `swift run` 起的 daemon 不在 launchctl 管理下，用户自己负责（CLAUDE.md 已写"跑 dev
/// 二进制前先 launchctl bootout"）。
enum LaunchAgent {
    static func isRunning(label: String) -> Bool {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = ["list", label]
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return false
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        // launchctl list 输出格式：
        //   {
        //       "LimitLoadToSessionType" = "Aqua";
        //       "Label" = "io.duopaste.agent";
        //       "PID" = 12345;          ← 进程在跑
        //       "LastExitStatus" = 0;
        //       ...
        //   };
        // idle 状态没有 PID 字段。用 regex 精确匹配 `"PID" =` 避免误中 plist key 之类
        return s.range(of: #""PID"\s*="#, options: .regularExpression) != nil
    }

    /// duo-pasted LaunchAgent 的固定 label，定义在 scripts/install-agent.sh 写出的 plist 里
    static let duoPastedLabel = "io.duopaste.agent"
}

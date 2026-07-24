import Foundation
import Testing

@testable import DuoPasteCore

private let label = "io.duopaste.agent"
private let installed = "/Users/u/Applications/DuoPaste.app/Contents/MacOS/duo-pasted"

private func decide(
    xpc: String? = nil,
    loaded: Bool = true,
    exe: String? = installed,
    program: String? = installed
) -> LaunchdAdoption.Decision {
    LaunchdAdoption.decide(
        xpcServiceName: xpc,
        label: label,
        jobIsLoaded: loaded,
        executablePath: exe,
        jobProgramPath: program
    )
}

@Suite("LaunchAgent adoption on daemon startup")
struct LaunchdAdoptionTests {
    @Test("an orphaned copy of the installed binary hands off")
    func orphanHandsOff() {
        #expect(decide() == .handOffToLaunchd)
    }

    @Test("the launchd job itself never hands off")
    func launchdJobStaysPut() {
        // XPC_SERVICE_NAME 是 launchd 注入的自我识别信号。少了这条判定，job 会 kickstart
        // 自己再退出——每次启动都循环一遍。
        #expect(decide(xpc: label) == .continueRunning)
    }

    @Test("a job label that is not ours does not count as self-identification")
    func otherServiceNameStillHandsOff() {
        #expect(decide(xpc: "com.example.other") == .handOffToLaunchd)
    }

    @Test("no LaunchAgent installed means run standalone")
    func standaloneRuns() {
        #expect(decide(loaded: false) == .continueRunning)
    }

    @Test("a dev build never hands off to the installed job")
    func devBuildRuns() {
        // 否则 `swift run` 会莫名其妙启动 ~/Applications 里那份 release 再把自己退掉
        #expect(decide(exe: "/Users/u/dev/duo-paste/.build/debug/duo-pasted") == .continueRunning)
    }

    @Test("unknown paths are not assumed to match")
    func missingPathsRun() {
        #expect(decide(exe: nil) == .continueRunning)
        #expect(decide(program: nil) == .continueRunning)
    }

    @Test("symlinked and unnormalized paths still count as the same install")
    func pathNormalization() {
        #expect(decide(exe: "/Users/u/Applications/../Applications/DuoPaste.app/Contents/MacOS/duo-pasted")
            == .handOffToLaunchd)
    }
}

@Suite("Unrecognized CLI argument handling")
struct CLIInvocationTests {
    @Test("a mistyped long flag is refused instead of booting a second daemon")
    func longFlagRefused() {
        // `duo-pasted --version` 曾静默拉起第二个 daemon 实例：重复捕获 + 抢全局快捷键 +
        // 跟常驻实例抢 SQLite WAL 写锁
        #expect(CLIInvocation.classifyUnrecognized("--version") == .refuse)
        #expect(CLIInvocation.classifyUnrecognized("--nope") == .refuse)
    }

    @Test("a mistyped subcommand is refused")
    func bareTokenRefused() {
        #expect(CLIInvocation.classifyUnrecognized("mesh-doctr") == .refuse)
    }

    @Test("system and debugger injected arguments still boot the daemon")
    func systemArgumentsPassThrough() {
        // 拦下这些会让 daemon 在某些启动路径下起不来——比崩溃更糟
        #expect(CLIInvocation.classifyUnrecognized("-psn_0_12345") == .runDaemon)
        #expect(CLIInvocation.classifyUnrecognized("-NSDocumentRevisionsDebugMode") == .runDaemon)
        #expect(CLIInvocation.classifyUnrecognized("-AppleLanguages") == .runDaemon)
    }
}

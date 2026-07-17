import AppKit
import SwiftUI
import DuoPasteCore
import DuoPasteCapture
import DuoPasteSync

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Settings scene 里的业务视图通过这个弱引用读取 daemon 运行状态。
    /// 单 daemon 进程内永远只有 1 个 AppDelegate。
    static weak var shared: AppDelegate?

    private var deps: AppDependencies!
    var state: AppState!  // SwiftUI Settings 读
    /// SwiftUI Settings 读 config / paths / device-id / blobs 路径
    var dependencies: AppDependencies? { deps }

    /// SettingsView 调用：rebuild/abort OCR 索引后立刻 wake worker 缩短到下一 tick。
    /// nonisolated wake() 内部走 actor hop，主线程调用安全。
    func wakeOCRWorker() {
        ocrWorker?.wake()
    }
    private var panel: SearchPanelController!
    private var statusBar: StatusBarController!
    private var watcher: PasteboardWatcher!
    private var hotkey: GlobalHotKey!
    private var snapshotScheduler: SnapshotScheduler!
    private var memorySampler: MemorySampler!
    private var serverTask: Task<Void, Never>?
    private var bonjourAdvertiser: BonjourAdvertiser?
    /// daemon 启动时构造一份。Mac Settings"显示配对码"调它 generatePIN(),
    /// /pair/<pin> 路由调它 validateAndConsumePIN
    private(set) var pairingService: PairingService?
    /// 新 PIN 客户端的独立 credential 签发/验签入口。只在 serve + shared-secret 可用时存在。
    private(set) var credentialAuthenticator: DeviceCredentialAuthenticator?
    /// MeshSupervisor 起来后构造,周期 fetch mesh peer 的 /endpoints,聚合给本机
    /// /endpoints 路由暴露 + snapshot 变化时通过 wsBroadcaster 推 endpoints_changed
    private var meshEndpointsCache: MeshEndpointsCache?
    /// Mesh peer 拉取入口。PR 2 单 peer 部署下 supervisor 内只有一个 PullWorker，行为跟原
    /// `pullWorker: PullWorker?` 等价；PR 5 mesh-init 后多 peer 列表自然 fan-out 进 N 个 worker
    private var meshSupervisor: MeshSupervisor?
    /// 本机 OCR worker。`config.ocr.enabled=true` 才启动；启动条件跟 mesh 解耦，
    /// 任何拓扑（standalone / mesh peer）都跑 own-origin image OCR
    private var ocrWorker: OCRWorker?
    /// lazy blob 拉取：image kind + 本机 BlobStore 缺字节时按需 GET /blob/<sha> 到本地。
    /// 跟 PullWorker 共享 HTTPPeerClient 配置（同一 baseURL + auth），
    /// nil → standalone 模式或加载 shared-secret 失败，pasteBack 缺字节时显示错误而非干跑
    private var pasteBlobFetcher: BlobFetcher?
    /// 当前在跑的 lazy paste task。多次按 Enter 时先 cancel 旧 task 再起新的，
    /// 避免重复拉同一 sha 的字节竞争 BlobStore.put
    private var currentPasteTask: Task<Void, Never>?
    /// lazy 拉超时。走 Tailscale DERP 中继时 TLS 握手本身就需 3s+；30s 给足余量。
    /// nonisolated 让 TaskGroup 的 sleeper task 能 capture（详 fetchBlobLazy）
    nonisolated static let lazyBlobTimeoutSec: TimeInterval = 30

    private var currentExportTask: Task<Void, Never>?
    private var exportGeneration = 0
    private var exportProgressKey = 0
    private var exportIsVacuuming = false
    private var diagnosticExportInFlight = false

    private static var reopenSettingsFlag: URL {
        Paths.makeDefault().root.appendingPathComponent("reopen-settings-on-launch")
    }

    private static func consumeReopenSettingsFlag() -> Bool {
        let url = reopenSettingsFlag
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    /// 抓一次 AXIsProcessTrusted 写进 state。启动末尾 + SettingsView "刷新"按钮调。
    /// AX 没有 KVO/通知,用户在系统设置里勾完没办法立即知道,只能让用户主动触发刷新
    func refreshAccessibilityTrusted() {
        let trusted = AXIsProcessTrusted()
        state.accessibilityTrusted = trusted
        if !trusted {
            fputs("accessibility · not trusted — PasteInjector 静默退化,用户需手动 Cmd+V\n", stderr)
        }
    }

    /// SettingsView apply 后调用——重读 config.hotkey 把 GlobalHotKey 重 register 到新组合。
    /// 零成本（register API 幂等：先 unregister 旧 + remove 旧 handler，再 register 新）。
    /// **关键**：必须重新 load 一次 config 拿最新值；deps.config 是 daemon 启动时快照不会变
    func reloadHotkey() {
        guard hotkey != nil else { return }
        let cfg: Config
        do {
            cfg = try Config.load(from: deps.paths.configFile)
        } catch {
            fputs("reloadHotkey: 读 config 失败：\(error)\n", stderr)
            return
        }
        do {
            let translated = try HotkeyTranslation.translate(cfg.hotkey)
            try hotkey.register(
                keyCode: translated.keyCode,
                carbonModifiers: translated.modifiers
            ) { [weak self] in
                self?.panel.toggle()
            }
            statusBar?.updateOpenSearchHotkey(cfg.hotkey)
            fputs("hotkey re-registered: \(cfg.hotkey.modifiers.joined(separator: "+"))+\(cfg.hotkey.key)\n", stderr)
        } catch {
            fputs("reloadHotkey: register 失败：\(error)\n", stderr)
        }
    }

    /// Settings 对 excluded_bundle_ids 的热重载：AppState 先更新让 watcher gate 立即生效，
    /// CaptureService 随后更新第二道零写入门。其他 capture limits 仍按原约定需重启。
    func reloadCapturePolicy() {
        let cfg: Config
        do {
            cfg = try Config.load(from: deps.paths.configFile)
        } catch {
            fputs("reloadCapturePolicy: 读 config 失败：\(error)\n", stderr)
            return
        }
        state.updateExcludedBundleIDs(cfg.capture.excludedBundleIDs)
        let service = deps.captureService
        Task {
            await service.updateExcludedBundleIDs(cfg.capture.excludedBundleIDs)
        }
        fputs("capture exclusions reloaded: \(cfg.capture.excludedBundleIDs.count) bundle id(s)\n", stderr)
    }

    func pauseCapture(minutes: Int) {
        state.pauseCapture(for: TimeInterval(max(1, minutes) * 60))
    }

    func pauseCaptureUntilResumed() {
        state.pauseCaptureUntilResumed()
    }

    func resumeCapture() {
        state.resumeCapture()
    }

    func listDeviceCredentials() async throws -> [DeviceCredentialRecord] {
        try await deps.database.listDeviceCredentials()
    }

    func revokeDeviceCredential(_ credentialID: String) async throws {
        if let credentialAuthenticator {
            _ = try await credentialAuthenticator.revoke(
                credentialID: credentialID,
                revokedByDeviceID: deps.deviceID
            )
        } else {
            _ = try await deps.database.revokeDeviceCredential(
                credentialID: credentialID,
                revokedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
                revokedByDeviceID: deps.deviceID
            )
        }
        // 已建立连接没有新的 HTTP/WS handshake；立即 rotation 才能让被撤销设备失效。
        await deps.wsBroadcaster.rotateAllConnections()
    }

    /// SettingsView「立即重启 daemon」按钮调用——退出让 launchd KeepAlive 自动 respawn
    /// 新进程，新进程重读 config 让所有非热重载字段生效。
    ///
    /// **必须 exit 非 0**：plist 的 KeepAlive 是 `{SuccessfulExit:false}`（Sparkle 自动更新
    /// 方案 A 的前提——Sparkle clean exit 0 不重启、让位安装）。exit(0) 会被这条 gate 当
    /// 「正常退出」**不重启**，重启按钮就失效了。用 173 只为在日志里跟 fatal(1) 区分，
    /// launchd 只认 0 vs 非 0，数值本身无特殊含义。详 install-agent.sh KeepAlive 段。
    func restartDaemon() {
        try? "1".write(to: Self.reopenSettingsFlag, atomically: true, encoding: .utf8)
        fputs("restart requested via settings — exiting(173) for launchd respawn\n", stderr)
        exit(173)
    }

    func showSettings() {
        if bringSettingsWindowForward() {
            return
        }

        // `.accessory` app 在未激活时发送 Settings selector，responder chain 可能报告
        // handled 但不真正 materialize scene。先激活保证首次创建发生；窗口挂载后
        // `bringSettingsWindowForward()` 还会再激活一次并明确 order front。
        NSApp.activate(ignoringOtherApps: true)

        // Settings scene 由 SwiftUI 注册在 responder chain。从 NSMenu tracking loop 返回后
        // 发 selector，让系统继续管理单例窗口、标题栏和 TabView 外观。首次创建是异步的，
        // 等 SettingsWindowProbe 拿到真实 NSWindow 后再 activate + order front。
        let selectors = ["showSettingsWindow:", "showPreferencesWindow:"]
        for name in selectors {
            if NSApp.sendAction(NSSelectorFromString(name), to: nil, from: nil) {
                bringSettingsWindowForwardWhenReady(attempt: 0)
                return
            }
        }
        fputs("settings: Settings scene selector unavailable\n", stderr)
    }

    @discardableResult
    private func bringSettingsWindowForward() -> Bool {
        guard let window = SettingsWindowBridge.window else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }

    private func bringSettingsWindowForwardWhenReady(attempt: Int) {
        if bringSettingsWindowForward() {
            return
        }
        guard attempt < 20 else {
            fputs("settings: Settings window unavailable after 1s\n", stderr)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.bringSettingsWindowForwardWhenReady(attempt: attempt + 1)
        }
    }

    func toggleSearch() {
        panel?.toggle()
    }

    func openSavedSearchView(id: String) {
        guard state.applySavedSearchView(id: id) else {
            statusBar?.updateSavedSearchViews(state.savedSearchViews)
            return
        }
        panel.show()
    }

    func confirmQuit() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出 duo-paste？"
        alert.informativeText = "退出后剪贴板捕获与跨设备同步会停止，直到下次开机自启，"
            + "或手动运行 install-agent.sh / launchctl kickstart 重新启动。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Export

    func showExportDialog() {
        guard currentExportTask == nil else { return }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "导出剪贴板历史"
        alert.informativeText = "选择导出格式和目标目录。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "选择目录…")
        alert.addButton(withTitle: "取消")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 64))

        let formatLabel = NSTextField(labelWithString: "格式：")
        formatLabel.frame = NSRect(x: 0, y: 36, width: 50, height: 20)
        accessory.addSubview(formatLabel)

        let formats: [(String, ExportFormat)] = [
            ("JSON", .json), ("Markdown", .markdown), ("SQLite", .sqlite),
        ]
        let formatPopup = NSPopUpButton(frame: NSRect(x: 52, y: 34, width: 160, height: 24), pullsDown: false)
        formatPopup.addItems(withTitles: formats.map(\.0))
        accessory.addSubview(formatPopup)

        let blobCheck = NSButton(checkboxWithTitle: "包含图片和文件字节", target: nil, action: nil)
        blobCheck.frame = NSRect(x: 0, y: 4, width: 220, height: 20)
        blobCheck.state = .on
        accessory.addSubview(blobCheck)

        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let formatIndex = max(0, min(formatPopup.indexOfSelectedItem, formats.count - 1))
        let format = formats[formatIndex].1
        let includeBlobs = blobCheck.state == .on

        let panel = NSOpenPanel()
        panel.message = "选择导出目录"
        panel.prompt = "导出"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let exportDir = dir.appendingPathComponent(
            "duo-paste-export-\(Self.exportTimestamp())", isDirectory: true
        )

        guard let deps = self.deps else { return }
        let exporter = Exporter(database: deps.database, blobs: deps.blobs)
        let options = ExportOptions(format: format, includeBlobs: includeBlobs)

        exportGeneration += 1
        exportProgressKey = 0
        let gen = exportGeneration

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try exporter.export(to: exportDir, options: options) { p in
                    let key: Int
                    switch p.phase {
                    case .vacuuming: key = 0
                    case .exporting: key = p.current
                    case .copyingBlobs: key = Int.max / 2 + p.current
                    }
                    Task { @MainActor in
                        guard self?.exportGeneration == gen else { return }
                        guard key >= self?.exportProgressKey ?? 0 else { return }
                        self?.exportProgressKey = key
                        switch p.phase {
                        case .vacuuming:
                            self?.exportIsVacuuming = true
                            if self?.currentExportTask?.isCancelled == true {
                                self?.statusBar?.setExportProgress("等待 VACUUM 完成后取消…")
                            } else {
                                self?.statusBar?.setExportProgress("正在生成 SQLite 副本…")
                            }
                        case .exporting:
                            self?.exportIsVacuuming = false
                            self?.statusBar?.setExportProgress("取消导出 (\(p.current)/\(p.total))")
                        case .copyingBlobs:
                            self?.exportIsVacuuming = false
                            self?.statusBar?.setExportProgress("取消导出 (复制 \(p.current)/\(p.total))")
                        }
                    }
                }
                await MainActor.run {
                    guard self?.exportGeneration == gen else { return }
                    self?.finishExport()
                    let done = NSAlert()
                    done.alertStyle = .informational
                    done.messageText = "导出完成"
                    let blobLine = result.blobCount > 0 ? "\n图片/文件：\(result.blobCount) 个" : ""
                    let countLine: String
                    if format == .sqlite {
                        countLine = "完整数据库副本：\(result.itemCount) 条物理行（含跨设备重复及已删除项）"
                    } else {
                        countLine = "共 \(result.itemCount) 条记录"
                    }
                    done.informativeText = "\(countLine)\(blobLine)\n位置：\(exportDir.path)"
                    done.addButton(withTitle: "在 Finder 中显示")
                    done.addButton(withTitle: "好")
                    if done.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.selectFile(
                            result.destination.path,
                            inFileViewerRootedAtPath: exportDir.path
                        )
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self?.exportGeneration == gen else { return }
                    self?.finishExport()
                }
            } catch {
                await MainActor.run {
                    guard self?.exportGeneration == gen else { return }
                    self?.finishExport()
                    let err = NSAlert()
                    err.alertStyle = .critical
                    err.messageText = "导出失败"
                    err.informativeText = String(describing: error)
                    err.runModal()
                }
            }
        }
        currentExportTask = task
        statusBar?.setExportProgress("取消导出…")
    }

    func cancelExport() {
        currentExportTask?.cancel()
        if exportIsVacuuming {
            statusBar?.setExportProgress("等待 VACUUM 完成后取消…")
        }
    }

    /// Settings「导出安全诊断包」。与历史 Exporter 完全分开：只把 mesh-doctor、
    /// quick_check、版本、脱敏 config 和白名单日志交给 DiagnosticBundleExporter。
    func showDiagnosticExportDialog() {
        guard !diagnosticExportInFlight, let deps else { return }

        let panel = NSOpenPanel()
        panel.message = "选择安全诊断包的导出目录"
        panel.prompt = "导出诊断包"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let destination = parent.appendingPathComponent(
            "duo-paste-diagnostics-\(Self.exportTimestamp())",
            isDirectory: true
        )
        diagnosticExportInFlight = true

        let config = deps.config
        let deviceID = deps.deviceID
        let databasePath = deps.paths.mainDB
        let blobs = deps.blobs
        let secret = try? SharedSecret.load(from: deps.paths.sharedSecretFile)
        let logsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/duo-paste", isDirectory: true)
        let logFiles = ["duo-pasted.out.log", "duo-pasted.err.log"].map {
            logsRoot.appendingPathComponent($0)
        }
        let tlsState = Self.tlsCertificateState(for: config)
        let version = Self.diagnosticVersionInfo()
        let syncSession = AppDependencies.syncURLSession

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let probe: @Sendable (URL) async -> Admin.HealthProbeOutcome = { url in
                    guard let secret else {
                        return .unreachable(reason: "shared-secret 未配置")
                    }
                    let client = HTTPPeerClient(
                        baseURL: url,
                        auth: HMACAuth(secret: secret),
                        session: PonteSession.session(for: url, fallback: syncSession)
                    )
                    do {
                        let response = try await client.fetchPrimaryHealth()
                        switch response.outcome {
                        case .ok(let id, let nowMs, _): return .ok(deviceID: id, nowMs: nowMs)
                        case .unreachable(let reason): return .unreachable(reason: reason)
                        case .rejected(let reason): return .rejected(reason: reason)
                        }
                    } catch {
                        return .unreachable(reason: String(describing: error))
                    }
                }
                let doctor = try await Admin.meshDoctor(
                    selfDeviceID: deviceID,
                    peers: config.peers,
                    dbPath: databasePath,
                    blobs: blobs,
                    healthProbe: probe,
                    tlsCertificate: tlsState
                )
                let result = try DiagnosticBundleExporter.export(
                    to: destination,
                    config: config,
                    meshDoctorReport: doctor,
                    databasePath: databasePath,
                    logFiles: logFiles,
                    version: version
                )
                await MainActor.run {
                    guard let self else { return }
                    self.diagnosticExportInFlight = false
                    let alert = NSAlert()
                    alert.alertStyle = .informational
                    alert.messageText = "安全诊断包已导出"
                    alert.informativeText = "不含 shared-secret、私钥、剪贴板正文或 blob。\n位置：\(result.directory.path)"
                    alert.addButton(withTitle: "在 Finder 中显示")
                    alert.addButton(withTitle: "好")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: result.directory.path)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.diagnosticExportInFlight = false
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "诊断包导出失败"
                    alert.informativeText = String(describing: error)
                    alert.runModal()
                }
            }
        }
    }

    private func finishExport() {
        exportGeneration += 1
        exportProgressKey = 0
        exportIsVacuuming = false
        statusBar?.setExportProgress(nil)
        currentExportTask = nil
    }

    private static func exportTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func tlsCertificateState(for config: Config, now: Date = Date()) -> TLSCertificateState {
        guard config.serveTLS else { return .notConfigured }
        guard let path = config.tlsCertPath else {
            return .unreadable("serve_tls=true 但 tls_cert_path 缺失")
        }
        do {
            return .inspected(try TLSCertificateInspector.inspect(
                at: URL(fileURLWithPath: path),
                now: now
            ))
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    private static func diagnosticVersionInfo() -> DiagnosticBundleExporter.VersionInfo {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return DiagnosticBundleExporter.VersionInfo(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture
        )
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 只保留 Settings scene + AppKit NSStatusItem 时，SwiftUI 没有常驻的可见 scene。
        // 应用被激活后若仍无窗口，AppKit 可能把它当作可 automatic termination
        // 的普通 UI app，以 exit 0 收掉。duo-paste 是 launchd 托管的常驻 daemon，
        // capture / sync / hotkey 都必须在无窗口时继续运行，因此显式禁用自动终止。
        ProcessInfo.processInfo.disableAutomaticTermination("duo-paste background daemon")
        // 早一点切 accessory，避免 Dock 闪一下
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        do {
            deps = try AppDependencies()
        } catch {
            fputs("fatal: bootstrap deps failed: \(error)\n", stderr)
            // 非 0 退出让 launchd（KeepAlive={SuccessfulExit:false}）重启重试——bootstrap
            // 失败常是 transient（DB 临时被占 / snapshot 中）。**不能**用 NSApp.terminate：
            // 它走 exit 0，会被 SuccessfulExit gate 当「正常退出」不重启，daemon 就此死掉。
            // 这条 gate 是 Sparkle 自动更新方案 A 的前提（Sparkle clean exit 0 不重启，
            // 让位安装；崩溃/fatal 非 0 才重启自愈）。详 install-agent.sh KeepAlive 段。
            exit(1)
        }

        state = AppState(deps: deps)
        state.onPinOperationQueued = { [weak self] in
            self?.meshSupervisor?.wakeAll()
        }
        panel = SearchPanelController(
            state: state,
            onPaste: { [weak self] items in self?.pasteBack(items) },
            onPastePlainText: { [weak self] items in self?.pasteBackPlainText(items) },
            onReveal: { [weak self] item in self?.revealInFinder(item) },
            onOpenWith: { [weak self] item, app in self?.openWith(item, app: app) },
            onDismiss: { [weak self] in self?.cancelLazyPasteIfAny() },
            // 搜索 panel 右上角齿轮——先 hide 搜索 panel(显式,不依赖 resignKey 自动 hide:
            // preview 打开时 resignKey 被守卫不会触发),再打开 Settings 窗口
            onOpenSettings: { [weak self] in
                self?.panel.hide()
                self?.showSettings()
            },
            // previewShown=true 时 ⌘C 触发——把文本预览选中字符串写 NSPasteboard。
            // 走 watcher.pasteBack barrier:写入期间 isPasteBackInFlight=true 让
            // tick 跳过这一拍 + 完成后 suppressUpToCurrent 把 lastChangeCount 推齐,
            // 不会把自家复制再 capture 入库。self-pid 过滤兜不住——panel 不抢
            // frontmost,extract 里 frontApp.pid 是用户上一个 app 不是 self
            onCopyText: { [weak self] text in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.watcher.pasteBack { () -> Bool in
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        return pb.setString(text, forType: .string)
                    }
                }
            }
        )
        statusBar = StatusBarController(
            hotkey: deps.config.hotkey,
            savedSearchViews: state.savedSearchViews
        )
        state.onCapturePauseChanged = { [weak self] pause in
            self?.statusBar.updateCapturePause(pause)
        }
        state.onSavedSearchViewsChanged = { [weak self] views in
            self?.statusBar.updateSavedSearchViews(views)
        }
        statusBar.updateCapturePause(state.capturePause)
        watcher = PasteboardWatcher(
            maxRawRTFBytes: deps.config.capture.maxTextBytes,
            maxBlobBytes: deps.config.capture.maxBlobBytes,
            shouldCapture: { [weak self] bundleID in
                self?.state.shouldCapture(sourceAppBundleID: bundleID) ?? true
            },
            onCapture: { [weak self] captured in
                self?.handleCapture(captured)
            }
        )
        // actor 后台轮询——start() 现在 actor-isolated,fire-and-forget Task 调
        let bgWatcher = watcher!
        Task { await bgWatcher.start() }

        hotkey = GlobalHotKey()
        registerHotkeyWithFallback()

        snapshotScheduler = SnapshotScheduler(deps: deps)
        snapshotScheduler.start()

        memorySampler = MemorySampler(deps: deps)
        memorySampler.start()

        // "打开方式" 临时文件清理:删 24h 以上旧 staging 子目录。挂在 detached low-priority
        // 队列,不阻塞 launch。staging 目录不存在直接 no-op,首次运行无副作用
        let stagingRoot = deps.paths.openWithStagingDir
        Task.detached(priority: .background) {
            OpenWithStaging.cleanupOldStaging(root: stagingRoot)
        }

        if deps.config.serve {
            startSyncServer()
            // 启 wsBroadcaster rotation 任务（只 serve 时才有意义——broadcaster 才有 connections
            // 来 close）。auth 安全 hardening：每 4h 主动 close 所有 ws 连接强制 client 用最新
            // shared-secret 重新做 HMAC upgrade，secret 被窃取后能监听窗口压到 ≤ rotation interval
            let broadcaster = deps.wsBroadcaster
            Task { await broadcaster.start() }
            // Bonjour 广播让 iOS Settings 的"发现的 Mac"列表能看见这台。secret 不在 TXT 里——
            // 走 QR 二次配对(Mac Settings 主动展开后 60s 内显示)
            bonjourAdvertiser = BonjourAdvertiser(
                port: deps.config.servePort,
                deviceID: deps.deviceID,
                tls: deps.config.serveTLS
            )
            bonjourAdvertiser?.start()
        }
        // PR 3 smart transport：mesh + paste-fetcher 都先 discover 学到对端 ponte_host，
        // 再按决定建 worker / fetcher。两者共享同一 discover 结果走同一 Task 串行启动避免
        // 重复 /health 探测（per peer 2 个 candidate × 3s timeout）
        let needMesh = deps.config.mesh.enabled && !deps.config.peers.isEmpty
        let needPasteFetcher = !deps.config.peers.isEmpty
        if needMesh || needPasteFetcher {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.startWithSmartTransport(startMesh: needMesh, startPasteFetcher: needPasteFetcher)
            }
        }

        // Blob 仓库 baseline 扫盘：detached 后台一次 directorySize → setBaseline。
        // Settings 关于页订阅 blobStats.stream() 在 baseline 落盘前看到 nil = "计算中…"。
        let blobsDir = deps.paths.blobsDir
        let blobStats = deps.blobStats
        Task.detached(priority: .utility) {
            let total = Volume.directorySize(at: blobsDir) ?? 0
            await blobStats.setBaseline(total)
        }

        // Lazy migration: 回填 file kind 图片扩展但无 blob 字节的本机行。
        // 历史背景:CleanShot 等工具复制截图时,PasteboardWatcher 当时没读到字节
        // (读失败 / 路径权限 / 旧版本) → 只存了文件路径,blob 字段空 → OCRWorker 跳过。
        // 重启 daemon 时尝试再读一遍本地路径,把缺字节的行补上;补完 ocr_state=pending
        // 让 OCRWorker 自然扫到。文件已删 / 超 cap 的行原样跳过,不会再尝试(下次启动
        // 仍扫,但 fileMissing 谓词命中跳过,代价微小)。
        // detached Task 不阻塞 UI ready 路径——OCR 不急,reads/writes 独立 DB 连接
        let dbPath = deps.paths.mainDB
        let blobsBaseURL = deps.paths.blobsDir
        let selfDeviceID = deps.deviceID
        let captureMaxBytes = deps.config.capture.maxBlobBytes
        Task.detached(priority: .utility) {
            do {
                let report = try Admin.refillMissingImageBlobs(
                    dbPath: dbPath,
                    blobsDir: blobsBaseURL,
                    selfDeviceID: selfDeviceID,
                    maxBlobBytes: captureMaxBytes,
                    log: { msg in
                        fputs("\(msg)\n", stderr)
                    }
                )
                if report.refilled > 0 {
                    // 有新填的 blob → wake OCR worker 立即扫,避免等 idle 周期
                    await MainActor.run { AppDelegate.shared?.wakeOCRWorker() }
                }
                fputs("startup-migration · refill-image-blobs · \(report.summary)\n", stderr)
            } catch {
                fputs("startup-migration · refill-image-blobs · 失败: \(error)\n", stderr)
            }
        }

        // OCR worker：本机 own-origin image 跑 Vision OCR 把图里文字写 text_full 进 FTS5。
        // 启动条件 = config.ocr.enabled，跟 push/pull/serve 解耦——任何 role 都跑自家
        // OCR（分布式 MVP，每台 Mac 自跑自家 origin=self，结果不跨设备同步；详 plan
        // vivid-scanning-vellum.md §1 设计原则）
        if deps.config.ocr.enabled {
            startOCRWorker()
        }

        // Accessibility 权限快照——PasteInjector.injectCmdV 需要(CGEvent.post 不走
        // accessibility 静默失败,pasteboard 已写用户可以自己 Cmd+V,但用户不知道为
        // 什么没"自动落到 caret")。Settings 里"自动粘贴权限"行用这个 flag 显示状态
        // + 引导用户去系统设置勾选。授权完用户手动按 Settings 的"刷新"或者重启
        // daemon 才会更新这个值——AX 没有 KVO/通知
        refreshAccessibilityTrusted()

        fputs("duo-paste UI ready · device=\(deps.deviceID) · mode=\(deps.config.summary) · storage_mode=\(deps.config.mesh.storageMode.rawValue) · db=\(deps.paths.mainDB.path)\n", stderr)

        // Sparkle 自动更新（方案 A）——SUFeedURL 存在才启。读这个 lazy static 触发
        // UpdaterController 初始化 → SPUStandardUpdaterController(startingUpdater:true)
        // 开始周期检查。DP_NO_SPARKLE 本地构建不写 SU 键 → 不实例化，避免 Sparkle 报
        // feed 缺失。手动「检查更新」入口见 MenuBarExtra / SettingsView 关于页。
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            _ = UpdaterController.shared
        }

        if Self.consumeReopenSettingsFlag() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showSettings()
            }
        }
    }

    /// 用 config.hotkey 注册 Carbon 全局快捷键；失败时回退到默认 ⌥⌘V 再试一次。
    /// 失败原因常见两种：(1) 别的 app 已经占用了同样的组合（如 Alfred 抢 ⌘Space），
    /// 此时回退默认能让 daemon 至少有一条入口；(2) translate 失败属程序员错误（Config
    /// 应已 validate），但 fallback 路径用默认参数直接走 register 默认值，绕过 translate
    private func registerHotkeyWithFallback() {
        let cfg = deps.config.hotkey
        do {
            let translated = try HotkeyTranslation.translate(cfg)
            try hotkey.register(
                keyCode: translated.keyCode,
                carbonModifiers: translated.modifiers
            ) { [weak self] in
                self?.panel.toggle()
            }
            fputs("hotkey registered: \(cfg.modifiers.joined(separator: "+"))+\(cfg.key)\n", stderr)
            return
        } catch {
            fputs("hotkey register failed (\(cfg.modifiers.joined(separator: "+"))+\(cfg.key)): \(error). falling back to default ⌥⌘V\n", stderr)
        }
        // 已经是默认组合还是挂了，那真的没救了——光留菜单栏入口
        if cfg == Config.HotkeyConfig.default {
            fputs("hotkey fallback skipped: already on default ⌥⌘V\n", stderr)
            return
        }
        do {
            try hotkey.register(onFire: { [weak self] in
                self?.panel.toggle()
            })
            fputs("hotkey registered (fallback): option+cmd+V\n", stderr)
        } catch {
            fputs("hotkey fallback also failed: \(error). only menu bar entry available\n", stderr)
        }
    }


    /// PR 3：mesh supervisor + paste-fetcher 一起 discover-first 启动。每个 peer 探一次
    /// `/health` 学对端 `ponte_host` 自动 fill ponte URL（替代用户手抄 `pull_url`）。
    /// 决策优先级：手抄 `pull_url` > 学到 ponte_host > tailscale `peer.url`（见 SmartTransport
    /// docstring）。
    ///
    /// 决策好之后 PeerBuilder 按 host 选 NIO 还是 URLSession transport——ponte 路径下 WS 走
    /// URLSession + PonteSession proxy；tailscale 路径仍走 NIO 直连
    private func startWithSmartTransport(startMesh: Bool, startPasteFetcher: Bool) async {
        let cfg = deps.config
        let auth: HMACAuth
        do {
            let secret = try SharedSecret.load(from: deps.paths.sharedSecretFile)
            auth = HMACAuth(secret: secret)
        } catch {
            fputs("smart transport NOT started: 加载 shared-secret 失败：\(error)\n", stderr)
            return
        }
        let smart = SmartTransport()
        let decisions = await smart.discover(
            peers: cfg.peers,
            auth: auth,
            tailscaleSession: AppDependencies.syncURLSession
        )
        for d in decisions {
            fputs(
                "smart-transport: peer \(d.peerIndex) → \(d.transportLabel)" +
                (d.learnedPonteHost.map { " (learned ponte_host=\($0))" } ?? "") +
                "\n",
                stderr
            )
        }
        // 让 SettingsView 一打开就能看到初始决策（reconcile 完后 onDecisionsUpdated 再刷）
        self.state.setTransports(decisions)

        // 起 mesh supervisor(如果该起)
        if startMesh {
            let intervalSec = max(1, cfg.mesh.pullIntervalSec)
            // PullWorker /health tick → AppState 的实时回写通道。weak 防 PullWorker 通过 closure
            // 持 strong AppState(AppDelegate 也持 state),hop @MainActor 让 setter 在正确 isolation
            let appState = self.state
            let onHealthProbedCb: @Sendable (Int, Int64) -> Void = { [weak appState] peerIdx, rttMs in
                Task { @MainActor in
                    appState?.updateChosenHostRtt(peerIndex: peerIdx, rttMs: rttMs)
                }
            }
            // B5 quick recovery:PullWorker 连续 transient 失败到 threshold 时调一次。
            // closure fire 时 self.meshSupervisor 已 set(builder 之后才创建 supervisor 但
            // closure 调用必然在 daemon 跑起来之后)。reconcileTransports 自带 ReconcileGate
            // 防 storm,DNS / 周期 timer / B5 三路 trigger 进同一个 gate 不会重复 discover
            let onChosenLikelyDownCb: @Sendable (Int) -> Void = { [weak self] _ in
                Task { @MainActor in
                    await self?.meshSupervisor?.reconcileTransports()
                }
            }
            let builder = SmartTransport.PeerBuilder(
                database: deps.database,
                blobs: deps.blobs,
                meshStatus: deps.meshStatus,
                pasteSuppressions: deps.pasteSuppressions,
                selfDeviceID: deps.deviceID,
                evictOnFull: deps.evictOnFull,
                pullWorkerConfig: PullWorker.Config(
                    intervalSec: TimeInterval(intervalSec),
                    crossDeviceDedupWindowNs: cfg.mesh.crossDeviceDedupWindowNs,
                    storageMode: cfg.mesh.storageMode
                ),
                wsEnabled: cfg.mesh.wsEnabled,
                auth: auth,
                tailscaleSession: AppDependencies.syncURLSession,
                onCatastrophicFailure: {
                    FileHandle.standardError.write(Data(
                        "ws-client: catastrophic — exiting to let launchd restart\n".utf8
                    ))
                    exit(1)
                },
                expectedPeerDeviceIDs: cfg.peers.map { $0.deviceID },
                onHealthProbed: onHealthProbedCb,
                onChosenLikelyDown: onChosenLikelyDownCb,
                onPinOperationsResolved: { [weak appState] in
                    Task { @MainActor [weak appState] in
                        await appState?.refresh()
                    }
                },
                onCredentialRevocationsMerged: { [broadcaster = deps.wsBroadcaster] _ in
                    Task { await broadcaster.rotateAllConnections() }
                }
            )
            let supervisorPeers = decisions.map { builder.build(decision: $0) }
            // reconcile 完后 hop 回 main actor 写 AppState,SwiftUI 自动刷新 SettingsView
            // weak appState 防 supervisor 持 strong cycle(AppDelegate 也持 supervisor)
            // reconcile 完成回调:既 push 到 AppState 让 Settings 显示新 transport,也踢
            // MeshEndpointsCache 立即 refreshNow——避免新发现的 peer / ponte_host 等
            // 周期 60s 才出现在 iOS 端
            let onDecisionsUpdated: @Sendable ([SmartTransport.PeerDecision]) -> Void = { [weak self, weak appState] newDecisions in
                Task { @MainActor [weak appState] in
                    appState?.setTransports(newDecisions)
                }
                Task { @MainActor [weak self] in
                    if let cache = self?.meshEndpointsCache {
                        await cache.refreshNow()
                    }
                }
            }
            let supervisor = MeshSupervisor(
                initialPeers: supervisorPeers,
                initialDecisions: decisions,
                smart: smart,
                configPeers: cfg.peers,
                auth: auth,
                tailscaleSession: AppDependencies.syncURLSession,
                buildPeer: { builder.build(decision: $0) },
                onDecisionsUpdated: onDecisionsUpdated
            )
            self.meshSupervisor = supervisor
            await supervisor.start()
            fputs("mesh supervisor → \(supervisorPeers.count) peer(s) (interval=\(intervalSec)s, ws=\(cfg.mesh.wsEnabled ? "on" : "off"))\n", stderr)

            // 装配 MeshEndpointsCache:周期 fetch mesh peer 的 /endpoints,聚合给本机
            // /endpoints 暴露给 iOS。snapshot 变化时让 broadcaster 推 endpoints_changed
            // 给 client(iOS) re-fetch + re-probe
            let broadcaster = deps.wsBroadcaster
            let cache = MeshEndpointsCache.production(
                supervisor: supervisor,
                auth: auth,
                selfDeviceID: deps.deviceID,
                session: AppDependencies.syncURLSession,
                onSnapshotChanged: { updatedAtUnix in
                    Task {
                        await broadcaster.broadcastEndpointsChanged(updatedAtUnix: updatedAtUnix)
                    }
                }
            )
            self.meshEndpointsCache = cache
            await cache.startRefreshLoop()
            fputs("mesh endpoints cache started\n", stderr)
        }

        // paste-back blob fetcher 用 peers[0] 的决策——多 peer 部署下 image 通常在主力机产，
        // 缺字节会 404 由 lazy 路径自然降级（PR 6 之后 fallback chain 不在这里做）
        if startPasteFetcher, let d0 = decisions.first {
            let session = PonteSession.session(for: d0.chosenPullURL, fallback: AppDependencies.syncURLSession)
            let fetcher = HTTPPeerClient(baseURL: d0.chosenPullURL, auth: auth, session: session)
            self.pasteBlobFetcher = fetcher
            self.state.pasteBlobFetcher = fetcher
            fputs("paste blob fetcher → \(d0.chosenPullURL.absoluteString)\n", stderr)
        }
    }

    /// OCR worker：扫本机 own-origin image kind + ocr_state=pending 的行，调 Vision
    /// 把图里文字写 item.text_full 进 FTS5。失败 / 不识别格式 → 标 skipped / failed，
    /// 用户跑 `duo-pasted retry-failed-ocr` 重置回 pending 重扫。
    private func startOCRWorker() {
        let cfg = deps.config.ocr
        let level = VisionOCRRecognizer.level(fromConfig: cfg.recognitionLevel)
        let recognizer = VisionOCRRecognizer(
            recognitionLevel: level,
            usesLanguageCorrection: true,
            log: { msg in
                FileHandle.standardError.write(Data("ocr-vision: \(msg)\n".utf8))
            }
        )
        let workerConfig = OCRWorker.Config(
            perItemPauseMs: max(0, cfg.perItemPauseMs),
            maxBlobBytes: max(1, cfg.maxBlobMB) * 1024 * 1024,
            languages: cfg.languages
        )
        // OCR Phase 2：跟 CaptureService 共用 wsBroadcaster fan-out 路径，让 OCR 结果
        // < 1s 推到对端（不接的话对端要等 30s 周期 pull tick 才看到 ocr_state=done）
        let wsBroadcaster = deps.wsBroadcaster
        let deviceID = deps.deviceID
        let worker = OCRWorker(
            database: deps.database,
            blobs: deps.blobs,
            recognizer: recognizer,
            originDevice: deps.deviceID,
            config: workerConfig,
            onCursorAdvanced: { ns in
                Task {
                    await wsBroadcaster.broadcastCursorAdvanced(
                        deviceID: deviceID,
                        latestIngestedAtNs: ns
                    )
                }
            }
        )
        self.ocrWorker = worker
        Task { await worker.start() }
        fputs("ocr worker · level=\(cfg.recognitionLevel) · langs=\(cfg.languages.joined(separator: ","))\n", stderr)
    }

    /// 启动 Hummingbird server。loadShared secret 失败 / 端口占用 等都不致命——
    /// 让 daemon 继续起 UI / 捕获，server 单独失败只在日志里出现，用户能看到。
    private func startSyncServer() {
        let cfg = deps.config
        let secretPath = deps.paths.sharedSecretFile
        let deviceID = deps.deviceID
        do {
            let secret = try SharedSecret.load(from: secretPath)
            let auth = HMACAuth(secret: secret)
            let tls: SyncServer.TLSPaths? = {
                guard cfg.serveTLS, let cert = cfg.tlsCertPath, let key = cfg.tlsKeyPath else {
                    return nil
                }
                return SyncServer.TLSPaths(certPath: cert, keyPath: key)
            }()
            // app_icon store:bundleID → PNG bytes(SQLite + 内存 negative cache),
            // NSWorkspace resolver 注入 AppKit 拿 icon 渲染 128px PNG。
            // iOS client 通过 GET /app_icon/<bundleID> 拉
            let appIconStore = AppIconStore(
                database: deps.database,
                resolver: AppKitAppIconResolver.resolver()
            )
            // PIN 配对 service:用户在 Settings 主动点"显示配对码"才 generatePIN()。
            // secretsProvider 闭包延迟到验证成功才读 disk,避免常驻 secret 在 actor 状态里
            let pairingService = PairingService(
                secretsProvider: { try SharedSecret.load(from: secretPath) }
            )
            self.pairingService = pairingService
            let credentialAuthenticator = DeviceCredentialAuthenticator(
                database: deps.database,
                rootSecret: secret
            )
            self.credentialAuthenticator = credentialAuthenticator
            // endpointsProvider:每次 /endpoints 调用现算(EndpointDiscovery 读 cfg + SurgePonte)
            let configCopy = cfg
            let endpointsProvider: @Sendable () -> [PeerEndpoint] = {
                EndpointDiscovery.discover(config: configCopy)
            }
            // meshEndpointsProvider 通过 weak self 拿 cache(supervisor 起后才创建,SyncServer
            // 启动时此处可能还是 nil → 返 nil = mesh_peers 字段缺失,iOS 老逻辑兼容)
            let meshEndpointsProvider: @Sendable () async -> [MeshPeerEntry]? = { [weak self] in
                guard let cache = await MainActor.run(body: { self?.meshEndpointsCache }) else {
                    return nil
                }
                return await cache.snapshot()
            }
            let server = SyncServer(
                deviceID: deviceID,
                database: deps.database,
                blobs: deps.blobs,
                host: cfg.serveHost,
                port: cfg.servePort,
                auth: auth,
                credentialAuthenticator: credentialAuthenticator,
                tls: tls,
                broadcaster: deps.wsBroadcaster,
                appIconStore: appIconStore,
                endpointsProvider: endpointsProvider,
                meshEndpointsProvider: meshEndpointsProvider,
                pairingService: pairingService,
                onItemMutated: { _, _ in
                    Task { @MainActor in
                        await AppDelegate.shared?.state.refresh()
                    }
                },
                onPinOperationQueued: {
                    Task { @MainActor in
                        AppDelegate.shared?.meshSupervisor?.wakeAll()
                        await AppDelegate.shared?.state.refresh()
                    }
                }
            )
            serverTask = Task.detached(priority: .utility) {
                do {
                    try await server.run()
                } catch {
                    let msg = "sync server crashed: \(error)\n"
                    FileHandle.standardError.write(Data(msg.utf8))
                }
            }
            fputs("sync server starting on \(cfg.serveHost):\(cfg.servePort)\n", stderr)
        } catch {
            fputs("sync server NOT started: \(error)\n", stderr)
        }
    }

    private func handleCapture(_ captured: CapturedPasteboard) {
        // watcher 已在正文 extraction 前拦一次；这里再判一次，覆盖设置热重载 / 暂停恰好
        // 发生在 extraction 与回调之间的竞态，也保护未来可能绕过 watcher 的调用方。
        guard state.shouldCapture(sourceAppBundleID: captured.sourceAppBundleID) else { return }
        let pause = state.activeCapturePause()
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.deps.captureService.ingest(captured, pause: pause)
                switch result.outcome {
                case .inserted:
                    await self.state.refresh()
                    // image kind 入库后 wake OCR worker 缩短延迟（避免等 5min idle）
                    if result.item?.ocrState == .pending {
                        self.ocrWorker?.wake()
                    }
                case .mergedWithPrevious:
                    await self.state.refresh()
                case .skippedTooLarge(let kind, let bytes, let limit):
                    // 体积超限：留可见提示；pasteboard 本身仍可直接 Cmd+V。
                    let appStateKind: AppState.SkipNotice.Kind = (kind == .text) ? .text : .blob
                    self.state.recordSkip(kind: appStateKind, bytes: bytes, limit: limit)
                    fputs("capture skipped (too large): \(kind) \(bytes)B > \(limit)B\n", stderr)
                case .skippedEmpty, .skippedExcludedApp, .skippedPaused:
                    // 隐私 gate / 空 payload 不刷新 UI、不唤醒 OCR；service 也不会广播 mesh。
                    break
                }
            } catch {
                fputs("ingest error: \(error)\n", stderr)
            }
        }
    }

    private func revealInFinder(_ item: Item) {
        switch item.kind {
        case .file:
            let urls = fileURLs(from: item)
            let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existingURLs.isEmpty {
                // 本地路径存在 → Finder reveal
                NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
                panel.hide()
            } else if let sha = item.blobSha256 {
                // 路径不在本机（远端 file item）且有 blob → Preview 打开
                openBlobBackedItem(item, sha: sha)
            }

        case .image:
            guard let sha = item.blobSha256 else { return }
            openBlobBackedItem(item, sha: sha)

        default:
            break
        }
    }

    private func fileURLs(from item: Item) -> [URL] {
        guard let raw = item.textFull ?? item.preview, !raw.isEmpty else { return [] }
        return raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    private func openBlobBackedItem(_ item: Item, sha: String) {
        currentPasteTask?.cancel()
        currentPasteTask = nil
        state.pasteProgress = .idle

        // 本地已有 blob -> 直接打开
        if let url = deps.blobs.locate(sha256: sha) {
            NSWorkspace.shared.open(url)
            panel.hide()
            return
        }

        // 远端 blob 未缓存 -> 复用 lazy fetch 路径，拉完后打开
        guard let fetcher = pasteBlobFetcher else {
            state.pasteProgress = .failed(reason: "图片在本机未缓存，且未配置 primary 拉取通道")
            return
        }

        state.pasteProgress = .fetching(itemID: item.id, sizeHint: item.blobSize)
        currentPasteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.fetchBlobLazy(sha: sha, fetcher: fetcher)
            if Task.isCancelled { return }
            switch outcome {
            case .success:
                self.state.pasteProgress = .idle
                if let url = self.deps.blobs.locate(sha256: sha) {
                    NSWorkspace.shared.open(url)
                }
                self.panel.hide()
            case .failure(let reason):
                self.state.pasteProgress = .failed(reason: reason)
            }
        }
    }

    /// 右键 contextMenu "打开方式" 触发——用指定 app 打开该 item。
    ///
    /// 三种 item 路径:
    /// 1. 本机有 blob / 是 text/url/本机存在 file → 同步物化 + NSWorkspace.open
    /// 2. blob 不在本机但配了 pasteBlobFetcher → 复用 lazy fetch (5s race timeout) 拉完再 open
    /// 3. blob 不在本机也没 fetcher → pasteProgress.failed banner
    ///
    /// 跟 pasteBack 共享 currentPasteTask:多次右键不同 app 时旧 task 自动 cancel,
    /// panel hide / Esc 也通过 onDismiss → cancelLazyPasteIfAny 路径 cancel
    private func openWith(_ item: Item, app: URL) {
        currentPasteTask?.cancel()
        currentPasteTask = nil
        state.pasteProgress = .idle

        // 需要 blob 字节但本机没缓存 → 走 lazy 拉路径。
        // text/url/rtf/html: 没 blob 不需要拉。
        // file kind: 本机路径存在直接 open,blob 才是兜底
        let needsLazyBlob: Bool = {
            guard let sha = item.blobSha256 else { return false }
            if deps.blobs.exists(sha256: sha) { return false }
            // file kind 且本机路径存在 → 直接 open 不依赖 blob
            if item.kind == .file {
                let urls = fileURLs(from: item)
                if urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    return false
                }
            }
            return true
        }()

        if needsLazyBlob, let sha = item.blobSha256 {
            guard let fetcher = pasteBlobFetcher else {
                state.pasteProgress = .failed(reason: "blob 在本机未缓存,且未配置 primary 拉取通道")
                return
            }
            state.pasteProgress = .fetching(itemID: item.id, sizeHint: item.blobSize)
            currentPasteTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.fetchBlobLazy(sha: sha, fetcher: fetcher)
                if Task.isCancelled { return }
                switch outcome {
                case .success:
                    self.state.pasteProgress = .idle
                    self.performOpenWith(item, app: app)
                case .failure(let reason):
                    self.state.pasteProgress = .failed(reason: reason)
                }
            }
            return
        }

        performOpenWith(item, app: app)
    }

    /// 同步路径——blob 字节已就位 / 不需要 blob。物化 → NSWorkspace 调起目标 app。
    /// 失败走 pasteProgress.failed banner;成功 panel.hide()
    private func performOpenWith(_ item: Item, app: URL) {
        let target: OpenWithTarget
        do {
            target = try OpenWithStaging.materialize(
                item: item,
                blobs: deps.blobs,
                root: deps.paths.openWithStagingDir
            )
        } catch {
            state.pasteProgress = .failed(reason: "物化失败: \(error)")
            return
        }

        // file/webURL 都用同一个 open([URL], withApplicationAt:, configuration:) 路径:
        // - file URL 让目标 app 把它当作文件打开
        // - web URL 让浏览器 / scheme handler 打开 URL 字符串
        // 两者 NSWorkspace 都接受
        let url: URL
        switch target {
        case .fileURL(let u), .webURL(let u):
            url = u
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        // 剪贴板内容是临时,不该污染目标 app 的 Recent / 最近列表
        config.addsToRecentItems = false

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await NSWorkspace.shared.open(
                    [url], withApplicationAt: app, configuration: config
                )
                self.panel.hide()
            } catch {
                self.state.pasteProgress = .failed(reason: "打开失败: \(error.localizedDescription)")
            }
        }
    }

    /// 多项 paste 入口。分三条路径:
    /// 1. 单项 → pasteBackSingle(保留 image lazy 拉 blob 能力)
    /// 2. 多项同 kind 非 image → Copyback.writeMerged 合并写一次 NSPasteboard
    /// 3. 多项跨 kind 或多 image → 按选择顺序取首项 fallback + recentNotice banner 告知用户
    ///
    /// **为什么多项不记 PasteSuppressionSet**:它是单条 item fingerprint(text_full / blob_sha)
    /// 的去重,用于"用户 Cmd+V 粘回的内容 5 分钟内不再 capture"。多项合并后写入的字符串不
    /// 对应库里任何已有行(临时拼接),做 suppression 也匹配不上。`suppressUpToCurrent()` 仍调,
    /// 防 watcher 立刻把 self-write 那次 changeCount 当成新 capture
    private func pasteBack(_ items: [Item]) {
        guard !items.isEmpty else { return }

        // 多次按 Enter（拉一半再按 Enter）→ cancel 旧 task，避免重复 GET 同 sha 竞争 BlobStore.put
        currentPasteTask?.cancel()
        currentPasteTask = nil
        state.pasteProgress = .idle

        switch PasteMerge.strategy(for: items) {
        case .singleItem:
            pasteBackSingle(items[0])

        case .mergedImages:
            pasteBackMergedImages(items)

        case .mergedText, .mergedFile:
            // mergedText 含跨 kind:image/file 用 preview 占位; mergedFile 是全 file 多 URL。
            // 文本/路径同步可拿,不走 lazy 拉 blob——但 watcher.pasteBack 是 actor barrier
            // (async),包 Task 跨 main→actor→main 一圈。barrier 内串行 flush → main 写 → suppress。
            //
            // **必须**存 currentPasteTask: 即便当前 body 几乎不 await（极短同步），Esc 触发
            // panel.hide() 时 cancelLazyPasteIfAny 才能 cancel；未来谁加任何 await（多 image
            // flatten / 大文本压缩 等）也不会因为没存 task 而留下孤儿写入路径
            let blobs = deps.blobs
            currentPasteTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let wrote = await self.watcher.pasteBack {
                    Copyback.writeMerged(items: items, blobs: blobs)
                }
                if Task.isCancelled { return }
                if !wrote {
                    self.state.pasteProgress = .failed(reason: "选中项无可写入内容")
                    return
                }
                let target = self.panel.previousFrontmostApp
                // immediate=true 同步 orderOut,让出 key window 给 target,否则 panel
                // 140ms 淡出动画期间 CGEvent Cmd+V 会被路由到 panel 而不是目标 app
                self.panel.hide(immediate: true)
                PasteInjector.injectCmdV(into: target)
                await self.bumpUsedItems(items)
            }
        }
    }

    /// R3.3 纯文本粘贴。写入的是解码后的 `.string`，再走普通 Cmd+V 注入——不把
    /// “目标 app 是否实现 ⇧⌘V”当成协议。多选只有全为 text/rtf/html 才接受。
    ///
    /// 两层 suppression 都保留：
    /// 1. watcher.pasteBack actor barrier 在写入期间挡 tick，随后 suppress changeCount；
    /// 2. 按实际 pastedText 记录 PasteSuppressionSet，挡 Universal Clipboard 对端 echo。
    private func pasteBackPlainText(_ items: [Item]) {
        guard !items.isEmpty,
              items.allSatisfy({ PlainTextPaste.supports($0.kind) }) else { return }

        currentPasteTask?.cancel()
        currentPasteTask = nil
        state.pasteProgress = .idle

        currentPasteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let pastedText = await self.watcher.pasteBack {
                Copyback.writePlainText(items: items)
            }
            if Task.isCancelled { return }
            guard let pastedText else {
                self.state.pasteProgress = .failed(reason: "无法转换为纯文本")
                return
            }
            self.deps.pasteSuppressions.record(
                fingerprint: PasteSuppressionSet.fingerprint(text: pastedText),
                ttlSec: 300
            )
            let target = self.panel.previousFrontmostApp
            self.panel.hide(immediate: true)
            PasteInjector.injectCmdV(into: target)
            await self.bumpUsedItems(items)
        }
    }

    /// 多 image 多选 paste 路径。三种情况:
    /// 1. 全部 image 字节本机已有 → 同步走 Copyback.writeMergedImages 落 temp + writeObjects
    /// 2. 部分缺字节 + 有 fetcher → 起 task 并发拉缺的(总 10s 超时)→ 拉完(成功 / 部分)再写
    /// 3. 部分缺字节 + 无 fetcher → 失败 banner
    ///
    /// 错误策略:partial(拉到 N/M)仍写已拉的部分,banner 提示余 K 张未拉到——比"整体失败"对
    /// 用户更友好
    private func pasteBackMergedImages(_ items: [Item]) {
        let missing: [String] = items.compactMap { it -> String? in
            guard let sha = it.blobSha256 else { return nil }
            return deps.blobs.exists(sha256: sha) ? nil : sha
        }

        if missing.isEmpty {
            // 都在本机 → barrier 内同步 paste(actor 串行 flush → main 写 → suppress)。
            // 同 .mergedText 路径理由：存 currentPasteTask 让 panel.hide 能 cancel，防未来
            // 谁加 await 后这条路径变孤儿写入入口
            let blobs = deps.blobs
            currentPasteTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let (wrote, _) = await self.watcher.pasteBack {
                    Copyback.writeMergedImages(items: items, blobs: blobs)
                }
                if Task.isCancelled { return }
                if !wrote {
                    self.state.pasteProgress = .failed(reason: "选中图片无可写入内容")
                    return
                }
                let target = self.panel.previousFrontmostApp
                // immediate=true 同步 orderOut,让出 key window 给 target,否则 panel
                // 140ms 淡出动画期间 CGEvent Cmd+V 会被路由到 panel 而不是目标 app
                self.panel.hide(immediate: true)
                PasteInjector.injectCmdV(into: target)
                await self.bumpUsedItems(items)
            }
            return
        }

        guard let fetcher = pasteBlobFetcher else {
            state.pasteProgress = .failed(reason: "部分图片在本机未缓存，且未配置 primary 拉取通道")
            return
        }

        state.pasteProgress = .fetching(itemID: items[0].id, sizeHint: items[0].blobSize)
        currentPasteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchBlobsConcurrent(shas: missing, fetcher: fetcher, timeoutSec: 10)
            if Task.isCancelled { return }
            self.state.pasteProgress = .idle
            let blobs = self.deps.blobs
            let (wrote, stillMissing) = await self.watcher.pasteBack {
                Copyback.writeMergedImages(items: items, blobs: blobs)
            }
            if !wrote {
                self.state.pasteProgress = .failed(reason: "未能拉到任何图片字节")
                return
            }
            if !stillMissing.isEmpty {
                let got = items.count - stillMissing.count
                self.state.postNotice("已 paste \(got) 张图（共 \(items.count)，余 \(stillMissing.count) 张未拉到）")
            }
            let target = self.panel.previousFrontmostApp
            // immediate=true 同步 orderOut,让出 key window 给 target,否则 panel
            // 140ms 淡出动画期间 CGEvent Cmd+V 会被路由到 panel 而不是目标 app
            self.panel.hide(immediate: true)
            PasteInjector.injectCmdV(into: target)
            // 部分拉到也算"用过"——`writeMergedImages` 已经把拿到字节的几张写进了 pb,
            // 这些就是用户视觉上看到的 paste 结果,全顶比"细分谁拉到了"心智更一致
            await self.bumpUsedItems(items)
        }
    }

    private enum ConcurrentFetchOutcome { case fetchDone; case timeout }

    /// 并发拉多个 sha 的 blob 字节。每个 sha 用现有 fetchBlobLazyInner 单条重试 backoff,
    /// 整体用 TaskGroup + 一条 timeout task 控总时长。
    ///
    /// 退出条件:**所有 fetch 完成** OR **timeout 触发**(取较早者)。task 返回 outcome 让
    /// group.next 能区分——单 group.next() 只等第一个完成会过早 cancel 还在跑的 fetch。
    /// **不抛错**——失败的 sha 留给上层 writeMergedImages 检测(`blobs.exists` 仍 false)
    private func fetchBlobsConcurrent(shas: [String], fetcher: BlobFetcher, timeoutSec: TimeInterval) async {
        await withTaskGroup(of: ConcurrentFetchOutcome.self) { group in
            let total = shas.count
            for sha in shas {
                group.addTask { [weak self] in
                    if let self {
                        _ = await self.fetchBlobLazyInner(sha: sha, fetcher: fetcher)
                    }
                    return .fetchDone
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                return .timeout
            }
            var fetchDone = 0
            while let outcome = await group.next() {
                switch outcome {
                case .fetchDone:
                    fetchDone += 1
                    if fetchDone >= total {
                        group.cancelAll()  // 所有 fetch 完成 → 取消 timer 早退
                        return
                    }
                case .timeout:
                    group.cancelAll()  // timer 先 fire → 取消还在跑的 fetch
                    return
                }
            }
        }
    }

    /// 单项 paste 实现——原 pasteBack 内容搬来,签名改名。快路径(本机有可粘内容)同步;
    /// 慢路径(image kind 缺字节 / file kind 跨设备同步过来无本机路径+无本机 blob)起 task 拉 blob 5s 超时
    private func pasteBackSingle(_ item: Item) {
        // 快路径：不需要 lazy 拉字节 → 同步 Copyback.write + 关 panel。
        // 慢路径触发条件（任一）：
        //   (a) .image kind 且本机 BlobStore 没字节 —— 没字节没法粘贴
        //   (b) .file kind 且本机文件路径不存在 + 本机 BlobStore 也没字节 ——
        //       跨设备同步过来的 image 文件，无路径无字节时直接粘会落到 raw 路径字符串
        //       (Copyback fallback)，看起来"粘出的是路径"。先拉字节再走 image 字节粘贴路径
        if !needsBlobFetchForPaste(item) {
            // 快路径:无需拉字节,但 performLocalPaste 现在是 actor barrier (async),
            // 包 Task 走 main → actor → main 一圈。barrier 内仍保证 flush/suppress 串行
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performLocalPaste(item)
                let target = self.panel.previousFrontmostApp
                // immediate=true 同步 orderOut,让出 key window 给 target,否则 panel
                // 140ms 淡出动画期间 CGEvent Cmd+V 会被路由到 panel 而不是目标 app
                self.panel.hide(immediate: true)
                PasteInjector.injectCmdV(into: target)
                await self.bumpUsedItems([item])
            }
            return
        }

        // 慢路径：起异步 task 拉 blob
        guard let fetcher = pasteBlobFetcher,
              let sha = item.blobSha256
        else {
            // 没 fetcher（standalone / pull 启动失败）→ 没法补救，显示错误让用户知道
            state.pasteProgress = .failed(reason: "图片在本机未缓存，且未配置 primary 拉取通道")
            return
        }

        state.pasteProgress = .fetching(itemID: item.id, sizeHint: item.blobSize)
        currentPasteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.fetchBlobLazy(sha: sha, fetcher: fetcher)
            if Task.isCancelled { return }
            switch outcome {
            case .success:
                self.state.pasteProgress = .idle
                await self.performLocalPaste(item)
                let target = self.panel.previousFrontmostApp
                // immediate=true 同步 orderOut,让出 key window 给 target,否则 panel
                // 140ms 淡出动画期间 CGEvent Cmd+V 会被路由到 panel 而不是目标 app
                self.panel.hide(immediate: true)
                PasteInjector.injectCmdV(into: target)
                await self.bumpUsedItems([item])
            case .failure(let reason):
                self.state.pasteProgress = .failed(reason: reason)
                // 保持 panel 显示让用户看错误——Esc 关、Enter 重试都由现有 key monitor 处理
            }
        }
    }

    /// 判断 pasteBack 是否需要先拉 blob。.image kind 没本机字节必拉；.file kind 只在
    /// 本机文件路径全不在 + BlobStore 也没字节时拉（跨设备同步过来的 image file item）。
    /// 路径若在本机存在则走 Copyback `.file` 分支写 file URL，不需要 blob 字节
    private func needsBlobFetchForPaste(_ item: Item) -> Bool {
        guard let sha = item.blobSha256 else { return false }
        if deps.blobs.exists(sha256: sha) { return false }
        switch item.kind {
        case .image:
            return true
        case .file:
            return !fileItemHasUsableLocalPath(item)
        default:
            return false
        }
    }

    private func fileItemHasUsableLocalPath(_ item: Item) -> Bool {
        guard let raw = item.textFull ?? item.preview else { return false }
        let fm = FileManager.default
        return raw.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            return !path.isEmpty && fm.fileExists(atPath: path)
        }
    }

    /// SearchPanelController.onDismiss 回调——panel hide（Esc / focus 切走 / 主动 hide）
    /// 时 cancel 进行中的 lazy paste task + 重置 progress 状态。
    /// **不变量**：所有 panel 关闭路径都触发此回调，避免 task 在 panel 关闭后继续把
    /// 字节写进 NSPasteboard（孤儿写入，用户在另一 app context 莫名得到 paste），
    /// 也避免 .failed banner 残留到下次 panel 打开。
    /// 成功路径 `currentPasteTask` 完成时 panel.hide() 也走这里，但此刻 task 已 nil
    /// 出来或已自然结束——cancel 一个已完成的 task 无副作用
    private func cancelLazyPasteIfAny() {
        currentPasteTask?.cancel()
        currentPasteTask = nil
        state.pasteProgress = .idle
    }

    /// paste 成功后顶 used items:bump captured_at_ns + ingested_at_ns 让列表里浮到最前 +
    /// fan-out 给对端 peer。镜像 iOS HistoryCellView.triggerCopy → POST /bump/<id> 心智,
    /// 让 Mac/iOS 两端"用过即顶"行为对称。
    ///
    /// 为什么 Mac 端 paste 不会自然 bump:`watcher.pasteBack` 写完 pb 立刻 `suppressUpToCurrent()`
    /// 把 lastChangeCount 推齐,下次 tick changeCount 没跳变 → watcher 跳过 → CaptureService
    /// 的"同 origin 同 text dedup merge bump"分支永远不会进。这是双层防御的副作用而非有意,
    /// 这里显式补一刀走"非 capture 触发"的独立入口 `Database.bumpCapturedAt`。
    ///
    /// 不变量:
    /// - **只在 paste 真正成功后调用**(wrote==true / PasteInjector 已注入之后)——避免按
    ///   Enter 但 blob 拉不到/取消时也顶,导致列表错乱
    /// - tombstone / notFound 用 `try?` swallow——bump 失败不影响 paste 已经完成的事实,
    ///   也不该 surface 给用户(他能粘出来就完了)
    /// - 一次 paste 一次 broadcast:用 maxIngest 一次性 fan-out,减少 WS 噪声
    /// - 多选场景全部顶(用户拍板):涉及的每条都算"用过",跟单选心智一致
    private func bumpUsedItems(_ items: [Item]) async {
        guard !items.isEmpty else { return }
        let nowNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        var maxIngest: Int64 = 0
        for item in items {
            if let newIngest = try? await deps.database.bumpCapturedAt(id: item.id, now: nowNs) {
                maxIngest = Swift.max(maxIngest, newIngest)
            }
        }
        guard maxIngest > 0 else { return }
        await deps.wsBroadcaster.broadcastCursorAdvanced(
            deviceID: deps.deviceID,
            latestIngestedAtNs: maxIngest
        )
        await state.refresh()
    }

    /// 真正写 NSPasteboard 那一步——blob 字节已到位（或非 image kind）。
    /// 走 watcher.pasteBack barrier：actor 内串行 flush → main 写 → suppress
    /// 之间不会被并发轮询 tick 插入(self-write 那次 cc 跳变会被 suppress 推走)
    private func performLocalPaste(_ item: Item) async {
        let blobs = deps.blobs
        let wrote = await watcher.pasteBack {
            Copyback.write(item: item, blobs: blobs)
        }
        if wrote, let fp = PasteSuppressionSet.fingerprint(forItem: item) {
            deps.pasteSuppressions.record(fingerprint: fp, ttlSec: 300)
        }
    }

    /// lazy GET /blob 拿字节落盘。封装 transient 重试（2 次 2s/4s backoff）+ 总体超时
    /// `lazyBlobTimeoutSec`（默 30s）。不抛错——把 GetBlobError / timeout / cancellation
    /// 统一压缩成 LazyOutcome
    private enum LazyOutcome { case success; case failure(reason: String) }

    /// 用 TaskGroup 让"重试循环"跟"`lazyBlobTimeoutSec` 超时"竞争——先完成的赢，另一边
    /// 被 cancel。**不能**只靠 fetchBlobLazyInner 内的 `Date() > deadline` 早退检查——
    /// URLSession 单个 request 默认 60s timeout，如果服务端 hang 在 connection 已建立但
    /// 不返回数据的状态，inner 循环根本没机会 check Date()。group cancel 会让 URLSession
    /// 抛 URLError.cancelled 立即返回，是唯一能保证总超时内一定有结果的姿态
    ///
    /// 历史：原来 5s 总超时，Tailscale DERP 中继路径 TLS 握手本身 3s+ → 经常超时；放宽到
    /// 30s。配合 SearchPanelController.hide 同步先调 onDismiss cancel task（PR-G）让
    /// "panel 关 → 30s 后 blob 字节落到 NSPasteboard"的孤儿写入窗口缩到 0
    private func fetchBlobLazy(sha: String, fetcher: BlobFetcher) async -> LazyOutcome {
        do {
            return try await withThrowingTaskGroup(of: LazyOutcome.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return .failure(reason: "已取消") }
                    return await self.fetchBlobLazyInner(sha: sha, fetcher: fetcher)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.lazyBlobTimeoutSec * 1_000_000_000))
                    return .failure(reason: "拉取超时 (\(Int(Self.lazyBlobTimeoutSec))s)")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            return .failure(reason: "已取消")
        } catch {
            return .failure(reason: "未知错误: \(error)")
        }
    }

    /// 内部重试循环。`fetchBlobLazy` 外面已经用 TaskGroup 包了 `lazyBlobTimeoutSec` 总超时；
    /// 这里只负责 transient 错误的 2 次 backoff 重试。每次循环开头 check `Task.isCancelled`
    /// ——group cancel 时尽快退出
    private func fetchBlobLazyInner(sha: String, fetcher: BlobFetcher) async -> LazyOutcome {
        let backoffs: [TimeInterval] = [0, 2, 4]  // 第 1 次立即；第 2/3 次前 sleep
        for (attempt, delay) in backoffs.enumerated() {
            if Task.isCancelled { return .failure(reason: "已取消") }
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return .failure(reason: "已取消")
                }
            }
            do {
                let r = try await fetcher.getBlob(sha256: sha)
                switch r {
                case .found(let data):
                    do {
                        // ENOSPC 时走 LRU 驱逐重试：用户正在 paste，先腾出空间再写
                        _ = try deps.blobs.putVerifiedRetryingOnFull(
                            data, expectedSha256: sha, evictor: deps.evictOnFull
                        )
                        return .success
                    } catch {
                        return .failure(reason: "落盘失败: \(error)")
                    }
                case .notFound:
                    return .failure(reason: "primary 上无此图片字节 (sha=\(sha.prefix(8))...)")
                }
            } catch let err as GetBlobError {
                switch err {
                case .rejected(let r):
                    return .failure(reason: "鉴权拒绝: \(r)")
                case .shaMismatch(let expected, let actual):
                    return .failure(reason: "primary 返回字节 sha 不一致 (expected \(expected.prefix(8))... got \(actual.prefix(8))...)")
                case .transient(let r):
                    if attempt == backoffs.count - 1 {
                        return .failure(reason: "网络异常 (重试 \(backoffs.count) 次仍失败): \(r)")
                    }
                    continue
                }
            } catch is CancellationError {
                return .failure(reason: "已取消")
            } catch {
                return .failure(reason: "未知错误: \(error)")
            }
        }
        return .failure(reason: "拉取失败")
    }
}

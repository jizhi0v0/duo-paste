import AppKit
import SwiftUI
import DuoPasteCore
import DuoPasteCapture
import DuoPasteSync

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI Settings scene 不能直接访问 AppDelegate 实例字段。这里挂一个 weak 弱引用，
    /// 让 SettingsView 能拿到当前 AppState（含 deps.config / deps.deviceID / pasteBlobFetcher
    /// / meshStatus）。单 daemon 进程内永远只有 1 个 AppDelegate
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
    private var serverTask: Task<Void, Never>?
    private var bonjourAdvertiser: BonjourAdvertiser?
    /// daemon 启动时构造一份。Mac Settings"显示配对码"调它 generatePIN(),
    /// /pair/<pin> 路由调它 validateAndConsumePIN
    private(set) var pairingService: PairingService?
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

    /// 自管的 Settings 窗口。第一次点状态栏「设置…」时 lazy 创建；
    /// 后续点击 makeKeyAndOrderFront 复用同一个 window，关掉时 orderOut 不销毁
    /// 让 SwiftUI 状态（SettingsModel 的 working copy）保留
    private var settingsWindow: NSWindow?
    private var settingsTrafficLightOverlay: TrafficLightGlyphOverlay?

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

    /// StatusBarController 触发的「设置…」入口。accessory app 没 Dock + 无主菜单，
    /// SwiftUI Settings scene 不响应 `showSettingsWindow:` —— 自管 NSWindow 绕开整个机制
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

    /// SettingsView「立即重启 daemon」按钮调用——`exit(0)` 让 launchd KeepAlive
    /// 自动 respawn 新进程（plist 有 KeepAlive=true）。daemon 进程级重启比手动
    /// `launchctl kickstart` 直接，且新进程会重读 config 让所有非热重载字段生效
    func restartDaemon() {
        try? "1".write(to: Self.reopenSettingsFlag, atomically: true, encoding: .utf8)
        fputs("restart requested via settings — exiting for launchd respawn\n", stderr)
        exit(0)
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = settingsWindow {
            centerSettingsWindow(win)
            win.makeKeyAndOrderFront(nil)
            return
        }
        // Paste 风格窗口：内容铺进 titlebar，traffic lights 漂在 sidebar 顶部。
        // 必须在创建时就传完整 styleMask——NSWindow(contentViewController:) 先用默认
        // styleMask 完成首次布局，事后追加 .fullSizeContentView 在 macOS 26 上不重新 layout
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let host = FullBleedHostingView(rootView: SettingsView(appState: self.state))
        win.contentView = host
        win.title = ""
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.setContentSize(NSSize(width: 760, height: 620))
        // 锁固定尺寸——styleMask 没 .resizable，理论上不会有 resize 路径；min/max 都设到
        // frame.size 让契约自证（避免之前 minSize=700×560 让阅读代码的人以为支持缩到 700）。
        // CLAUDE.md §"Settings 窗口" 不变量：traffic lights placement 在 fixed size 下才稳
        win.minSize = win.frame.size
        win.maxSize = win.frame.size
        win.isReleasedWhenClosed = false   // close 走 orderOut，下次直接复用
        win.delegate = self
        centerSettingsWindow(win)
        self.settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        positionSettingsTrafficLights(in: win)
        // 某些机器 NSThemeFrame 在 makeKeyAndOrderFront 之后还要 layout 一次，
        // 会把我们的 setFrameOrigin 覆盖回默认位置。延后一拍再摆一次，赢这场 race。
        DispatchQueue.main.async { [weak self] in
            self?.positionSettingsTrafficLights(in: win)
        }
    }

    private func centerSettingsWindow(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? window.screen
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }

        let frame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func positionSettingsTrafficLights(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        // 系统 standardWindowButton 在某些 macOS 版本上 NSThemeFrame 会反复 re-layout
        // 把我们的 setFrameOrigin 覆盖回左上角默认位置（mini 上复现，MBP 上 OK）。
        // 干脆隐藏掉走真·自绘——overlay 自己画红黄绿 + 处理点击。
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }

        let topInset: CGFloat = 32   // 跟右侧 SettingsGroup title (.padding(.top, 32) + 13pt) 垂直中心对齐
        let leftInset: CGFloat = 34  // 跟 sidebar 项左边缘对齐 = sidebar padding(14) + 内 padding(8) + row padding(12)
        let diameter: CGFloat = 14
        let spacing: CGFloat = 20

        let overlay = settingsTrafficLightOverlay ?? TrafficLightGlyphOverlay()
        overlay.hostWindow = window
        overlay.buttonDiameter = diameter
        overlay.buttonSpacing = spacing
        if overlay.superview !== contentView {
            overlay.removeFromSuperview()
            contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
            settingsTrafficLightOverlay = overlay
        }
        let y = contentView.isFlipped
            ? topInset
            : contentView.bounds.height - topInset - diameter
        overlay.frame = NSRect(
            x: leftInset,
            y: y,
            width: diameter + spacing * 2 + 2,
            height: diameter + 2
        )
        overlay.needsDisplay = true
        overlay.needsDisplay = true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 早一点切 accessory，避免 Dock 闪一下
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        do {
            deps = try AppDependencies()
        } catch {
            fputs("fatal: bootstrap deps failed: \(error)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        state = AppState(deps: deps)
        panel = SearchPanelController(
            state: state,
            onPaste: { [weak self] items in self?.pasteBack(items) },
            onReveal: { [weak self] item in self?.revealInFinder(item) },
            onOpenWith: { [weak self] item, app in self?.openWith(item, app: app) },
            onDismiss: { [weak self] in self?.cancelLazyPasteIfAny() },
            // 搜索 panel 右上角齿轮——先 hide 搜索 panel(显式,不依赖 resignKey 自动 hide:
            // preview 打开时 resignKey 被守卫不会触发),再打开 Settings 窗口
            onOpenSettings: { [weak self] in
                self?.panel.hide()
                self?.showSettings()
            }
        )
        statusBar = StatusBarController(hotkey: deps.config.hotkey) { [weak self] in
            self?.panel.toggle()
        }

        watcher = PasteboardWatcher(
            maxRawRTFBytes: deps.config.capture.maxTextBytes,
            maxBlobBytes: deps.config.capture.maxBlobBytes,
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
                onChosenLikelyDown: onChosenLikelyDownCb
            )
            let supervisorPeers = decisions.map { builder.build(decision: $0) }
            // reconcile 完后 hop 回 main actor 写 AppState,SwiftUI 自动刷新 SettingsView
            // weak appState 防 supervisor 持 strong cycle(AppDelegate 也持 supervisor)
            // reconcile 完成回调:既 push 到 AppState 让 Settings 显示新 transport,也踢
            // MeshEndpointsCache 立即 refreshNow——避免新发现的 peer / ponte_host 等
            // 周期 60s 才出现在 iOS 端
            let onDecisionsUpdated: @Sendable ([SmartTransport.PeerDecision]) -> Void = { [weak self] newDecisions in
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.deps.captureService.ingest(captured)
                // 体积超限：在 AppState 留个标记 → SearchView 黄 banner 提示。
                // 这是 cap 的可见出口——光 stderr log 用户感知不到，但搜索时找不到
                // 刚复制的东西会以为"是不是 daemon 挂了"。
                if case .skippedTooLarge(let kind, let bytes, let limit) = result.outcome {
                    let appStateKind: AppState.SkipNotice.Kind = (kind == .text) ? .text : .blob
                    self.state.recordSkip(kind: appStateKind, bytes: bytes, limit: limit)
                    fputs("capture skipped (too large): \(kind) \(bytes)B > \(limit)B\n", stderr)
                }
                await self.state.refresh()
                // image kind 入库后 wake OCR worker 缩短延迟（避免等 5min idle）
                // OCRWorker 可处理范围 = image kind OR (file kind + image_mime + has_blob)
                // 同 OCRWorker.fetchPending / Admin.ocrScopeSQL 口径——CleanShot 截图走 file
                // 路径入库,标 ocr_state=pending,但旧 wake 条件 kind==.image 不命中,worker
                // 进 idleIntervalSec=300s sleep 让新截图卡 pending 等长时间。改用 ocr_state
                // 直接判断,未来 OCRWorker scope 扩展时 wake 条件自动跟随
                if case .inserted = result.outcome,
                   result.item?.ocrState == .pending {
                    self.ocrWorker?.wake()
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
            }
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

extension AppDelegate: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow else { return }
        positionSettingsTrafficLights(in: window)
    }
}

private final class FullBleedHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

private final class TrafficLightGlyphOverlay: NSView {
    weak var hostWindow: NSWindow? {
        didSet {
            for obs in keyObservers { NotificationCenter.default.removeObserver(obs) }
            keyObservers.removeAll()
            guard let win = hostWindow else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                let obs = NotificationCenter.default.addObserver(forName: name, object: win, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.needsDisplay = true }
                }
                keyObservers.append(obs)
            }
        }
    }
    var buttonDiameter: CGFloat = 14
    var buttonSpacing: CGFloat = 20
    private var isHovering = false
    private var keyObservers: [NSObjectProtocol] = []

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            for obs in keyObservers { NotificationCenter.default.removeObserver(obs) }
            keyObservers.removeAll()
        }
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let win = hostWindow else { return }
        let idx = Int(floor((p.x - 1) / buttonSpacing))
        switch idx {
        case 0: win.performClose(nil)
        case 1: win.performMiniaturize(nil)
        case 2: win.performZoom(nil)
        default: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let isActive = hostWindow?.isKeyWindow ?? hostWindow?.isMainWindow ?? false
        let fills: [NSColor] = isActive
            ? [NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1),
               NSColor(srgbRed: 0.996, green: 0.737, blue: 0.184, alpha: 1),
               NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)]
            : Array(repeating: NSColor(srgbRed: 0.32, green: 0.32, blue: 0.32, alpha: 1), count: 3)

        for i in 0..<3 {
            let c = center(forButtonAt: i)
            let rect = CGRect(
                x: c.x - buttonDiameter / 2,
                y: c.y - buttonDiameter / 2,
                width: buttonDiameter,
                height: buttonDiameter
            )
            context.setFillColor(fills[i].cgColor)
            context.fillEllipse(in: rect)
            // 极淡描边模仿系统
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
            context.setLineWidth(0.5)
            context.strokeEllipse(in: rect.insetBy(dx: 0.25, dy: 0.25))
        }

        guard isHovering else { return }
        context.setLineCap(.round)
        context.setLineWidth(1.25)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.52).cgColor)

        drawClose(in: context, center: center(forButtonAt: 0))
        drawMiniaturize(in: context, center: center(forButtonAt: 1))
        drawZoom(in: context, center: center(forButtonAt: 2))
    }

    private func center(forButtonAt index: Int) -> CGPoint {
        CGPoint(
            x: 1 + buttonDiameter / 2 + CGFloat(index) * buttonSpacing,
            y: 1 + buttonDiameter / 2
        )
    }

    private func drawClose(in context: CGContext, center: CGPoint) {
        let r: CGFloat = 3.2
        context.beginPath()
        context.move(to: CGPoint(x: center.x - r, y: center.y - r))
        context.addLine(to: CGPoint(x: center.x + r, y: center.y + r))
        context.move(to: CGPoint(x: center.x + r, y: center.y - r))
        context.addLine(to: CGPoint(x: center.x - r, y: center.y + r))
        context.strokePath()
    }

    private func drawMiniaturize(in context: CGContext, center: CGPoint) {
        let r: CGFloat = 3.8
        context.beginPath()
        context.move(to: CGPoint(x: center.x - r, y: center.y))
        context.addLine(to: CGPoint(x: center.x + r, y: center.y))
        context.strokePath()
    }

    private func drawZoom(in context: CGContext, center: CGPoint) {
        let r: CGFloat = 3.9
        context.beginPath()
        context.move(to: CGPoint(x: center.x - r, y: center.y))
        context.addLine(to: CGPoint(x: center.x + r, y: center.y))
        context.move(to: CGPoint(x: center.x, y: center.y - r))
        context.addLine(to: CGPoint(x: center.x, y: center.y + r))
        context.strokePath()
    }
}

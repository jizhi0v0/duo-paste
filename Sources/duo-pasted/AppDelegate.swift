import AppKit
import DuoPasteCore
import DuoPasteCapture
import DuoPasteSync

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var deps: AppDependencies!
    private var state: AppState!
    private var panel: SearchPanelController!
    private var statusBar: StatusBarController!
    private var watcher: PasteboardWatcher!
    private var hotkey: GlobalHotKey!
    private var snapshotScheduler: SnapshotScheduler!
    private var serverTask: Task<Void, Never>?
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 早一点切 accessory，避免 Dock 闪一下
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            onPaste: { [weak self] item in self?.pasteBack(item) },
            onReveal: { [weak self] item in self?.revealInFinder(item) },
            onDismiss: { [weak self] in self?.cancelLazyPasteIfAny() }
        )
        statusBar = StatusBarController { [weak self] in
            self?.panel.toggle()
        }

        watcher = PasteboardWatcher(
            maxRawRTFBytes: deps.config.capture.maxTextBytes,
            maxBlobBytes: deps.config.capture.maxBlobBytes,
            onCapture: { [weak self] captured in
                self?.handleCapture(captured)
            }
        )
        watcher.start()

        hotkey = GlobalHotKey()
        registerHotkeyWithFallback()

        snapshotScheduler = SnapshotScheduler(deps: deps)
        snapshotScheduler.start()

        if deps.config.serve {
            startSyncServer()
            // 启 wsBroadcaster rotation 任务（只 serve 时才有意义——broadcaster 才有 connections
            // 来 close）。auth 安全 hardening：每 4h 主动 close 所有 ws 连接强制 client 用最新
            // shared-secret 重新做 HMAC upgrade，secret 被窃取后能监听窗口压到 ≤ rotation interval
            let broadcaster = deps.wsBroadcaster
            Task { await broadcaster.start() }
        }
        if deps.config.mesh.enabled && !deps.config.peers.isEmpty {
            startMeshSupervisor()
        }
        // lazy paste-back blob fetcher 跟 PullWorker 独立——只要配了 peers + shared-secret，
        // 即使 mesh.enabled=false 也能在 paste 时按需拉单个 blob。
        // 多 peer 部署下 fetcher 当前只指 peers[0]——image 通常一台主力机产，找到的概率最高。
        // 若 peers[0] 缺字节会 404，PR 6 之后 lazy 路径不再有 fallback chain（plan 留作未来）
        setupPasteBlobFetcher()

        // OCR worker：本机 own-origin image 跑 Vision OCR 把图里文字写 text_full 进 FTS5。
        // 启动条件 = config.ocr.enabled，跟 push/pull/serve 解耦——任何 role 都跑自家
        // OCR（分布式 MVP，每台 Mac 自跑自家 origin=self，结果不跨设备同步；详 plan
        // vivid-scanning-vellum.md §1 设计原则）
        if deps.config.ocr.enabled {
            startOCRWorker()
        }

        fputs("duo-paste UI ready · device=\(deps.deviceID) · mode=\(deps.config.summary) · db=\(deps.paths.mainDB.path)\n", stderr)
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


    /// Mesh supervisor：每个 peer 起一对 (PullWorker, WSNotificationClient)，supervisor 统一
    /// 启停。PR 5 后从 `config.peers` + `config.mesh` 读，多 peer 自然 fan-out。
    ///
    /// 启用条件：`config.mesh.enabled=true` 且 `peers` 非空（applicationDidFinishLaunching guard）。
    /// 启动失败（shared-secret / 单个 peer URL 解析）非致命，daemon 仍然能用本机捕获 + 本地搜索。
    private func startMeshSupervisor() {
        let cfg = deps.config
        do {
            let secret = try SharedSecret.load(from: deps.paths.sharedSecretFile)
            let auth = HMACAuth(secret: secret)
            let intervalSec = max(1, cfg.mesh.pullIntervalSec)
            var supervisorPeers: [MeshSupervisor.Peer] = []
            for peer in cfg.peers {
                let client = HTTPPeerClient(
                    baseURL: peer.url,
                    auth: auth,
                    session: AppDependencies.syncURLSession
                )
                // 严格模式：peer.deviceID 显式给了 → 严格校验对端 /health 返回 device_id
                // 不匹配立即 transient skip。学习模式：deviceID=nil → 首次 /health 学到
                let worker = PullWorker(
                    database: deps.database,
                    transport: client,
                    selfDeviceID: deps.deviceID,
                    expectedPeerDeviceID: peer.deviceID,
                    meshStatus: deps.meshStatus,
                    pasteSuppressions: deps.pasteSuppressions,
                    blobFetcher: client,
                    blobs: deps.blobs,
                    config: PullWorker.Config(
                        intervalSec: TimeInterval(intervalSec),
                        batchLimit: cfg.mesh.pullBatchLimit,
                        initialBackoffSec: cfg.mesh.pullInitialBackoffSec,
                        maxBackoffSec: cfg.mesh.pullMaxBackoffSec,
                        crossDeviceDedupWindowNs: cfg.mesh.crossDeviceDedupWindowNs,
                        clockSkewWarnMs: cfg.mesh.clockSkewWarnMs,
                        eagerBlobs: cfg.mesh.eagerBlobs
                    )
                )
                let wsClient: WSNotificationClient?
                if cfg.mesh.wsEnabled {
                    wsClient = WSNotificationClient(
                        peerURL: peer.url,
                        auth: auth,
                        expectedPeerDeviceID: peer.deviceID,
                        onCursorAdvanced: { [weak worker] _ in worker?.wake() },
                        config: WSNotificationClient.Config(
                            heartbeatSec: cfg.mesh.wsHeartbeatSec,
                            reconnectInitialSec: cfg.mesh.wsReconnectInitialSec,
                            reconnectMaxSec: cfg.mesh.wsReconnectMaxSec
                        )
                    )
                } else {
                    wsClient = nil  // mesh.ws_enabled=false 退化为周期 pull
                }
                supervisorPeers.append(MeshSupervisor.Peer(worker: worker, wsClient: wsClient))
            }
            let supervisor = MeshSupervisor(peers: supervisorPeers)
            self.meshSupervisor = supervisor
            Task { await supervisor.start() }
            fputs("mesh supervisor → \(supervisorPeers.count) peer(s) (interval=\(intervalSec)s, ws=\(cfg.mesh.wsEnabled ? "on" : "off"))\n", stderr)
            for peer in cfg.peers {
                fputs("  · \(peer.url.absoluteString)\(peer.deviceID.map { " device_id=\($0)" } ?? " (learn mode)")\n", stderr)
            }
        } catch {
            fputs("mesh supervisor NOT started: \(error)\n", stderr)
        }
    }

    /// lazy paste-back blob fetcher 初始化——跟 PullWorker 独立。
    /// 只要 config 配了至少 1 个 peer + shared-secret 可加载就建一个 HTTPPeerClient
    /// 给 pasteBack 用，**不依赖** mesh.enabled / serve 配置。**这是 paste-back
    /// 不可降级的最低要求**：用户已经选中图片按 Enter 了，没 fetcher 等于挂掉。
    /// 多 peer 部署当前只用 peers[0]——通常 image 在某一台主力机产，命中率最高
    private func setupPasteBlobFetcher() {
        guard let firstPeer = deps.config.peers.first else { return }
        do {
            let secret = try SharedSecret.load(from: deps.paths.sharedSecretFile)
            let auth = HMACAuth(secret: secret)
            self.pasteBlobFetcher = HTTPPeerClient(
                baseURL: firstPeer.url,
                auth: auth,
                session: AppDependencies.syncURLSession
            )
            fputs("paste blob fetcher → \(firstPeer.url.absoluteString)\n", stderr)
        } catch {
            fputs("paste blob fetcher NOT initialized: \(error)\n", stderr)
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
            let server = SyncServer(
                deviceID: deviceID,
                database: deps.database,
                blobs: deps.blobs,
                host: cfg.serveHost,
                port: cfg.servePort,
                auth: auth,
                tls: tls,
                broadcaster: deps.wsBroadcaster
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
                if case .inserted = result.outcome,
                   result.item?.kind == .image {
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

    private func pasteBack(_ item: Item) {
        // 多次按 Enter（拉一半再按 Enter）→ cancel 旧 task，避免重复 GET 同 sha 竞争 BlobStore.put
        currentPasteTask?.cancel()
        currentPasteTask = nil
        state.pasteProgress = .idle

        // 快路径：不需要 lazy 拉字节 → 同步 Copyback.write + 关 panel。
        // 慢路径触发条件（任一）：
        //   (a) .image kind 且本机 BlobStore 没字节 —— 没字节没法粘贴
        //   (b) .file kind 且本机文件路径不存在 + 本机 BlobStore 也没字节 ——
        //       跨设备同步过来的 image 文件，无路径无字节时直接粘会落到 raw 路径字符串
        //       (Copyback fallback)，看起来"粘出的是路径"。先拉字节再走 image 字节粘贴路径
        if !needsBlobFetchForPaste(item) {
            performLocalPaste(item)
            panel.hide()
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
                self.performLocalPaste(item)
                self.panel.hide()
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

    /// 真正写 NSPasteboard 那一步——blob 字节已到位（或非 image kind）
    private func performLocalPaste(_ item: Item) {
        // 先 flush 任何 pending 的真实复制：若 debounce 窗口里正有一条用户的 Cmd+C 在
        // 等 500ms 稳定，我们的写回会污染 pasteboard 内容并被 suppressUpToCurrent 丢掉。
        // flush 在写回之前调，capture 读到的还是用户原始内容
        watcher.flushPendingIfAny()
        let wrote = Copyback.write(item: item, blobs: deps.blobs)
        watcher.suppressUpToCurrent()
        if wrote, let fp = PasteSuppressionSet.fingerprint(forItem: item) {
            deps.pasteSuppressions.record(fingerprint: fp, ttlSec: 300)
        }
    }

    /// lazy GET /blob 拿字节落盘。封装 transient 重试（2 次 2s/4s backoff）+ 总体超时 5s。
    /// 不抛错——把 GetBlobError / timeout / cancellation 统一压缩成 LazyOutcome
    private enum LazyOutcome { case success; case failure(reason: String) }

    /// 用 TaskGroup 让"重试循环"跟"5s 超时"竞争——先完成的赢，另一边被 cancel。
    /// **不能**只靠 fetchBlobLazyInner 内的 `Date() > deadline` 早退检查——URLSession
    /// 单个 request 默认 60s timeout，如果服务端 hang 在 connection 已建立但不返回数据
    /// 的状态，inner 循环根本没机会 check Date()。group cancel 会让 URLSession 抛
    /// URLError.cancelled 立即返回，是唯一能保证 5s 内一定有结果的姿态
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

    /// 内部重试循环。`fetchBlobLazy` 外面已经用 TaskGroup 包了 5s 总超时；这里只负责
    /// transient 错误的 2 次 backoff 重试。每次循环开头 check `Task.isCancelled`——
    /// group cancel 时尽快退出
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
                        _ = try deps.blobs.putVerified(data, expectedSha256: sha)
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

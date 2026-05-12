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
    private var pushWorker: PushWorker?
    private var pullWorker: PullWorker?
    /// lazy blob 拉取：image kind + 本机 BlobStore 缺字节时按需 GET /blob/<sha> 到本地。
    /// 跟 PullWorker / PushWorker 共享 HTTPIngestClient 配置（同一 baseURL + auth），
    /// nil → standalone 模式或 startPullWorker 失败，pasteBack 缺字节时显示错误而非干跑
    private var pasteBlobFetcher: BlobFetcher?
    /// 当前在跑的 lazy paste task。多次按 Enter 时先 cancel 旧 task 再起新的，
    /// 避免重复拉同一 sha 的字节竞争 BlobStore.put
    private var currentPasteTask: Task<Void, Never>?
    /// lazy 拉超时（5s）。Tailscale 几 MB 图片正常 < 1s；3+s 大概率网络异常。
    /// nonisolated 让 TaskGroup 的 sleeper task 能 capture（详 fetchBlobLazy）
    nonisolated static let lazyBlobTimeoutSec: TimeInterval = 5

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
            onDismiss: { [weak self] in self?.cancelLazyPasteIfAny() }
        )
        statusBar = StatusBarController { [weak self] in
            self?.panel.toggle()
        }

        watcher = PasteboardWatcher(
            maxRawRTFBytes: deps.config.capture.maxTextBytes,
            onCapture: { [weak self] captured in
                self?.handleCapture(captured)
            }
        )
        watcher.start()

        hotkey = GlobalHotKey()
        do {
            // Config.validate 已经守过合法字符集，这里 translate 失败属程序员错误
            let translated = try HotkeyTranslation.translate(deps.config.hotkey)
            try hotkey.register(
                keyCode: translated.keyCode,
                carbonModifiers: translated.modifiers
            ) { [weak self] in
                self?.panel.toggle()
            }
            fputs("hotkey registered: \(deps.config.hotkey.modifiers.joined(separator: "+"))+\(deps.config.hotkey.key)\n", stderr)
        } catch {
            fputs("hotkey register failed: \(error)\n", stderr)
            // 没有快捷键也能用菜单栏入口，不致命
        }

        snapshotScheduler = SnapshotScheduler(deps: deps)
        snapshotScheduler.start()

        if deps.config.serve {
            startSyncServer()
        }
        if deps.config.primaryURL != nil {
            startPushWorker()
        }
        if deps.config.pull.enabled {
            startPullWorker()
        }
        // lazy paste-back blob fetcher 跟 PullWorker 独立——只要配了 primary_url
        // + shared-secret，即使 pull.enabled=false（用户不想拉全量元数据）也能
        // 在 paste 时按需拉单个 blob。P1 review fix：原实现把 fetcher 绑在
        // startPullWorker 里，pull.enabled=false 时 image paste 永远失败
        setupPasteBlobFetcher()

        fputs("duo-paste UI ready · device=\(deps.deviceID) · mode=\(deps.config.summary) · db=\(deps.paths.mainDB.path)\n", stderr)
    }

    /// Push worker：把本机 origin pending → primary。
    /// Shared secret 加载失败 / config 没有 primary_url 不会到这里——AppDelegate 启动时已 guard。
    private func startPushWorker() {
        guard let primaryURL = deps.config.primaryURL else { return }
        do {
            let secret = try SharedSecret.load(from: deps.paths.sharedSecretFile)
            let auth = HMACAuth(secret: secret)
            let client = HTTPIngestClient(
                baseURL: primaryURL,
                auth: auth,
                session: AppDependencies.syncURLSession
            )
            let worker = PushWorker(
                database: deps.database,
                blobs: deps.blobs,
                transport: client,
                originDevice: deps.deviceID
            )
            self.pushWorker = worker
            Task { await worker.start() }
            fputs("push worker → \(primaryURL.absoluteString)\n", stderr)
        } catch {
            fputs("push worker NOT started: \(error)\n", stderr)
        }
    }

    /// Pull worker：周期把 primary 全量同步进本地 item_mirror。
    /// 启用条件：`config.pull.enabled=true` 且 primary_url 非空（Config.validate 已保证）。
    /// 启动失败（shared-secret / URL 解析）非致命，daemon 仍然能用本机捕获 + 本地搜索。
    private func startPullWorker() {
        guard let primaryURL = deps.config.primaryURL else { return }
        do {
            let secret = try SharedSecret.load(from: deps.paths.sharedSecretFile)
            let auth = HMACAuth(secret: secret)
            let client = HTTPIngestClient(
                baseURL: primaryURL,
                auth: auth,
                session: AppDependencies.syncURLSession
            )
            let intervalSec = max(1, deps.config.pull.intervalSec)
            let worker = PullWorker(
                database: deps.database,
                transport: client,
                selfDeviceID: deps.deviceID,
                mirrorStatus: deps.mirrorStatus,
                pasteSuppressions: deps.pasteSuppressions,
                blobFetcher: client,
                blobs: deps.blobs,
                config: PullWorker.Config(
                    intervalSec: TimeInterval(intervalSec),
                    eagerBlobs: deps.config.pull.eagerBlobs
                )
            )
            self.pullWorker = worker
            Task { await worker.start() }
            fputs("pull worker → \(primaryURL.absoluteString) @ \(intervalSec)s\n", stderr)
        } catch {
            fputs("pull worker NOT started: \(error)\n", stderr)
        }
    }

    /// lazy paste-back blob fetcher 初始化——跟 PullWorker / PushWorker 独立。
    /// 只要 config 配了 primary_url + shared-secret 可加载就建一个 HTTPIngestClient
    /// 给 pasteBack 用，**不依赖** pull.enabled / serve 配置。**这是 paste-back
    /// 不可降级的最低要求**：用户已经选中图片按 Enter 了，没 fetcher 等于挂掉
    private func setupPasteBlobFetcher() {
        guard let primaryURL = deps.config.primaryURL else { return }
        do {
            let secret = try SharedSecret.load(from: deps.paths.sharedSecretFile)
            let auth = HMACAuth(secret: secret)
            self.pasteBlobFetcher = HTTPIngestClient(
                baseURL: primaryURL,
                auth: auth,
                session: AppDependencies.syncURLSession
            )
            fputs("paste blob fetcher → \(primaryURL.absoluteString)\n", stderr)
        } catch {
            fputs("paste blob fetcher NOT initialized: \(error)\n", stderr)
        }
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
                tls: tls
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
                self.pushWorker?.wake()    // 有 worker 才唤醒；没配 primary 即 nil
            } catch {
                fputs("ingest error: \(error)\n", stderr)
            }
        }
    }

    private func pasteBack(_ item: Item) {
        // 多次按 Enter（拉一半再按 Enter）→ cancel 旧 task，避免重复 GET 同 sha 竞争 BlobStore.put
        currentPasteTask?.cancel()
        currentPasteTask = nil
        state.pasteProgress = .idle

        // 快路径：非 image 或 blob 本机已有 → 同步 Copyback.write + 关 panel
        if item.kind != .image
            || (item.blobSha256.map { deps.blobs.exists(sha256: $0) } ?? true)
        {
            performLocalPaste(item)
            panel.hide()
            return
        }

        // 慢路径：image kind + 本机 BlobStore 没字节 → 起异步 task 拉 blob
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

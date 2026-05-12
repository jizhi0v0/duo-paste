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
    /// lazy 拉超时（5s）。Tailscale 几 MB 图片正常 < 1s；3+s 大概率网络异常
    private static let lazyBlobTimeoutSec: TimeInterval = 5

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
        panel = SearchPanelController(state: state) { [weak self] item in
            self?.pasteBack(item)
        }
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
            try hotkey.register { [weak self] in
                self?.panel.toggle()
            }
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
            // lazy paste-back 复用同一个 client（同 baseURL + auth + session 共享连接池）
            self.pasteBlobFetcher = client
            Task { await worker.start() }
            fputs("pull worker → \(primaryURL.absoluteString) @ \(intervalSec)s\n", stderr)
        } catch {
            fputs("pull worker NOT started: \(error)\n", stderr)
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

    private func fetchBlobLazy(sha: String, fetcher: BlobFetcher) async -> LazyOutcome {
        let deadline = Date().addingTimeInterval(Self.lazyBlobTimeoutSec)
        let backoffs: [TimeInterval] = [0, 2, 4]  // 第 1 次立即；第 2/3 次前 sleep
        for (attempt, delay) in backoffs.enumerated() {
            if Task.isCancelled { return .failure(reason: "已取消") }
            if Date() > deadline { return .failure(reason: "拉取超时 (\(Int(Self.lazyBlobTimeoutSec))s)") }
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
                        // sha 校验失败 / 写盘失败：sha mismatch 是 server 给错字节（不可恢复），
                        // 写盘失败更罕见（磁盘满）—— 都不重试
                        return .failure(reason: "落盘失败: \(error)")
                    }
                case .notFound:
                    // primary 也没字节，不可恢复——promote 时缺 blob 场景
                    return .failure(reason: "primary 上无此图片字节 (sha=\(sha.prefix(8))...)")
                }
            } catch let err as GetBlobError {
                switch err {
                case .rejected(let r):
                    // 4xx：HMAC 失败 / config 错误，重试无意义
                    return .failure(reason: "鉴权拒绝: \(r)")
                case .shaMismatch(let expected, let actual):
                    return .failure(reason: "primary 返回字节 sha 不一致 (expected \(expected.prefix(8))... got \(actual.prefix(8))...)")
                case .transient(let r):
                    // 5xx / 网络：进入下一轮重试，除非已超 deadline
                    if attempt == backoffs.count - 1 {
                        return .failure(reason: "网络异常 (重试 \(backoffs.count) 次仍失败): \(r)")
                    }
                    continue
                }
            } catch {
                return .failure(reason: "未知错误: \(error)")
            }
        }
        return .failure(reason: "拉取失败")
    }
}

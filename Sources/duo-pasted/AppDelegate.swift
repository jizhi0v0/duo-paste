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
                config: PullWorker.Config(intervalSec: TimeInterval(intervalSec))
            )
            self.pullWorker = worker
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
                _ = try await self.deps.captureService.ingest(captured)
                await self.state.refresh()
                self.pushWorker?.wake()    // 有 worker 才唤醒；没配 primary 即 nil
            } catch {
                fputs("ingest error: \(error)\n", stderr)
            }
        }
    }

    private func pasteBack(_ item: Item) {
        Copyback.write(item: item, blobs: deps.blobs)
        // 把 watcher 内部的 lastChangeCount 推到当前，
        // 这样下次 tick 自然认为"没变化"，避免把粘回的内容当成新捕获。
        watcher.suppressUpToCurrent()
    }
}

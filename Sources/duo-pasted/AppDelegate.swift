import AppKit
import DuoPasteCore
import DuoPasteCapture

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var deps: AppDependencies!
    private var state: AppState!
    private var panel: SearchPanelController!
    private var statusBar: StatusBarController!
    private var watcher: PasteboardWatcher!
    private var hotkey: GlobalHotKey!
    private var snapshotScheduler: SnapshotScheduler!

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

        fputs("duo-paste UI ready · device=\(deps.deviceID) · db=\(deps.paths.mainDB.path)\n", stderr)
    }

    private func handleCapture(_ captured: CapturedPasteboard) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.deps.captureService.ingest(captured)
                await self.state.refresh()
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

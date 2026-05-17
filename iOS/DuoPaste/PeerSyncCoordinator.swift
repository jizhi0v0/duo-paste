import Foundation
import Observation
import DuoPasteCore

/// 把 PeerClient(HTTP /since)+ PeerWebSocket(/sync/ws cursor 推送)+ BlobCache
/// 绑在 HistoryStore 上。
///
/// 流程：
/// 1. reconfigure(cfg) 起 PeerClient + WS + 注入 BlobCache.fetcher
/// 2. WS hello / cursorAdvanced → onAdvance → kickPull()
/// 3. kickPull 增量拉 /since,**每页都 merge 到 store**(渐进刷新,大历史也能即时看到旧内容)
/// 4. 拉的过程中 WS 又来 advance → pendingAdvance=true,当前 task 完成再 kick 一轮
///    (修了上一版"inflight 时 advance 被吞掉,新内容要等下一次 capture 才出"的 bug)
@MainActor
@Observable
final class PeerSyncCoordinator {
    enum Status: Equatable {
        case idle
        case unconfigured
        case connecting
        case connected(peerDeviceID: String, lastSync: Date?)
        case backoff(failures: Int)
        case error(String)
    }

    private(set) var status: Status = .unconfigured
    private(set) var lastError: String?

    let blobCache: BlobCache
    let appIconCache: AppIconCache

    private let store: HistoryStore
    private var client: PeerClient?
    private var ws: PeerWebSocket?
    private var cursor: SinceCursor = .zero
    private var pullTask: Task<Void, Never>?
    /// inflight pullTask 期间收到 advance → 置 true,task 结束再 kick 一轮
    private var pendingAdvance: Bool = false

    init(store: HistoryStore) {
        self.store = store
        self.blobCache = BlobCache()
        self.appIconCache = AppIconCache()
    }

    func reconfigure(_ config: PeerConfig?) {
        stop()
        blobCache.resetAll()
        blobCache.fetcher = nil
        appIconCache.resetAll()
        appIconCache.fetcher = nil
        guard let config else {
            status = .unconfigured
            return
        }
        let client = PeerClient(config: config)
        self.client = client
        self.cursor = .zero
        self.status = .connecting
        // 注入 blob fetcher——长按 share image / 单击 image cell 时走这个
        blobCache.fetcher = { sha in
            try await client.fetchBlob(sha256: sha)
        }
        // 注入 app icon fetcher——HistoryCellView 拿到 sourceApp 时触发
        appIconCache.fetcher = { bid in
            try await client.fetchAppIcon(bundleID: bid)
        }
        let ws = PeerWebSocket(config: config, onAdvance: { [weak self] _ in
            self?.kickPull()
        })
        self.ws = ws
        ws.start()
        kickPull()
    }

    func stop() {
        ws?.stop()
        ws = nil
        pullTask?.cancel()
        pullTask = nil
        client = nil
        pendingAdvance = false
        status = .unconfigured
    }

    private func kickPull() {
        // 已有 inflight task → 不并发起新的,只置 pendingAdvance 让它收尾后再 kick
        if let t = pullTask, !t.isCancelled {
            pendingAdvance = true
            return
        }
        guard let client else { return }
        pendingAdvance = false
        let startCursor = cursor
        pullTask = Task { [weak self] in
            await self?.runPull(client: client, from: startCursor)
        }
    }

    private func runPull(client: PeerClient, from startCursor: SinceCursor) async {
        var cursor = startCursor
        var pages = 0
        let maxPages = 200 // 100k items 上限,正常用例远到不了
        do {
            while !Task.isCancelled, pages < maxPages {
                let page = try await client.fetchSince(cursor: cursor, limit: 500)
                pages += 1
                // 每页就 merge,UI 渐进刷新(不等全部拉完才一次性显示)
                store.merge(page.items)
                cursor = page.nextCursor
                self.cursor = cursor
                if !page.hasMore { break }
            }
            // 拉完了——更新状态 + 如果中途有 advance 进来,再 kick 一轮
            applyConnectedStatus()
        } catch is CancellationError {
            // 静默
        } catch {
            lastError = error.localizedDescription
            status = .error(error.localizedDescription)
        }
        pullTask = nil
        if pendingAdvance {
            pendingAdvance = false
            kickPull()
        }
    }

    private func applyConnectedStatus() {
        guard let ws else {
            status = .idle
            return
        }
        switch ws.state {
        case .connected(let pid):
            status = .connected(peerDeviceID: pid, lastSync: Date())
        case .connecting:
            status = .connecting
        case .backoff(let f):
            status = .backoff(failures: f)
        case .failed(let m):
            status = .error(m)
        case .idle, .stopped:
            status = .idle
        }
    }
}

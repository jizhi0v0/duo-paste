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
/// 5. statusTickTask 周期同步 ws.state → status,并检测 lastHeartbeatAt 超时(僵尸链路降级)
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

    /// 超过这个时长没收到任何 server 帧 → 即便 ws.state 还说 .connected,status 也降级到
    /// .error("链路无响应") 让 UI antenna 显橙。值要比 pingIntervalSec + pongTimeoutSec 大,
    /// 否则正常 ping/pong 周期内会误报。30s ping + 10s pong = 40s,留 ~2x buffer → 90s
    nonisolated let heartbeatStaleTimeoutSec: TimeInterval = 90
    /// status 周期 tick 间隔。5s 足够覆盖 backoff 退避变化 + zombie 检测响应延迟
    nonisolated let statusTickIntervalSec: TimeInterval = 5

    private let store: HistoryStore
    private var client: PeerClient?
    private var ws: PeerWebSocket?
    private var cursor: SinceCursor = .zero
    private var pullTask: Task<Void, Never>?
    private var statusTickTask: Task<Void, Never>?
    /// inflight pullTask 期间收到 advance → 置 true,task 结束再 kick 一轮
    private var pendingAdvance: Bool = false
    /// `applyConnectedStatus` 在 pull 成功时 stamp,heartbeat-stale 检测保护它不被覆盖
    private var lastConnectedStampAt: Date?

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
        startStatusTick()
        kickPull()
    }

    /// 跨设备"复制即顶":iOS UI 已经 store.bumpToFront 乐观顶 + UCB 写 pasteboard,
    /// 这里再 POST /bump 让 Mac DB 也顶,让其他 peer 通过 cursor_advanced 看到。
    ///
    /// **swallow 错误**——bump 失败不影响本机已 done 的复制 + 乐观顶 UX。常见失败:
    /// 网络抖 / Mac daemon 暂时不可达 / 404(本机 store 比 Mac DB 新)。日志记录足够,
    /// 用户不应看到 banner
    func bumpItemOnServer(id: String) {
        guard let client else { return }
        Task {
            do {
                try await client.bumpItem(id: id)
            } catch {
                // swallow——bump 是 best-effort 的跨设备一致信号,失败不阻塞 UI
                FileHandle.standardError.write(Data("bumpItemOnServer(\(id)) failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    func stop() {
        ws?.stop()
        ws = nil
        pullTask?.cancel()
        pullTask = nil
        statusTickTask?.cancel()
        statusTickTask = nil
        client = nil
        pendingAdvance = false
        lastConnectedStampAt = nil
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
                // 持久化 cursor → 后台 BGAppRefreshTask 从这里继续拉,不重头
                PersistedCursor(
                    ingestedAtNs: cursor.ingestedAtNs,
                    id: cursor.id,
                    updatedAtUnix: Int64(Date().timeIntervalSince1970)
                ).save()
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
            lastConnectedStampAt = Date()
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

    /// 周期 tick:同步 ws.state → status + 检测 heartbeat 僵尸(ping/pong 还没超时但
    /// 帧已经长时间没来——理论上 ping/pong 先检测,这层是兜底)
    private func startStatusTick() {
        statusTickTask?.cancel()
        let intervalNs = UInt64(statusTickIntervalSec * 1_000_000_000)
        // Task 在 @MainActor 函数体内创建,inherits MainActor isolation → tickStatus
        // 同 actor 调用不需要 await actor hop
        statusTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard let self else { return }
                self.tickStatus()
            }
        }
    }

    private func tickStatus() {
        guard let ws else { return }
        // 1) 同步 ws.state 到 status——但只在状态从 connected 变到其他时主动覆盖
        //    (避免每 5s 把 lastSync 时间戳清掉)
        switch ws.state {
        case .connecting:
            if case .connected = status {} else { status = .connecting }
        case .backoff(let f):
            status = .backoff(failures: f)
        case .failed(let m):
            status = .error(m)
        case .stopped, .idle:
            // 不动 status——stop() 已经处理
            break
        case .connected(let pid):
            // 2) zombie 检测:state 说 connected 但 lastHeartbeatAt 太老 → 降级
            let last = ws.lastHeartbeatAt ?? lastConnectedStampAt ?? .distantPast
            if Date().timeIntervalSince(last) > heartbeatStaleTimeoutSec {
                status = .error("链路无响应 (\(Int(Date().timeIntervalSince(last)))s)")
            } else if case .connected = status {
                // 已经显 connected,保留原 lastSync 不刷新(避免每 tick 假装"刚同步过")
            } else {
                // ws 重新 connected 但 status 还在 backoff/error → 走 applyConnectedStatus
                status = .connected(peerDeviceID: pid, lastSync: lastConnectedStampAt)
            }
        }
    }
}

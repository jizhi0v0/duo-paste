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
    /// 配对完成后 Mac 暴露的 endpoint 候选 list。NetworkChangeWatcher / WS endpoints_changed
    /// 触发 repickEndpoint() 时从这 re-probe 选最快。nil = 未配对(走 reconfigure 单 URL 路径)
    private var availableEndpoints: [PeerEndpoint] = []
    private var currentSecret: Data?
    /// 最近一次 endpoint pick 选中的 URL,UI 显示 + 避免 idle 重选时反复切
    private(set) var currentEndpointURL: String?
    private var repickTask: Task<Void, Never>?
    /// 每个 endpoint URL 最近一次实测 RTT。re-probe 时跟新最优比,差 < `rttStableEpsilon` →
    /// 不切防 flap。在 disconnected 期间所有候选都失败 -1 → 不更新 → 不影响 stable guard
    private(set) var lastRTT: [String: Int] = [:]
    /// 最近一次 probe 完整结果(含失败的) — 给 Settings UI 显示用
    private(set) var lastProbes: [EndpointPicker.Probe] = []
    /// RTT 抖动容忍——新最优比当前 RTT 差超过这个 ratio 才切。0.2 = 20%
    nonisolated let rttStableEpsilon: Double = 0.2
    /// 周期 safety probe task——5min 一次,即便 NWPathMonitor / WS 都没火,也防 endpoint
    /// 在没人通知的情况下变快了/慢了让 iOS 没法选最优
    private var periodicRepickTask: Task<Void, Never>?
    nonisolated let periodicRepickIntervalSec: TimeInterval = 300

    init(store: HistoryStore) {
        self.store = store
        self.blobCache = BlobCache()
        self.appIconCache = AppIconCache()
        // 网络变化 → 重新 probe + reselect
        NetworkChangeWatcher.shared.addListener { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repickEndpoint(reason: "network changed")
            }
        }
    }

    func reconfigure(_ config: PeerConfig?) {
        // **不调 stop()** ——stop() 在 nil 路径已经清,reconfigure 内部 cancelRuntimeTasks
        // 让 currentEndpointURL / availableEndpoints / currentSecret 在 URL switch 时
        // 保留(避免 applyPick 设了 currentEndpointURL 又被 stop 清掉的 race)
        cancelRuntimeTasks()
        lastProbes = []
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
        let ws = PeerWebSocket(
            config: config,
            onAdvance: { [weak self] _ in
                self?.kickPull()
            },
            onReprobeNeeded: { [weak self] reason in
                // WS 连续失败 → 已 pick 的 endpoint 不再 viable,主动重新探活选别的候选
                self?.repickEndpoint(reason: "ws: \(reason)")
            },
            onEndpointsChanged: { [weak self] in
                // Mac 推送说 mesh endpoints 更新了 → refetch /endpoints + re-probe
                self?.refetchAndRepick(reason: "ws: endpoints_changed")
            }
        )
        self.ws = ws
        ws.start()
        startStatusTick()
        kickPull()
    }

    /// PIN 配对完成 → 调这条入口让 coordinator 拿 secret + endpoint list,自动 probe
    /// 选最快连接。endpoints 缓存到 availableEndpoints,网络变 / WS endpoints_changed
    /// 时从这 re-probe
    func reconfigureFromPairing(secret: Data, endpoints: [PeerEndpoint]) {
        guard !endpoints.isEmpty else {
            status = .error("Mac 没返回任何 endpoint 候选")
            return
        }
        // 立刻把 status 切到 .connecting,避免 sheet 关掉后用户看到"未配置"——
        // probe 完成才有 currentEndpointURL,这之间 3-5s 不让 UI 显示旧状态
        self.status = .connecting
        self.currentSecret = secret
        self.availableEndpoints = endpoints
        startPeriodicRepick()
        repickEndpoint(reason: "pairing complete")
    }

    /// 触发并发 probe + 选最快 → reconfigure(挑中 URL)。
    /// secret / endpoints 没准备好(没配对过)直接 noop。
    /// **稳定性 guard**:已 pick 当前 endpoint + 新最优 RTT 跟它差 < `rttStableEpsilon` →
    /// 不切防 flap(20% 差异内属于测量噪音,不值得 reconfigure 抖一下)
    func repickEndpoint(reason: String) {
        // 用户主动 disconnect 后 status = .unconfigured。NetworkChangeWatcher 仍然
        // 会触发本函数,但**不能自动恢复连接**——尊重用户意图,等他点"重新连接"。
        // reconfigureFromPairing 会先把 status 设到 .connecting 才调本函数,正常路径
        // 此 guard 不阻塞
        if case .unconfigured = status, reason != "pairing complete" {
            FileHandle.standardError.write(Data("endpoint repick suppressed (.unconfigured): \(reason)\n".utf8))
            return
        }
        guard let secret = currentSecret, !availableEndpoints.isEmpty else { return }
        repickTask?.cancel()
        let endpoints = availableEndpoints
        FileHandle.standardError.write(Data("endpoint repick: \(reason) (\(endpoints.count) candidates)\n".utf8))
        repickTask = Task { [weak self] in
            let probes = await EndpointPicker.probeAll(endpoints: endpoints, secret: secret)
            guard !Task.isCancelled else { return }
            guard let best = probes.first(where: { $0.ok }) else {
                await MainActor.run {
                    self?.status = .error("所有 endpoint 都不通,检查 Mac 是否在线 + 网络")
                }
                return
            }
            let summary = probes.map { p in
                "\(p.endpoint.kind.rawValue)=\(p.rttMs)ms"
            }.joined(separator: " ")
            FileHandle.standardError.write(Data("endpoint pick: best=\(best.endpoint.kind.rawValue) (\(best.rttMs)ms) [\(summary)]\n".utf8))
            await MainActor.run {
                self?.recordRTTs(probes: probes)
                self?.lastProbes = probes
                self?.applyPick(endpoint: best.endpoint, rttMs: best.rttMs, secret: secret)
            }
        }
    }

    private func recordRTTs(probes: [EndpointPicker.Probe]) {
        for p in probes where p.ok {
            lastRTT[p.endpoint.url] = p.rttMs
        }
    }

    private func applyPick(endpoint: PeerEndpoint, rttMs: Int, secret: Data) {
        // 1) 同 URL + 已连接 → noop。但 status 处于 .error / .backoff 时不能 noop——
        //    此前 probe 全失败 stamp 了 .error,这次同 URL 重新可达需要重启连接刷新 status
        let wasHealthy: Bool = {
            if case .connected = status { return true }
            if case .connecting = status { return true }
            return false
        }()
        if currentEndpointURL == endpoint.url, wasHealthy {
            return
        }
        // 2) 不同 URL + 之前健康 + RTT 改善不显著 → 视为测量噪音不切。
        //    `wasHealthy` 限定:之前没连上时(.error / .backoff)需要切到新 URL 恢复,
        //    不该走稳定性 guard
        if let current = currentEndpointURL,
           current != endpoint.url,
           let currentRTT = lastRTT[current],
           currentRTT > 0,
           wasHealthy,
           Double(currentRTT - rttMs) / Double(currentRTT) < rttStableEpsilon {
            // 新最优只比当前快 < 20% → 视为噪音不切
            FileHandle.standardError.write(Data(
                "endpoint pick skipped: current=\(currentRTT)ms new=\(rttMs)ms (within \(Int(rttStableEpsilon*100))%)\n".utf8))
            return
        }
        currentEndpointURL = endpoint.url
        guard let url = URL(string: endpoint.url) else {
            status = .error("invalid endpoint URL: \(endpoint.url)")
            return
        }
        let cfg = PeerConfig(baseURL: url, sharedSecret: secret)
        // reconfigure 内部 stop + 起新连接;blob/icon cache 也 resetAll
        reconfigure(cfg)
    }

    /// 5min 周期重 probe——NWPathMonitor / WS 失败回调没火的兜底。endpoint 实际可用性
    /// 可能在没事件通知的情况下变化(对端 Mac 重启 + ponte_host 切了等),周期 probe
    /// 让 iOS 总能选最优
    private func startPeriodicRepick() {
        periodicRepickTask?.cancel()
        let intervalNs = UInt64(periodicRepickIntervalSec * 1_000_000_000)
        periodicRepickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard let self else { return }
                self.repickEndpoint(reason: "periodic")
            }
        }
    }

    /// WS endpoints_changed 收到 → refetch /endpoints 拿新列表(可能 Mac 加了
    /// peer 或学到新 ponte_host)→ re-probe
    private func refetchAndRepick(reason: String) {
        guard let client else { return }
        Task { [weak self] in
            do {
                let page = try await client.fetchEndpoints()
                let flat = Self.flattenEndpoints(page)
                await MainActor.run {
                    guard let self else { return }
                    self.availableEndpoints = flat
                    self.repickEndpoint(reason: reason)
                }
            } catch {
                FileHandle.standardError.write(Data("refetchAndRepick failed: \(error)\n".utf8))
            }
        }
    }

    /// PeerEndpointsPage 的 self + mesh_peers 扁平化成 picker 用的 [PeerEndpoint]
    /// (mesh_peers 字段在 Phase B 加,缺失时只返 self)
    nonisolated static func flattenEndpoints(_ page: PeerEndpointsPage) -> [PeerEndpoint] {
        var out = page.endpoints
        if let peers = page.meshPeers {
            for entry in peers where entry.healthy {
                out.append(contentsOf: entry.endpoints)
            }
        }
        return out
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

    /// 仅取消运行时 task / 连接,**不动 config**(currentSecret / availableEndpoints /
    /// currentEndpointURL)。`reconfigure(cfg)` 内部用,switch URL 时让 config 保留
    private func cancelRuntimeTasks() {
        ws?.stop()
        ws = nil
        pullTask?.cancel()
        pullTask = nil
        periodicRepickTask?.cancel()
        periodicRepickTask = nil
        repickTask?.cancel()
        repickTask = nil
        statusTickTask?.cancel()
        statusTickTask = nil
        client = nil
        pendingAdvance = false
        lastConnectedStampAt = nil
    }

    /// 断开连接但**保留配对信息**——"已配对未连接"状态,可走 reconnect 直接复用。
    /// `currentEndpointURL` / `availableEndpoints` / `currentSecret` 都保留,UI 可以
    /// 显示"上次连接 URL = ..."当残留。lastProbes 是临时探活结果,清掉
    func stop() {
        cancelRuntimeTasks()
        lastProbes = []
        status = .unconfigured
    }

    /// 彻底重置——unpair / 切换设备用。清掉所有 config + runtime
    func reset() {
        cancelRuntimeTasks()
        currentEndpointURL = nil
        availableEndpoints = []
        currentSecret = nil
        lastProbes = []
        lastRTT = [:]
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

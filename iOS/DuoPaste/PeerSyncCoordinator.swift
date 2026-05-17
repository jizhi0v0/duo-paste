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
    /// 多 URL 并发 WS 池。HTTP probe 通但单 URL WS TLS 挂时(iOS cellular Surge 链路坑),
    /// pool 让其他 URL 的 WS 还在工作推 cursor_advanced。see PeerWSPool 注释
    private var wsPool: PeerWSPool?
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
    /// 最近一次 repick 开始时间——给节流用。network 抖动 / WS 失败级联触发的 repick
    /// 受 minRepickIntervalSec 限制,防止 cellular 切换期 NWPathMonitor 多次火 + WS
    /// 失败回调连环触发大量并发 probe 拖垮 URLSession 池(实测有 crash)
    private var lastRepickStartedAt: Date?
    /// 节流间隔:相邻自动 repick 之间最小间隔。用户主动操作(配对 / 手动刷新)绕过
    nonisolated let minRepickIntervalSec: TimeInterval = 3
    /// 每个 endpoint URL 最近一次实测 RTT。re-probe 时跟新最优比,差 < `rttStableEpsilon` →
    /// 不切防 flap。在 disconnected 期间所有候选都失败 -1 → 不更新 → 不影响 stable guard
    private(set) var lastRTT: [String: Int] = [:]
    /// 最近一次 probe 完整结果(含失败的) — 给 Settings UI 显示用
    private(set) var lastProbes: [EndpointPicker.Probe] = []

    /// 给 Settings UI 显示 pool 里每个 URL 的 WS 状态——是 connected / connecting / backoff / cooldown
    struct PoolURLStatus: Equatable, Sendable {
        enum Phase: String, Sendable {
            case connected
            case connecting
            case backoff
            case cooldown
            case absent  // probe ok 但没在 pool 里(超出 top-K)
        }
        let url: String
        let phase: Phase
        let lastHeartbeatAt: Date?
        let cooldownUntil: Date?
    }

    /// 把 pool 状态扁平成 URL → phase map,给 UI 渲染。pool nil → 全 absent
    func poolStatus(for url: String) -> PoolURLStatus {
        guard let pool = wsPool else {
            return PoolURLStatus(url: url, phase: .absent, lastHeartbeatAt: nil, cooldownUntil: nil)
        }
        let cooldownMap = Dictionary(uniqueKeysWithValues: pool.cooldownSnapshot().map { ($0.url, $0.until) })
        if let until = cooldownMap[url] {
            return PoolURLStatus(url: url, phase: .cooldown, lastHeartbeatAt: nil, cooldownUntil: until)
        }
        let socks = pool.snapshot()
        if let s = socks.first(where: { $0.url == url }) {
            let phase: PoolURLStatus.Phase = switch s.state {
            case .connected: .connected
            case .connecting: .connecting
            case .backoff, .failed: .backoff
            case .idle, .stopped: .absent
            }
            return PoolURLStatus(url: url, phase: phase, lastHeartbeatAt: s.lastHeartbeatAt, cooldownUntil: nil)
        }
        return PoolURLStatus(url: url, phase: .absent, lastHeartbeatAt: nil, cooldownUntil: nil)
    }
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

    /// 手填 advanced URL 路径用——单 URL 当作单 probe 走 pool。配对路径走
    /// `reconfigureFromPairing` + `applyPicks`,不应进这里
    func reconfigure(_ config: PeerConfig?) {
        cancelRuntimeTasks()
        lastProbes = []
        blobCache.resetAll()
        blobCache.fetcher = nil
        appIconCache.resetAll()
        appIconCache.fetcher = nil
        guard let config else {
            status = .unconfigured
            currentSecret = nil
            availableEndpoints = []
            currentEndpointURL = nil
            return
        }
        self.currentSecret = config.sharedSecret
        let manualEP = PeerEndpoint(url: config.baseURL.absoluteString, kind: .tailscale)
        self.availableEndpoints = [manualEP]
        self.status = .connecting
        // 手填 URL 不走 probe → 直接用 0ms 占位 probe 走 pool
        let probe = EndpointPicker.Probe(endpoint: manualEP, rttMs: 0)
        setupClientAndPool(probes: [probe], secret: config.sharedSecret)
    }

    /// 公共装配路径:重 PeerClient + PeerWSPool,注入 blob/icon fetcher。
    /// 既给手填 URL 用(单 probe),也给 paired probe 路径用(top-K)
    private func setupClientAndPool(probes: [EndpointPicker.Probe], secret: Data) {
        guard let bestProbe = probes.first(where: { $0.ok }),
              let bestURL = URL(string: bestProbe.endpoint.url) else {
            status = .error("无可达 endpoint")
            return
        }
        self.currentEndpointURL = bestProbe.endpoint.url
        let cfg = PeerConfig(baseURL: bestURL, sharedSecret: secret)
        let client = PeerClient(config: cfg)
        self.client = client
        self.cursor = .zero
        if case .connected = status {} else { self.status = .connecting }
        blobCache.fetcher = { sha in try await client.fetchBlob(sha256: sha) }
        appIconCache.fetcher = { bid in try await client.fetchAppIcon(bundleID: bid) }
        let pool = PeerWSPool(
            secret: secret,
            topK: 2,
            onAdvance: { [weak self] _ in
                self?.kickPull()
            },
            onAllDown: { [weak self] reason in
                // 全 WS 都死了——升级到 repick 重新探活全 candidate list
                self?.repickEndpoint(reason: "ws-pool: \(reason)")
            },
            onEndpointsChanged: { [weak self] in
                self?.refetchAndRepick(reason: "ws: endpoints_changed")
            }
        )
        self.wsPool = pool
        pool.reconcile(probes: probes)
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
            DebugLog.shared.append("endpoint repick suppressed (.unconfigured): \(reason)")
            return
        }
        // 节流——cellular 切换 / Wi-Fi 抖动期 NWPathMonitor 多次火 + WS 失败回调级联
        // 会让 repick 短时间内被触发十几次,每次起 6 个并发 URLSession probe,把 Surge
        // 隧道 / URLSession 连接池压垮可能 crash。用户主动操作绕过节流
        let userInitiated = reason == "pairing complete"
            || reason == "manual refresh"
            || reason.hasPrefix("ws: endpoints_changed")
        if !userInitiated, let last = lastRepickStartedAt,
           Date().timeIntervalSince(last) < minRepickIntervalSec {
            DebugLog.shared.append("endpoint repick throttled: \(reason) (last=\(Int(Date().timeIntervalSince(last) * 1000))ms ago)")
            return
        }
        guard let secret = currentSecret, !availableEndpoints.isEmpty else { return }
        lastRepickStartedAt = Date()
        repickTask?.cancel()
        let endpoints = availableEndpoints
        DebugLog.shared.append("endpoint repick: \(reason) (\(endpoints.count) candidates)")
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
            DebugLog.shared.append("endpoint pick: best=\(best.endpoint.kind.rawValue) (\(best.rttMs)ms) [\(summary)]")
            await MainActor.run {
                self?.recordRTTs(probes: probes)
                self?.lastProbes = probes
                self?.applyPicks(probes: probes, secret: secret)
            }
        }
    }

    /// 记录每次 probe 的 RTT(含失败 = -1)。失败值参与 stability guard:current URL
    /// 在最新 probe 里 -1 时,guard 的 `currentRTT > 0` 自然 false → 不抑制切换
    private func recordRTTs(probes: [EndpointPicker.Probe]) {
        for p in probes {
            lastRTT[p.endpoint.url] = p.rttMs   // -1 for failed too
        }
    }

    /// 把最新 probe 结果调和给 pool——top-K reachable URL 起 / 保持 WS,其他关掉。
    /// HTTP `client` 跟到 best probe URL(只在 URL 变了或 client nil 时重建)。
    ///
    /// **关键差异 vs 旧 applyPick**: pool 自动复用已活的 WS(reconcile 内部 diff),
    /// 不会因为同 URL 触发整体重启。flap guard 还在但只挡 client URL 切换,**WS pool
    /// 始终更新**(让新增 endpoint 立刻被开 WS)
    private func applyPicks(probes: [EndpointPicker.Probe], secret: Data) {
        guard let bestProbe = probes.first(where: { $0.ok }) else {
            status = .error("所有 endpoint 都不通,检查 Mac 是否在线 + 网络")
            return
        }
        // pool 必须刷新——新 probe 可能新增 / 删除 reachable URL
        if let pool = wsPool {
            pool.reconcile(probes: probes)
        } else {
            // 没 pool → 走 setup
            setupClientAndPool(probes: probes, secret: secret)
            return
        }

        // client URL 切换 guard:同 URL noop;不同 URL + 有活连接 + RTT 改善不显著 → flap
        let bestURL = bestProbe.endpoint.url
        let hasLiveConnection: Bool = {
            if case .connected = wsPool?.state { return true } else { return false }
        }()
        if currentEndpointURL == bestURL, client != nil { return }
        if let current = currentEndpointURL,
           current != bestURL,
           let currentRTT = lastRTT[current],
           currentRTT > 0,
           hasLiveConnection,
           Double(currentRTT - bestProbe.rttMs) / Double(currentRTT) < rttStableEpsilon {
            DebugLog.shared.append("client pick skipped: current=\(currentRTT)ms new=\(bestProbe.rttMs)ms (within \(Int(rttStableEpsilon*100))%)")
            return
        }
        // 切 client URL
        guard let url = URL(string: bestURL) else {
            status = .error("invalid endpoint URL: \(bestURL)")
            return
        }
        currentEndpointURL = bestURL
        let cfg = PeerConfig(baseURL: url, sharedSecret: secret)
        let newClient = PeerClient(config: cfg)
        self.client = newClient
        blobCache.fetcher = { sha in try await newClient.fetchBlob(sha256: sha) }
        appIconCache.fetcher = { bid in try await newClient.fetchAppIcon(bundleID: bid) }
        DebugLog.shared.append("client URL switched to: \(bestURL) (\(bestProbe.endpoint.kind.rawValue) \(bestProbe.rttMs)ms)")
        kickPull()
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
                DebugLog.shared.append("refetchAndRepick failed: \(error)")
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
                DebugLog.shared.append("bumpItemOnServer(\(id)) failed: \(error.localizedDescription)")
            }
        }
    }

    /// 仅取消运行时 task / 连接,**不动 config**(currentSecret / availableEndpoints /
    /// currentEndpointURL)。`reconfigure(cfg)` 内部用,switch URL 时让 config 保留
    private func cancelRuntimeTasks() {
        wsPool?.stop()
        wsPool = nil
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
        guard let pool = wsPool else {
            status = .idle
            return
        }
        switch pool.state {
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
        guard let pool = wsPool else { return }
        // pool.state 聚合多 WS:任一 .connected → pool.connected,否则取最活跃子 state.
        // 单 WS 死 + 其他活 = pool.connected,UI 仍显示已连接(这正是 pool 价值)
        switch pool.state {
        case .connecting:
            if case .connected = status {} else { status = .connecting }
        case .backoff(let f):
            status = .backoff(failures: f)
        case .failed(let m):
            status = .error(m)
        case .stopped, .idle:
            break
        case .connected(let pid):
            // zombie 检测:pool 说 connected 但所有 sub WS 帧都太老 → 降级
            let last = pool.lastHeartbeatAt ?? lastConnectedStampAt ?? .distantPast
            if Date().timeIntervalSince(last) > heartbeatStaleTimeoutSec {
                status = .error("链路无响应 (\(Int(Date().timeIntervalSince(last)))s)")
            } else if case .connected = status {
                // 已经显 connected 保留 lastSync
            } else {
                status = .connected(peerDeviceID: pid, lastSync: lastConnectedStampAt)
            }
        }
    }
}

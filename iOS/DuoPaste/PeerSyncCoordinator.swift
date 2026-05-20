import Foundation
import Network
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
    /// AppStorage 配对数据启动校验的中文 reason——非 nil 时 SettingsView 红色横幅显示,
    /// 让用户知道为什么没自动连上(否则 try? 静默吞掉,体验"app 启动后什么都不响应")。
    /// `DuoPasteApp.task` 在 reconfigure 决策前先 setPairingDataIssue 写,
    /// "取消配对" / "重新连接" 后清掉。空字符串视同 nil
    private(set) var pairingDataIssue: String?

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
    /// 触发 repickEndpoint() 时从这 re-probe 并按 route hint 选路。nil = 未配对(走 reconfigure 单 URL 路径)
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
    /// route election 期间不要把 probe/HTTP/WS 的瞬态错误直接暴露给 Settings。
    /// 网络切换时几个 endpoint 会同时 TLS/DNS/backoff 报错,这些只是选路证据。
    private var routeElectionID: UInt64 = 0
    private var routeElectionStartedAt: Date?
    private var routeElectionTimeoutTask: Task<Void, Never>?
    private var pendingRouteError: String?
    nonisolated let routeElectionGraceSec: TimeInterval = 12

    /// 给 Settings UI 显示 pool 里每个 URL 的 WS 状态
    struct PoolURLStatus: Equatable, Sendable {
        enum Phase: String, Sendable {
            case connected
            case connecting
            case backoff
            case absent
        }
        let url: String
        let phase: Phase
    }

    /// 单 URL phase 查询——**只读两个 Observable**(pool.sockets + 指定 ws.state),
    /// 不再走 pool.snapshot() 遍历全部 6 个 sub WS。避免 SettingsView 6 行 ForEach
    /// 每渲染读 78 个 Observable 让 SwiftUI 重渲队列堆积 freeze MainActor
    func poolStatus(for url: String) -> PoolURLStatus {
        guard let pool = wsPool, let ws = pool.sockets[url] else {
            return PoolURLStatus(url: url, phase: .absent)
        }
        let phase: PoolURLStatus.Phase = switch ws.state {
        case .connected: .connected
        case .connecting: .connecting
        case .backoff, .failed: .backoff
        case .idle, .stopped: .absent
        }
        return PoolURLStatus(url: url, phase: phase)
    }
    /// RTT 抖动容忍——新最优比当前 RTT 差超过这个 ratio 才切。0.2 = 20%
    nonisolated let rttStableEpsilon: Double = 0.2
    /// 周期 safety probe task——5min 一次,即便 NWPathMonitor / WS 都没火,也防 endpoint
    /// 在没人通知的情况下变快了/慢了让 iOS 没法选最优
    private var periodicRepickTask: Task<Void, Never>?
    nonisolated let periodicRepickIntervalSec: TimeInterval = 300

    /// NetworkChangeWatcher listener token——用于在 stop / dealloc 时 removeListener,
    /// 避免 SwiftUI @State 重建 PeerSyncCoordinator 实例时旧 listener 永久留在 watcher。
    /// **@ObservationIgnored + nonisolated(unsafe)**:`deinit` 默认 nonisolated 要读这个字段,
    /// `@Observable` 宏跟纯 `nonisolated` 不兼容(无法对可变 stored property 应用);
    /// `(unsafe)` 表明开发者保证:init / deinit 是仅有的两个访问点,refcount=0 时
    /// 没有并发写入,UUID 是 Sendable
    @ObservationIgnored
    nonisolated(unsafe) private var networkListenerToken: UUID?

    init(store: HistoryStore) {
        self.store = store
        self.blobCache = BlobCache()
        self.appIconCache = AppIconCache()
        // 网络变化 → 重新 probe(给 HTTP client URL 更新最佳路径)。WS 不需要触发——
        // pool 里每个 WS 都在自己 backoff/重连,网络变了它们自然在下次 reconnect 时
        // 用新网络重试
        networkListenerToken = NetworkChangeWatcher.shared.addListener { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleNetworkChange()
            }
        }
    }

    deinit {
        // deinit 默认 nonisolated；refcount=0 时读 stored property 无 race。
        // 局部 token 是 Sendable (UUID)，capture 进 detached MainActor task 安全
        let token = networkListenerToken
        guard let token else { return }
        Task.detached { @MainActor in
            NetworkChangeWatcher.shared.removeListener(token)
        }
    }

    /// 网络切换（Wi-Fi ↔ cellular / VPN path 变化）是硬边界：旧 TCP/WS 状态不可信。
    /// 立即清掉旧 pull + 重启 WS pool，让 UI 不再展示 stale green；cellular/expensive
    /// path 下先偏向 Ponte，因为 Tailscale 与 Surge 在 iOS 上会竞争 Network Extension。
    private func handleNetworkChange() {
        DebugLog.shared.append("network changed")
        if case .unconfigured = status {
            DebugLog.shared.append("network changed ignored (.unconfigured)")
            return
        }
        beginRouteElection(reason: "network changed")
        cancelPullForHTTPRouteChange()
        preferPonteForCurrentPath()
        wsPool?.restartAll(reason: "network changed")
        repickEndpoint(reason: "network changed")
    }

    /// 手填 advanced URL 路径用——单 URL 走 pool。配对路径走 `reconfigureFromPairing`
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
        seedProbes(from: [manualEP])
        beginRouteElection(reason: "manual config")
        setupClientAndPool(endpoints: [manualEP], httpClientURL: manualEP.url, secret: config.sharedSecret)
    }

    /// 公共装配路径:重 PeerClient + PeerWSPool。pool 对所有 endpoint 全开 WS,
    /// HTTP client 用 httpClientURL(配对完成时还没 probe,先用第一个,probe 完后切换)
    private func setupClientAndPool(
        endpoints: [PeerEndpoint],
        httpClientURL: String,
        secret: Data,
        kickInitialPull: Bool = true
    ) {
        guard setHTTPClient(urlString: httpClientURL, secret: secret, reason: "setup") != nil else {
            return
        }
        self.cursor = .zero
        if case .connected = status {} else if !isElectingRoute { self.status = .connecting }
        let pool = PeerWSPool(
            secret: secret,
            onAdvance: { [weak self] _ in
                self?.promoteHTTPToPreferredWS(reason: "ws advance")
                self?.kickPull()
            },
            onEndpointsChanged: { [weak self] in
                self?.refetchAndRepick(reason: "ws: endpoints_changed")
            }
        )
        self.wsPool = pool
        pool.reconcile(endpoints: endpoints)
        startStatusTick()
        if kickInitialPull {
            kickPull()
        }
    }

    /// PIN 配对完成 → 拿 secret + endpoint list,**立刻**对所有 endpoint 开 WS pool
    /// (不等 probe,5s probe 延迟期间用户就能开始看见 WS 连上),probe 并行跑完后更新
    /// HTTP client URL
    func reconfigureFromPairing(secret: Data, endpoints: [PeerEndpoint]) {
        guard !endpoints.isEmpty else {
            status = .error("Mac 没返回任何 endpoint 候选")
            return
        }
        self.currentSecret = secret
        self.availableEndpoints = endpoints
        seedProbes(from: endpoints)
        beginRouteElection(reason: "pairing complete")
        // 先用第一个 URL 当 HTTP client(probe 完后会切到最佳路线);pool 立刻全开 WS
        setupClientAndPool(
            endpoints: endpoints,
            httpClientURL: endpoints.first?.url ?? "",
            secret: secret,
            kickInitialPull: false
        )
        startPeriodicRepick()
        // 并行触发 probe 拿 RTT 数据供 HTTP client URL 选择
        repickEndpoint(reason: "pairing complete")
    }

    /// 触发并发 probe + route hint 选路 → reconfigure(挑中 URL)。
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
            || reason == "network changed"
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
        if shouldSurfaceRouteElection(for: reason) {
            beginRouteElection(reason: reason)
        }
        DebugLog.shared.append("endpoint repick: \(reason) (\(endpoints.count) candidates)")
        repickTask = Task { [weak self] in
            let probes = await EndpointPicker.probeAll(endpoints: endpoints, secret: secret)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.recordRTTs(probes: probes)
                self?.lastProbes = probes
            }
            guard let best = probes.first(where: { $0.ok }) else {
                await MainActor.run {
                    guard let self else { return }
                    if case .connected = self.wsPool?.state {
                        self.applyConnectedStatus()
                    } else if self.promoteHTTPToPreferredWS(reason: "probe all failed") {
                        self.kickPull()
                    } else {
                        self.recordConnectionProblem("所有 endpoint 都不通,检查 Mac 是否在线 + 网络")
                    }
                }
                return
            }
            let summary = probes.map { p in
                "\(p.endpoint.kind.rawValue)=\(p.rttMs)ms"
            }.joined(separator: " ")
            DebugLog.shared.append("endpoint pick: best=\(best.endpoint.kind.rawValue) (\(best.rttMs)ms) [\(summary)]")
            await MainActor.run {
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

    /// 候选列表是配对/恢复时已经拿到的事实，不应等 probe 完才出现在 UI。
    /// RTT 初始用 -1，占位显示 "—"，后续 probe 覆盖。
    private func seedProbes(from endpoints: [PeerEndpoint]) {
        lastProbes = endpoints.map { ep in
            EndpointPicker.Probe(endpoint: ep, rttMs: lastRTT[ep.url] ?? -1)
        }
    }

    /// 探活完成 → 根据 probe + route hint 选 HTTP client URL,同时把**全部 endpoint**
    /// 喂给 pool 让 pool 决定哪些开 WS(probe 只影响 HTTP,不影响 WS pool 决策——WS 全开)
    private func applyPicks(probes: [EndpointPicker.Probe], secret: Data) {
        let endpoints = availableEndpoints
        // pool reconcile 全 endpoints(不挑 probe 结果)
        if let pool = wsPool {
            pool.reconcile(endpoints: endpoints)
        } else {
            let bestURL = probes.first(where: { $0.ok })?.endpoint.url
                ?? endpoints.first?.url
                ?? ""
            setupClientAndPool(endpoints: endpoints, httpClientURL: bestURL, secret: secret)
            return
        }

        // HTTP client URL 切换:用 route picker 结果,带 flap guard
        guard let bestProbe = probes.first(where: { $0.ok }) else {
            // probe 全失败但 pool 里可能某个 WS 已经 .connected。4G + Surge Ponte 下
            // 常见现象是 /health probe 没 RTT,但 WS 已经 hello；这时把 WS 的 URL 当
            // reachability 证据，HTTP /since 跟着它走，避免"WS 在线但数据卡住"。
            if promoteHTTPToPreferredWS(reason: "probe all failed") {
                kickPull()
            } else {
                DebugLog.shared.append("probe all failed, no connected WS; keep current client URL (\(currentEndpointURL ?? "?"))")
            }
            return
        }
        let bestURL = bestProbe.endpoint.url
        let hasLiveConnection: Bool = {
            if case .connected = wsPool?.state { return true } else { return false }
        }()
        if currentEndpointURL == bestURL, client != nil {
            // 重启恢复时 setup 阶段已经安装了第一个 HTTP client，但故意不做初始 pull，
            // 等 probe/route hint 完成后再拉。若 bestURL 刚好没变，也必须 kick 一次
            // /since，否则会出现“WS 已连接但历史为空，直到下一条 cursor_advanced 才有数据”。
            DebugLog.shared.append("client pick unchanged, kick pull: \(bestURL)")
            kickPull()
            return
        }
        if let current = currentEndpointURL,
           current != bestURL,
           let currentRTT = lastRTT[current],
           currentRTT > 0,
           hasLiveConnection,
           Double(currentRTT - bestProbe.rttMs) / Double(currentRTT) < rttStableEpsilon {
            DebugLog.shared.append("client pick skipped: current=\(currentRTT)ms new=\(bestProbe.rttMs)ms (within \(Int(rttStableEpsilon*100))%)")
            return
        }
        let oldURL = currentEndpointURL
        guard setHTTPClient(
            urlString: bestURL,
            secret: secret,
            reason: "probe \(bestProbe.endpoint.kind.rawValue) \(bestProbe.rttMs)ms"
        ) != nil else {
            return
        }
        if oldURL != bestURL {
            cancelPullForHTTPRouteChange()
        }
        kickPull()
    }

    /// 统一安装 HTTP client。返回 nil = URL 非法；true = URL/client 改变；false = 原样可用。
    @discardableResult
    private func setHTTPClient(urlString: String, secret: Data, reason: String) -> Bool? {
        guard let url = URL(string: urlString) else {
            recordConnectionProblem("invalid endpoint URL: \(urlString)")
            return nil
        }
        let changed = currentEndpointURL != urlString || client == nil
        guard changed else { return false }
        currentEndpointURL = urlString
        let cfg = PeerConfig(baseURL: url, sharedSecret: secret)
        let newClient = PeerClient(config: cfg)
        self.client = newClient
        blobCache.fetcher = { sha in try await newClient.fetchBlob(sha256: sha) }
        appIconCache.fetcher = { bid in try await newClient.fetchAppIcon(bundleID: bid) }
        DebugLog.shared.append("client URL switched to: \(urlString) (\(reason))")
        return true
    }

    /// WS 已经 hello 的 URL 是比 HTTP /health probe 更强的可达信号。尤其在 4G + Surge
    /// Ponte 下，probe 可能因为 DNS/proxy/证书路径差异失败，但 WS 证明隧道可用。
    @discardableResult
    private func promoteHTTPToPreferredWS(reason: String) -> Bool {
        guard let secret = currentSecret,
              let url = wsPool?.preferredHTTPURL(prefer: currentEndpointURL) else { return false }
        if url == currentEndpointURL {
            DebugLog.shared.append("ws preferred kept current route: \(url) (\(reason))")
            return true
        }
        let oldURL = currentEndpointURL
        guard setHTTPClient(urlString: url, secret: secret, reason: "ws preferred: \(reason)") != nil else {
            return false
        }
        if oldURL != url {
            cancelPullForHTTPRouteChange()
        }
        return true
    }

    /// 切换 HTTP route 时旧 `/since` 可能正卡在 tailscale 黑洞里。必须取消旧 pull,
    /// 否则 `kickPull()` 只会置 pendingAdvance,新 Ponte client 要等旧请求超时才会用上。
    private func cancelPullForHTTPRouteChange() {
        if let t = pullTask, !t.isCancelled {
            t.cancel()
        }
        pullTask = nil
        pendingAdvance = false
    }

    /// 当前 path 是蜂窝/expensive 时，Ponte 是更符合用户配置意图的首选。这个切换只是
    /// 抢先把 HTTP client 指向 Ponte；probe / WS hello 仍会继续修正最终选择。
    private func preferPonteForCurrentPath() {
        guard let path = NetworkChangeWatcher.shared.currentPath else { return }
        guard path.usesInterfaceType(.cellular) || path.isExpensive else { return }
        guard let secret = currentSecret,
              let ponte = availableEndpoints.first(where: { $0.kind == .ponte }) else { return }
        let oldURL = currentEndpointURL
        guard setHTTPClient(urlString: ponte.url, secret: secret, reason: "network path prefers ponte") != nil else {
            return
        }
        if oldURL != ponte.url {
            cancelPullForHTTPRouteChange()
        }
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
                    self.seedProbes(from: flat)
                    self.repickEndpoint(reason: reason)
                }
            } catch {
                DebugLog.shared.append("refetchAndRepick failed: \(error)")
            }
        }
    }

    /// PeerEndpointsPage 的 self + mesh_peers 扁平化成 picker 用的 [PeerEndpoint]
    /// (mesh_peers 字段在 Phase B 加,缺失时只返 self)。healthy=false 的 peer 也保留:
    /// Mac 端 MeshEndpointsCache 明确用 unhealthy+stale TTL 防短暂闪断让 iOS 丢 fallback。
    nonisolated static func flattenEndpoints(_ page: PeerEndpointsPage) -> [PeerEndpoint] {
        var out = page.endpoints
        if let peers = page.meshPeers {
            for entry in peers {
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
        guard let secret = currentSecret else { return }
        var urls = wsPool?.connectedHTTPURLsByDevice(prefer: currentEndpointURL) ?? []
        // **无条件** union currentEndpointURL——pool.connected 只返回 WS state==.connected
        // 的路径，currentEndpointURL 的 WS 可能正在 connecting；HTTP /since 走它意味着 Mac DB
        // 上有 baseline cursor，bump 必须打到那台。set dedup 保证字符串重复不会双发；指向
        // 同一台 Mac 的不同物理路径（罕见）即便双发也 idempotent 安全（POST /bump 是
        // UPDATE 同 ID）
        if let currentEndpointURL {
            urls.append(currentEndpointURL)
        }
        urls = Array(Set(urls)).sorted { a, b in
            if a == currentEndpointURL { return true }
            if b == currentEndpointURL { return false }
            return a < b
        }
        guard !urls.isEmpty else { return }
        DebugLog.shared.append("bump fanout \(id): \(urls.count) route(s)")
        Task {
            await withTaskGroup(of: Void.self) { group in
                for urlString in urls {
                    group.addTask {
                        guard let url = URL(string: urlString) else { return }
                        let client = PeerClient(config: PeerConfig(baseURL: url, sharedSecret: secret))
                        do {
                            try await client.bumpItem(id: id)
                            DebugLog.shared.append("bump ok \(String(id.prefix(8))) via \(urlString)")
                        } catch let error as PeerClientError {
                            switch error {
                            case .itemNotFound, .itemTombstoned:
                                DebugLog.shared.append("bump ignored \(String(id.prefix(8))) via \(urlString): \(error.localizedDescription)")
                            default:
                                DebugLog.shared.append("bump failed \(String(id.prefix(8))) via \(urlString): \(error.localizedDescription)")
                            }
                        } catch {
                            // swallow——bump 是 best-effort 的跨设备一致信号,失败不阻塞 UI
                            DebugLog.shared.append("bump failed \(String(id.prefix(8))) via \(urlString): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// 委托 Mac peer 跑 fold-aware 全文搜索。把结果灌进 store.applyServerSearch 让 UI
    /// 切到 FTS5 结果(跟 Mac UI 口径一致),跨设备 chip 总数对齐。
    ///
    /// 错误处理:失败 swallow + log——HistoryStore.filtered 自然 fallback 到本机 contains。
    /// 单 endpoint 调用即可(不需要 fanout,搜索结果由任一 connected Mac 提供,内容一致)。
    /// 选 currentEndpointURL 优先;不可用时取 pool 第一个 connected URL
    func searchOnServer(q: String) {
        guard let secret = currentSecret else { return }
        let urls: [String] = wsPool?.connectedHTTPURLsByDevice(prefer: currentEndpointURL) ?? []
        let chosen = currentEndpointURL ?? urls.first
        guard let urlString = chosen, let url = URL(string: urlString) else { return }
        Task { [weak self] in
            guard let self else { return }
            let client = PeerClient(config: PeerConfig(baseURL: url, sharedSecret: secret))
            do {
                let (items, snippets, total) = try await client.searchItems(q: q, limit: 200)
                let result = HistoryStore.ServerSearchResult(
                    q: q, items: items, snippets: snippets, totalCount: total
                )
                await MainActor.run { self.store.applyServerSearch(result) }
                DebugLog.shared.append("search ok q=\(q) hits=\(items.count) total=\(total)")
            } catch {
                DebugLog.shared.append("search failed q=\(q): \(error.localizedDescription)")
            }
        }
    }

    /// 跨设备删除:iOS 长按"删除" → store.removeOptimistic 已让 UI 立即消失,
    /// 这里再 DELETE /item/<id> 让 Mac DB 落 tombstone + 推 cursor_advanced
    /// 让其他 peer 通过 /since 看到 tombstone。
    ///
    /// **swallow 错误**——失败的话下一次 /since 拉自然把这条 re-insert 回来,
    /// 用户可重试删除。常见失败:网络抖 / 410 已 tombstoned(幂等成功) / 404(罕见)。
    /// 跟 bumpItemOnServer 同源 fanout 路径——多 endpoint 并发,best-effort
    func deleteItemOnServer(id: String) {
        guard let secret = currentSecret else { return }
        var urls = wsPool?.connectedHTTPURLsByDevice(prefer: currentEndpointURL) ?? []
        if let currentEndpointURL {
            urls.append(currentEndpointURL)
        }
        urls = Array(Set(urls)).sorted { a, b in
            if a == currentEndpointURL { return true }
            if b == currentEndpointURL { return false }
            return a < b
        }
        guard !urls.isEmpty else { return }
        DebugLog.shared.append("delete fanout \(String(id.prefix(8))): \(urls.count) route(s)")
        Task {
            await withTaskGroup(of: Void.self) { group in
                for urlString in urls {
                    group.addTask {
                        guard let url = URL(string: urlString) else { return }
                        let client = PeerClient(config: PeerConfig(baseURL: url, sharedSecret: secret))
                        do {
                            try await client.deleteItem(id: id)
                            DebugLog.shared.append("delete ok \(String(id.prefix(8))) via \(urlString)")
                        } catch let error as PeerClientError {
                            switch error {
                            case .itemNotFound, .itemTombstoned:
                                // 幂等成功:server 已是目标状态,不算失败
                                DebugLog.shared.append("delete idempotent \(String(id.prefix(8))) via \(urlString): \(error.localizedDescription)")
                            default:
                                DebugLog.shared.append("delete failed \(String(id.prefix(8))) via \(urlString): \(error.localizedDescription)")
                            }
                        } catch {
                            DebugLog.shared.append("delete failed \(String(id.prefix(8))) via \(urlString): \(error.localizedDescription)")
                        }
                    }
                }
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
        routeElectionTimeoutTask?.cancel()
        routeElectionTimeoutTask = nil
        routeElectionStartedAt = nil
        pendingRouteError = nil
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
        pairingDataIssue = nil
    }

    /// 启动时 `DuoPasteApp.task` 把 PairingDataValidator 的 reason 写进来——SettingsView
    /// 红色横幅显示。空串 / nil → 没问题(校验通过 / 全新装)
    func setPairingDataIssue(_ reason: String?) {
        pairingDataIssue = (reason?.isEmpty == true) ? nil : reason
    }

    private func kickPull() {
        // 已有 inflight task → 不并发起新的,只置 pendingAdvance 让它收尾后再 kick
        if let t = pullTask, !t.isCancelled {
            pendingAdvance = true
            DebugLog.shared.append("pull queued behind inflight")
            return
        }
        guard let client else { return }
        pendingAdvance = false
        let startCursor = cursor
        DebugLog.shared.append("pull start cursor=(\(startCursor.ingestedAtNs),\(startCursor.id)) url=\(currentEndpointURL ?? "?")")
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
                DebugLog.shared.append("pull page \(pages): items=\(page.items.count) hasMore=\(page.hasMore) next=(\(page.nextCursor.ingestedAtNs),\(page.nextCursor.id))")
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
            DebugLog.shared.append("pull done pages=\(pages) storeItems=\(store.items.count)")
            applyConnectedStatus()
        } catch is CancellationError {
            // 静默
        } catch {
            recordConnectionProblem(error.localizedDescription)
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
            finishRouteElection()
            status = .connected(peerDeviceID: pid, lastSync: Date())
            lastConnectedStampAt = Date()
        case .connecting:
            status = .connecting
        case .backoff(let f):
            if isElectingRoute { status = .connecting } else { status = .backoff(failures: f) }
        case .failed(let m):
            recordConnectionProblem(m)
        case .idle, .stopped:
            if isElectingRoute { status = .connecting } else { status = .idle }
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
            if isElectingRoute { status = .connecting } else { status = .backoff(failures: f) }
        case .failed(let m):
            recordConnectionProblem(m)
        case .stopped, .idle:
            break
        case .connected(let pid):
            // zombie 检测:pool 说 connected 但所有 sub WS 帧都太老 → 降级
            let last = pool.lastHeartbeatAt ?? lastConnectedStampAt ?? .distantPast
            if Date().timeIntervalSince(last) > heartbeatStaleTimeoutSec {
                recordConnectionProblem("链路无响应 (\(Int(Date().timeIntervalSince(last)))s)")
            } else if case .connected = status {
                // 已经显 connected 保留 lastSync
            } else {
                finishRouteElection()
                status = .connected(peerDeviceID: pid, lastSync: lastConnectedStampAt)
            }
        }
    }

    private var isElectingRoute: Bool {
        routeElectionStartedAt != nil
    }

    private func shouldSurfaceRouteElection(for reason: String) -> Bool {
        if reason == "pairing complete" { return true }
        if reason == "manual refresh" { return true }
        if reason == "network changed" { return true }
        if reason.hasPrefix("ws: endpoints_changed") { return true }
        if case .connected = status { return false }
        return true
    }

    private func beginRouteElection(reason: String) {
        routeElectionID &+= 1
        let id = routeElectionID
        routeElectionStartedAt = Date()
        pendingRouteError = nil
        status = .connecting
        routeElectionTimeoutTask?.cancel()
        let graceSec = self.routeElectionGraceSec
        routeElectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(graceSec * 1_000_000_000))
            await MainActor.run {
                self?.routeElectionTimedOut(id: id)
            }
        }
        DebugLog.shared.append("route election started: \(reason)")
    }

    private func finishRouteElection() {
        guard isElectingRoute else { return }
        routeElectionStartedAt = nil
        pendingRouteError = nil
        routeElectionTimeoutTask?.cancel()
        routeElectionTimeoutTask = nil
        DebugLog.shared.append("route election finished")
    }

    private func routeElectionTimedOut(id: UInt64) {
        guard isElectingRoute, id == routeElectionID else { return }
        if case .connected = wsPool?.state {
            applyConnectedStatus()
            return
        }
        let msg = pendingRouteError ?? "仍在选择可用路线"
        routeElectionStartedAt = nil
        routeElectionTimeoutTask = nil
        status = .error(msg)
        DebugLog.shared.append("route election timed out: \(msg)")
    }

    private func recordConnectionProblem(_ message: String) {
        lastError = message
        pendingRouteError = message
        if isElectingRoute {
            if case .connected = status {
                return
            }
            status = .connecting
            DebugLog.shared.append("transient route error suppressed: \(message)")
        } else {
            status = .error(message)
        }
    }
}

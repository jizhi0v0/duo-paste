import SwiftUI
import DuoPasteCore

struct SettingsView: View {
    @Environment(PeerSyncCoordinator.self) private var coordinator
    @Environment(ShareCoordinator.self) private var shareCoord
    @AppStorage("peerURL") private var peerURL: String = ""
    @AppStorage("sharedSecretHex") private var sharedSecretHex: String = ""
    @AppStorage("credentialPresent") private var credentialPresent: Bool = false
    @AppStorage("peerEndpointsJSON") private var peerEndpointsJSON: String = ""
    /// 配对完成时存 QR host，让"已配对的 Mac"行可读。
    @AppStorage("pairedDisplayName") private var pairedDisplayName: String = ""
    /// 配对完成时存的对端 device_id 头 8 字符,辅助显示
    @AppStorage("pairedDeviceID") private var pairedDeviceID: String = ""

    @State private var alertText: String?
    @State private var showAlert: Bool = false
    @State private var discovery = PeerDiscovery()
    @State private var qrPayload: QRPayload?
    @State private var showQRScanner: Bool = false

    /// 是否已配对(有 secret + endpoints)。配对 ≠ 连接——可以已配对+离线
    private var isPaired: Bool {
        credentialPresent && !peerEndpointsJSON.isEmpty
    }

    /// 是否真连上了
    private var isConnected: Bool {
        if case .connected = coordinator.status { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                Form {
                    // 配对数据启动校验失败 → 红色横幅在最顶,文案说清楚为什么 + 提示"取消配对"。
                    // try? 静默吞错让用户无从感知坏数据,这是 P0-3 修的体验
                    if let issue = coordinator.pairingDataIssue, !issue.isEmpty {
                        pairingIssueSection(reason: issue)
                    }
                    if isPaired {
                        statusSection
                        pairedMacSection
                        candidatesSection
                    } else {
                        pairingSection
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("设置")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .tabBar)
            .sheet(item: $qrPayload) { payload in
                PinPairingSheet(
                    displayName: payload.host,
                    host: payload.host,
                    port: payload.port,
                    tls: payload.tls,
                    certificateSHA256: payload.certificateSHA256,
                    prefilledPIN: nil,
                    isPresented: qrSheetBinding
                ) { credential, deviceID, page in
                    handlePairingSuccess(
                        credential: credential, deviceID: deviceID,
                        page: page, displayName: payload.host
                    )
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView(isPresented: $showQRScanner) { payload in
                    qrPayload = payload
                }
            }
            .alert("提示", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertText ?? "")
            }
            .onAppear { if !isPaired { discovery.start() } }
            .onDisappear { discovery.stop() }
        }
    }

    private var qrSheetBinding: Binding<Bool> {
        Binding(get: { qrPayload != nil }, set: { if !$0 { qrPayload = nil } })
    }

    // MARK: - 配对数据校验失败横幅

    @ViewBuilder
    private func pairingIssueSection(reason: String) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("配对数据无法使用")
                        .font(.subheadline).bold()
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(role: .destructive) {
                unpair()
                coordinator.setPairingDataIssue(nil)
            } label: {
                Label("取消配对并重新开始", systemImage: "xmark.circle")
            }
        } header: {
            Text("启动检测")
        }
    }

    // MARK: - 已配对场景

    @ViewBuilder
    private var statusSection: some View {
        Section("状态") {
            HStack {
                Text("连接")
                Spacer()
                Text(statusText)
                    .foregroundStyle(statusColor)
                    .monospaced()
            }
            if let urlText = coordinator.currentEndpointURL {
                HStack {
                    Text("当前 URL")
                    Spacer()
                    Text(urlText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            // 连接 / 断开 / 连接中 三态:断开只停连接,**保留**配对信息;连接中
            // 显示 disabled spinner 防多次点击触发重复 reconfigureFromPairing
            if isConnected {
                Button(role: .destructive) {
                    coordinator.stop()
                } label: {
                    Label("断开", systemImage: "stop.circle")
                }
            } else if isConnecting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("连接中…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    reconnect()
                } label: {
                    Label("重新连接", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var isConnecting: Bool {
        switch coordinator.status {
        case .connecting, .backoff: return true
        default: return false
        }
    }

    @ViewBuilder
    private var pairedMacSection: some View {
        Section {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pairedDisplayName.isEmpty ? "已配对的 Mac" : pairedDisplayName)
                    if !pairedDeviceID.isEmpty {
                        Text(pairedDeviceID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    unpair()
                } label: {
                    Label("取消配对", systemImage: "xmark.circle")
                }
            }
        } header: {
            Text("已配对")
        } footer: {
            Text("左滑取消配对。取消后本机 Keychain 凭据清空，需重新扫码 + PIN 配对。")
        }
    }

    // MARK: - 候选 endpoint(调试用)

    private func phaseIcon(_ phase: PeerSyncCoordinator.PoolURLStatus.Phase) -> String {
        switch phase {
        case .connected: return "antenna.radiowaves.left.and.right"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .backoff: return "antenna.radiowaves.left.and.right.slash"
        case .absent: return "circle"
        }
    }
    private func phaseColor(_ phase: PeerSyncCoordinator.PoolURLStatus.Phase) -> Color {
        switch phase {
        case .connected: return .green
        case .connecting: return .orange
        case .backoff: return .red
        case .absent: return .secondary
        }
    }
    private func phaseLabel(_ s: PeerSyncCoordinator.PoolURLStatus) -> String {
        switch s.phase {
        case .connected: return "WS 在线"
        case .connecting: return "WS 连接中"
        case .backoff: return "WS 重试中"
        case .absent: return "未启 WS"
        }
    }

    /// 显示 picker 探到的全部候选 + RTT,选中的标记 ★。配 "刷新候选" / "导出日志" 按钮
    /// 让用户调试链路情况
    @ViewBuilder
    private var candidatesSection: some View {
        let probes: [EndpointPicker.Probe] = coordinator.lastProbes
        Section {
            if probes.isEmpty {
                Text("没探到候选——配对后或点下方刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(probes, id: \EndpointPicker.Probe.id) { (probe: EndpointPicker.Probe) in
                    let poolStatus = coordinator.poolStatus(for: probe.endpoint.url)
                    HStack {
                        let isCurrent = probe.endpoint.url == coordinator.currentEndpointURL
                        Text(isCurrent ? "★" : "·")
                            .foregroundStyle(isCurrent ? Color.green : Color.secondary)
                            .frame(width: 16)
                        Image(systemName: phaseIcon(poolStatus.phase))
                            .foregroundStyle(phaseColor(poolStatus.phase))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(probe.endpoint.url)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 6) {
                                Text(probe.endpoint.kind.rawValue)
                                Text("·")
                                Text(phaseLabel(poolStatus))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(probe.ok ? "\(probe.rttMs)ms" : "—")
                            .font(.caption.monospaced())
                            .foregroundStyle(probe.ok ? Color.primary : Color.red)
                    }
                }
            }
            Button {
                coordinator.repickEndpoint(reason: "manual refresh")
            } label: {
                Label("刷新候选", systemImage: "arrow.clockwise")
            }
            Button {
                // 走 ShareCoordinator UIKit 直 present,不套 SwiftUI .sheet——
                // 后者首次挂载 UIActivityViewController 必现"弹窗自动关闭再点才出"
                // race,见 ShareCoordinator.swift 头注释
                shareCoord.share([DebugLog.shared.snapshot()])
            } label: {
                Label("导出日志", systemImage: "doc.text.below.ecg")
            }
        } header: {
            Text("候选 endpoint(\(probes.count))· 调试")
        } footer: {
            Text("★ = HTTP /since 当前用的 URL。WS pool 对全部 endpoint 并发开 WS,任一推 cursor_advanced 都触发拉取。每个 WS 独立 8s handshake 超时 + 指数 backoff up to 60s(URLSessionWebSocketTask TLS 挂掉会永远阻塞 receive,必须硬超时)。")
        }
    }

    // MARK: - 未配对场景

    @ViewBuilder
    private var pairingSection: some View {
        Section {
            Button {
                showQRScanner = true
            } label: {
                Label("扫码配对", systemImage: "qrcode.viewfinder")
            }

            HStack {
                Image(systemName: "wifi")
                Text("发现的 Mac")
                Spacer()
                Text(discoveryStatusText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            if case .unauthorized = discovery.state {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("开启 Local Network 权限", systemImage: "gear")
                        .foregroundStyle(.orange)
                }
            } else if discovery.peers.isEmpty {
                Text("没发现 Mac → 上面「扫码配对」用 Mac Settings 显示的 QR")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(discovery.peers) { peer in
                    Button {
                        alertText = "已发现 \(peer.displayName)。为防主动中间人截获凭据，请打开这台 Mac 的 DuoPaste Settings → iOS 配对，并扫描同屏 QR；Bonjour + PIN 不再直接签发凭据。"
                        showAlert = true
                    } label: {
                        HStack {
                            Image(systemName: peer.tls ? "lock.fill" : "lock.open")
                                .foregroundStyle(peer.tls ? .green : .orange)
                            VStack(alignment: .leading) {
                                Text(peer.displayName)
                                    .foregroundStyle(.primary)
                                if let did = peer.deviceID {
                                    Text(did.prefix(8) + "…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospaced()
                                }
                            }
                            Spacer()
                            Image(systemName: "qrcode.viewfinder")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("配对")
        } footer: {
            Text("Bonjour 仅用于确认附近 Mac；安全配对必须扫描 Mac 同屏 QR 绑定 TLS leaf，再输入 PIN。配对任一 Mac 后，mesh 地址会自动透传。")
        }
    }

    // MARK: - 文本/颜色

    private var discoveryStatusText: String {
        switch discovery.state {
        case .idle: "未扫描"
        case .browsing: "扫描中"
        case .unauthorized: "需要权限"
        case .failed(let m): "失败: \(m)"
        }
    }

    /// 状态文本——`.unconfigured / .idle` 在已配对场景下要显示"已断开"而不是
    /// "未配置"(未配置 = 没 secret,跟"配对了但停了连接"语义不同)
    private var statusText: String {
        if isPaired {
            switch coordinator.status {
            case .idle, .unconfigured: return "已断开"
            case .connecting: return "连接中"
            case .connected(let pid, _): return "已连接 (\(String(pid.prefix(8))))"
            case .backoff(let f): return "重试 #\(f)"
            case .error(let m): return "错误: \(m)"
            }
        }
        switch coordinator.status {
        case .idle: return "—"
        case .unconfigured: return "未配置"
        case .connecting: return "连接中"
        case .connected(let pid, _): return "已连接 (\(String(pid.prefix(8))))"
        case .backoff(let f): return "重试 #\(f)"
        case .error(let m): return "错误: \(m)"
        }
    }

    /// 颜色:已配对+未连接 → 红;.connecting/.backoff → 橙;.connected → 绿
    private var statusColor: Color {
        switch coordinator.status {
        case .connected: .green
        case .error: .red
        case .connecting, .backoff: .orange
        case .idle, .unconfigured: isPaired ? .red : .secondary
        }
    }

    // MARK: - 动作

    /// 配对成功 → 持久化全部 + coordinator 接管 probe + route hint 选路
    private func handlePairingSuccess(
        credential: ClientCredential, deviceID: String,
        page: PeerEndpointsPage, displayName: String
    ) {
        do {
            try ClientCredentialKeychain.save(credential)
        } catch {
            presentAlert("设备凭据写入 Keychain 失败：\(error.localizedDescription)")
            return
        }
        credentialPresent = true
        // 旧版曾把 mesh root 明文放 UserDefaults；新配对后明确清空。
        sharedSecretHex = ""
        pairedDisplayName = displayName
        pairedDeviceID = String(deviceID.prefix(36))
        let flat = PeerSyncCoordinator.flattenEndpoints(page)
        if let data = try? JSONEncoder().encode(flat),
           let json = String(data: data, encoding: .utf8) {
            peerEndpointsJSON = json
        }
        coordinator.reconfigureFromPairing(
            secret: credential.requestSecret,
            credentialToken: credential.token,
            endpoints: flat
        )
    }

    /// 重新连接——用 AppStorage 里保存的 secret + endpoints,coordinator 走 probe + Mac hint 选最佳路线
    private func reconnect() {
        guard credentialPresent, !peerEndpointsJSON.isEmpty else {
            presentAlert("配对信息丢失,请重新走 PIN 配对")
            return
        }
        guard let data = peerEndpointsJSON.data(using: .utf8),
              let endpoints = try? JSONDecoder().decode([PeerEndpoint].self, from: data),
              let credential = try? ClientCredentialKeychain.load() else {
            presentAlert("配对数据损坏,请取消配对后重新走 PIN")
            return
        }
        coordinator.reconfigureFromPairing(
            secret: credential.requestSecret,
            credentialToken: credential.token,
            endpoints: endpoints
        )
    }

    /// 取消配对——比"断开"更彻底:走 coordinator.reset() 清所有 config + runtime,
    /// 再清 AppStorage,回到未配对界面
    private func unpair() {
        coordinator.reset()
        try? ClientCredentialKeychain.delete()
        credentialPresent = false
        sharedSecretHex = ""
        peerURL = ""
        peerEndpointsJSON = ""
        pairedDisplayName = ""
        pairedDeviceID = ""
        // 重新开 Bonjour discover 让用户能立即看到 Mac 列表配新对
        discovery.start()
    }

    private func presentAlert(_ msg: String) {
        alertText = msg
        showAlert = true
    }
}

extension QRPayload: Identifiable {
    var id: String { "\(host):\(port)" }
}

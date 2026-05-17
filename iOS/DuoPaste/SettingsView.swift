import SwiftUI
import DuoPasteCore

struct SettingsView: View {
    @Environment(PeerSyncCoordinator.self) private var coordinator
    @AppStorage("peerURL") private var peerURL: String = ""
    @AppStorage("sharedSecretHex") private var sharedSecretHex: String = ""
    @AppStorage("peerEndpointsJSON") private var peerEndpointsJSON: String = ""
    /// 配对完成时存的显示名(Bonjour 路径 = peer.displayName,QR 路径 = host),
    /// 让"已配对的 Mac"行可读
    @AppStorage("pairedDisplayName") private var pairedDisplayName: String = ""
    /// 配对完成时存的对端 device_id 头 8 字符,辅助显示
    @AppStorage("pairedDeviceID") private var pairedDeviceID: String = ""

    @State private var alertText: String?
    @State private var showAlert: Bool = false
    @State private var discovery = PeerDiscovery()
    @State private var selectedPeer: PeerDiscovery.DiscoveredPeer?
    @State private var qrPayload: QRPayload?
    @State private var showQRScanner: Bool = false

    /// 是否已配对(有 secret + endpoints)。配对 ≠ 连接——可以已配对+离线
    private var isPaired: Bool {
        !sharedSecretHex.isEmpty && !peerEndpointsJSON.isEmpty
    }

    /// 是否真连上了
    private var isConnected: Bool {
        if case .connected = coordinator.status { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                if isPaired {
                    statusSection
                    pairedMacSection
                } else {
                    pairingSection
                }
            }
            // 跟 HistoryView 同款 opaque 底——防 iOS 26 Tab crossfade 期间
            // 对面 tab 内容从 Form sections 缝里透过来。
            // ignoresSafeArea 把底延到 nav bar / tab bar 下,让 Liquid Glass 永远 blur 实底
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("设置")
            .sheet(item: $selectedPeer) { peer in
                PinPairingSheet(
                    displayName: peer.displayName,
                    host: peer.host,
                    port: peer.port,
                    tls: peer.tls,
                    prefilledPIN: nil,
                    isPresented: bonjourSheetBinding
                ) { secret, deviceID, page in
                    handlePairingSuccess(
                        secret: secret, deviceID: deviceID,
                        page: page, displayName: peer.displayName
                    )
                }
            }
            .sheet(item: $qrPayload) { payload in
                PinPairingSheet(
                    displayName: payload.host,
                    host: payload.host,
                    port: payload.port,
                    tls: payload.tls,
                    prefilledPIN: nil,
                    isPresented: qrSheetBinding
                ) { secret, deviceID, page in
                    handlePairingSuccess(
                        secret: secret, deviceID: deviceID,
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

    private var bonjourSheetBinding: Binding<Bool> {
        Binding(get: { selectedPeer != nil }, set: { if !$0 { selectedPeer = nil } })
    }

    private var qrSheetBinding: Binding<Bool> {
        Binding(get: { qrPayload != nil }, set: { if !$0 { qrPayload = nil } })
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
            Text("左滑取消配对。取消后 secret 本地清空,需重新走 PIN 配对。Mac 端无需通知——HMAC 失效后请求自动 401。")
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
                        selectedPeer = peer
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
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("配对")
        } footer: {
            Text("配对任一 Mac 即可——mesh 里其他设备的地址会自动透传过来,网络变化时自动切最快连接。")
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

    /// 配对成功 → 持久化全部 + coordinator 接管 probe + 选最快
    private func handlePairingSuccess(
        secret: Data, deviceID: String,
        page: PeerEndpointsPage, displayName: String
    ) {
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        sharedSecretHex = secretHex
        pairedDisplayName = displayName
        pairedDeviceID = String(deviceID.prefix(36))
        let flat = PeerSyncCoordinator.flattenEndpoints(page)
        if let data = try? JSONEncoder().encode(flat),
           let json = String(data: data, encoding: .utf8) {
            peerEndpointsJSON = json
        }
        coordinator.reconfigureFromPairing(secret: secret, endpoints: flat)
    }

    /// 重新连接——用 AppStorage 里保存的 secret + endpoints,coordinator 走 probe 选最快
    private func reconnect() {
        guard !sharedSecretHex.isEmpty, !peerEndpointsJSON.isEmpty else {
            presentAlert("配对信息丢失,请重新走 PIN 配对")
            return
        }
        guard let data = peerEndpointsJSON.data(using: .utf8),
              let endpoints = try? JSONDecoder().decode([PeerEndpoint].self, from: data),
              let secret = Data(hexString: sharedSecretHex) else {
            presentAlert("配对数据损坏,请取消配对后重新走 PIN")
            return
        }
        coordinator.reconfigureFromPairing(secret: secret, endpoints: endpoints)
    }

    /// 取消配对——比"断开"更彻底:走 coordinator.reset() 清所有 config + runtime,
    /// 再清 AppStorage,回到未配对界面
    private func unpair() {
        coordinator.reset()
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

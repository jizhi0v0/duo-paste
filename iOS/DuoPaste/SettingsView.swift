import SwiftUI
import DuoPasteCore

struct SettingsView: View {
    @Environment(PeerSyncCoordinator.self) private var coordinator
    @AppStorage("peerURL") private var peerURL: String = ""
    @AppStorage("sharedSecretHex") private var sharedSecretHex: String = ""
    /// 配对完成后持久化的 endpoint 候选 list(JSON)。重启 app 后能从这恢复 +
    /// 网络变 / 周期 timer 时重 probe 选最快
    @AppStorage("peerEndpointsJSON") private var peerEndpointsJSON: String = ""
    @State private var alertText: String?
    @State private var showAlert: Bool = false

    @State private var discovery = PeerDiscovery()
    @State private var selectedPeer: PeerDiscovery.DiscoveredPeer?
    @State private var qrPayload: QRPayload?
    @State private var showQRScanner: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                pairingSection
            }
            .navigationTitle("设置")
            .sheet(item: $selectedPeer) { peer in
                PinPairingSheet(
                    displayName: peer.displayName,
                    host: peer.host,
                    port: peer.port,
                    tls: peer.tls,
                    prefilledPIN: nil,
                    isPresented: bonjourSheetBinding
                ) { secret, _, page in
                    handlePairingSuccess(secret: secret, page: page)
                }
            }
            .sheet(item: $qrPayload) { payload in
                PinPairingSheet(
                    displayName: payload.host,
                    host: payload.host,
                    port: payload.port,
                    tls: payload.tls,
                    prefilledPIN: nil,  // QR 不含 PIN 防泄露,用户手输
                    isPresented: qrSheetBinding
                ) { secret, _, page in
                    handlePairingSuccess(secret: secret, page: page)
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
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    private var bonjourSheetBinding: Binding<Bool> {
        Binding(get: { selectedPeer != nil }, set: { if !$0 { selectedPeer = nil } })
    }

    private var qrSheetBinding: Binding<Bool> {
        Binding(get: { qrPayload != nil }, set: { if !$0 { qrPayload = nil } })
    }

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
            if !sharedSecretHex.isEmpty {
                Button(role: .destructive) {
                    disconnectAndForget()
                } label: {
                    Label("断开", systemImage: "stop.circle")
                }
            }
        }
    }

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

    private var discoveryStatusText: String {
        switch discovery.state {
        case .idle: "未扫描"
        case .browsing: "扫描中"
        case .unauthorized: "需要权限"
        case .failed(let m): "失败: \(m)"
        }
    }

    private var statusText: String {
        switch coordinator.status {
        case .idle: "—"
        case .unconfigured: "未配置"
        case .connecting: "连接中"
        case .connected(let pid, _): "已连接 (\(String(pid.prefix(8))))"
        case .backoff(let f): "重试 #\(f)"
        case .error(let m): "错误: \(m)"
        }
    }

    private var statusColor: Color {
        switch coordinator.status {
        case .connected: .green
        case .error: .red
        case .connecting, .backoff: .orange
        default: .secondary
        }
    }

    /// 配对成功 → 持久化 secret + endpoints + coordinator 接管 probe + 选最快
    private func handlePairingSuccess(secret: Data, page: PeerEndpointsPage) {
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        sharedSecretHex = secretHex
        let flat = PeerSyncCoordinator.flattenEndpoints(page)
        // 持久化让重启后能从这恢复
        if let data = try? JSONEncoder().encode(flat),
           let json = String(data: data, encoding: .utf8) {
            peerEndpointsJSON = json
        }
        coordinator.reconfigureFromPairing(secret: secret, endpoints: flat)
    }

    private func disconnectAndForget() {
        coordinator.stop()
        sharedSecretHex = ""
        peerURL = ""
        peerEndpointsJSON = ""
    }
}

extension QRPayload: Identifiable {
    var id: String { "\(host):\(port)" }
}

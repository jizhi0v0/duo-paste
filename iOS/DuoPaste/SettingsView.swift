import SwiftUI
import DuoPasteCore

struct SettingsView: View {
    @Environment(PeerSyncCoordinator.self) private var coordinator
    /// 手填 fallback——Bonjour / PIN 配对失败 / 高级用户直接知道 URL+secret 时用。
    /// 配对成功后这两个 AppStorage 字段会被写新值,UI 显示同步
    @AppStorage("peerURL") private var peerURL: String = ""
    @AppStorage("sharedSecretHex") private var sharedSecretHex: String = ""
    /// 配对完成后持久化的 endpoint 候选 list(JSON)。重启 app 后能从这恢复 +
    /// 网络变 / 周期 timer 时重 probe 选最快
    @AppStorage("peerEndpointsJSON") private var peerEndpointsJSON: String = ""
    @State private var lastParseError: String?
    @State private var showAdvanced: Bool = false

    @State private var discovery = PeerDiscovery()
    @State private var selectedPeer: PeerDiscovery.DiscoveredPeer?
    @State private var pairingError: String?

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                discoverySection
                advancedSection
            }
            .navigationTitle("设置")
            .sheet(item: $selectedPeer) { peer in
                PinPairingSheet(peer: peer, isPresented: pairingSheetBinding) { secret, _, endpoints in
                    handlePairingSuccess(secret: secret, endpoints: endpoints)
                }
            }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    private var pairingSheetBinding: Binding<Bool> {
        Binding(
            get: { selectedPeer != nil },
            set: { if !$0 { selectedPeer = nil } }
        )
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
            if let urlText = coordinator.currentEndpointURL ?? peerURLDisplay {
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
                    coordinator.stop()
                } label: {
                    Label("断开", systemImage: "stop.circle")
                }
                .disabled(disconnectDisabled)
            }
            if let lastParseError {
                Text(lastParseError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var discoverySection: some View {
        Section {
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
                Text("正在扫描同网段 Mac… 确保 Mac daemon serve=true + 同 Wi-Fi")
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
                                    Text(did)
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
            if let pairingError {
                Text(pairingError)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } header: {
            Text("Bonjour 配对")
        } footer: {
            Text("tap 一台 Mac → 输入它显示的 6 位 PIN → 自动获取 secret + 测延迟选最快连接")
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                TextField("https://host:8443", text: $peerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("64 字符 hex secret", text: $sharedSecretHex)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    applyManualConfig()
                } label: {
                    Label("应用 + 连接", systemImage: "antenna.radiowaves.left.and.right")
                }
            } label: {
                Label("高级:手填 URL + secret", systemImage: "gearshape.2")
            }
        } footer: {
            Text("PIN 配对 / Bonjour 都失败时走这里。secret 是 Mac ~/Library/Application Support/duo-paste/shared-secret 文件 64 字符 hex")
        }
    }

    private var peerURLDisplay: String? {
        peerURL.isEmpty ? nil : peerURL
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

    private var disconnectDisabled: Bool {
        switch coordinator.status {
        case .unconfigured, .idle: true
        default: false
        }
    }

    /// PIN 配对成功 → 持久化 secret + endpoints + 让 coordinator probe 选最快
    private func handlePairingSuccess(secret: Data, endpoints: [PeerEndpoint]) {
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        sharedSecretHex = secretHex
        // 把"被选中的 URL"也回填到 peerURL,让 advanced section 显示一致
        // (coordinator.applyPick 也会写 currentEndpointURL,UI 二者择一显示)
        if let first = endpoints.first(where: { $0.preferred }) ?? endpoints.first {
            peerURL = first.url
        }
        // 把 endpoint list 持久化让重启后能从这恢复
        if let data = try? JSONEncoder().encode(endpoints),
           let json = String(data: data, encoding: .utf8) {
            peerEndpointsJSON = json
        }
        pairingError = nil
        coordinator.reconfigureFromPairing(secret: secret, endpoints: endpoints)
    }

    /// 高级面板手填路径——还是支持单 URL + secret 直接连
    private func applyManualConfig() {
        do {
            let cfg = try PeerConfig.parse(urlString: peerURL, secretHex: sharedSecretHex)
            lastParseError = nil
            coordinator.reconfigure(cfg)
        } catch {
            lastParseError = error.localizedDescription
        }
    }
}

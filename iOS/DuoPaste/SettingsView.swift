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
    @State private var alertText: String?
    @State private var showAlert: Bool = false
    @State private var showAdvanced: Bool = false

    @State private var discovery = PeerDiscovery()
    @State private var selectedPeer: PeerDiscovery.DiscoveredPeer?

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                candidatesSection
                discoverySection
                advancedSection
            }
            .navigationTitle("设置")
            .sheet(item: $selectedPeer) { peer in
                PinPairingSheet(peer: peer, isPresented: pairingSheetBinding) { secret, _, page in
                    handlePairingSuccess(secret: secret, page: page)
                }
            }
            // 用 alert 避免 Form inline 错误被键盘遮挡。统一所有 Settings 错误源
            .alert("提示", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertText ?? "")
            }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    private func presentAlert(_ msg: String) {
        alertText = msg
        showAlert = true
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
        }
    }

    /// 显示 EndpointPicker 探到的全部候选 + RTT,选中的标记 ★。
    /// 不只是 Bonjour 发现的 Mac——还包括 mesh peer Mac 通过 /endpoints 透传过来的
    /// (iOS 配对 mini 后 mini 把 MBP 的 endpoints 也传过来,即便 Bonjour 跨 LAN 拿不到)
    @ViewBuilder
    private var candidatesSection: some View {
        let probes: [EndpointPicker.Probe] = coordinator.lastProbes
        if !probes.isEmpty {
            Section {
                ForEach(probes, id: \EndpointPicker.Probe.id) { (probe: EndpointPicker.Probe) in
                    HStack {
                        let isCurrent = probe.endpoint.url == coordinator.currentEndpointURL
                        Text(isCurrent ? "★" : "·")
                            .foregroundStyle(isCurrent ? .green : .secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(probe.endpoint.url)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(probe.endpoint.kind.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(probe.ok ? "\(probe.rttMs)ms" : "—")
                            .font(.caption.monospaced())
                            .foregroundStyle(probe.ok ? Color.primary : Color.red)
                    }
                }
            } header: {
                Text("候选 endpoint(\(probes.count))")
            } footer: {
                Text("★ = 当前连接。包括本机 Mac 透传的整个 mesh 候选——iOS Bonjour 跨 LAN 拿不到的 Mac 也在这里。RTT 排序选最低延迟。")
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

    /// PIN 配对成功 → 持久化 secret + endpoints + 让 coordinator probe 选最快。
    /// `page` 含 self + mesh_peers,扁平化让 picker 跨全 mesh 探活选最快。
    ///
    /// **不立即写 peerURL**——避免 status 闪一下 preferred URL(通常 tailscale)然后又
    /// 切到 picker 实际选中的(通常 .local)。让 statusSection 只看 currentEndpointURL,
    /// picker 完成才有第一个 URL 显示
    private func handlePairingSuccess(secret: Data, page: PeerEndpointsPage) {
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        sharedSecretHex = secretHex
        let flat = PeerSyncCoordinator.flattenEndpoints(page)
        // 持久化扁平化后的 endpoint list 让重启后能从这恢复
        if let data = try? JSONEncoder().encode(flat),
           let json = String(data: data, encoding: .utf8) {
            peerEndpointsJSON = json
        }
        coordinator.reconfigureFromPairing(secret: secret, endpoints: flat)
    }

    /// 高级面板手填路径——还是支持单 URL + secret 直接连。
    /// **逐字段校验**:URL 跟 secret 哪个空报哪个,而不是 PeerConfig.parse 短路只报第一个
    /// (用户填了 URL 没填 secret 时只看到"未配置 URL"会被误导)
    private func applyManualConfig() {
        let urlTrim = peerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretTrim = sharedSecretHex.trimmingCharacters(in: .whitespacesAndNewlines)
        var missing: [String] = []
        if urlTrim.isEmpty { missing.append("URL") }
        if secretTrim.isEmpty { missing.append("secret") }
        if !missing.isEmpty {
            presentAlert("未填:\(missing.joined(separator: " + "))")
            return
        }
        do {
            let cfg = try PeerConfig.parse(urlString: urlTrim, secretHex: secretTrim)
            coordinator.reconfigure(cfg)
        } catch {
            presentAlert(error.localizedDescription)
        }
    }
}

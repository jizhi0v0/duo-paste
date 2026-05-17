import SwiftUI

struct SettingsView: View {
    @Environment(PeerSyncCoordinator.self) private var coordinator
    @AppStorage("peerURL") private var peerURL: String = ""
    @AppStorage("sharedSecretHex") private var sharedSecretHex: String = ""
    @State private var lastParseError: String?

    @State private var discovery = PeerDiscovery()
    @State private var showScanner = false
    @State private var pairingErrorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://host:8443", text: $peerURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Mac Peer 地址")
                } footer: {
                    Text("Mac daemon 在 tailnet 内监听的 URL,例如 https://your-mac.tail-xxxx.ts.net:8443。两端 scheme 必须一致(都 https 或都 http),否则 WS 握手 EOF。")
                }

                Section {
                    SecureField("64 字符 hex", text: $sharedSecretHex)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("HMAC Shared Secret")
                } footer: {
                    Text("跟 Mac daemon 同一份 64 字符 hex secret。Mac 上路径:~/Library/Application Support/duo-paste/shared-secret")
                }

                Section {
                    Button {
                        applyConfig()
                    } label: {
                        Label("应用 + 连接", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button(role: .destructive) {
                        coordinator.stop()
                    } label: {
                        Label("断开", systemImage: "stop.circle")
                    }
                    .disabled(disconnectDisabled)
                }

                Section("状态") {
                    statusRow
                    if let err = lastParseError {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                discoverySection
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showScanner) {
                QRScannerView(onScan: handleQRScan, isPresented: $showScanner)
            }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    /// Bonjour 浏 _duopaste._tcp + QR 配对 section。扫码按钮**独立于**发现成功——
    /// Local Network 权限拒了 / NSBonjourServices 没生效都不挡用户扫码,扫到 QR 直接
    /// 填字段连接,无需先看到 Mac 出现在列表里
    @ViewBuilder
    private var discoverySection: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("扫描 Mac 显示的二维码", systemImage: "qrcode.viewfinder")
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
                // Local Network 权限拒了 — 给"去设置"CTA;扫码路径仍然可用(上面按钮)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("开启 Local Network 权限", systemImage: "gear")
                        .foregroundStyle(.orange)
                }
            } else if discovery.peers.isEmpty {
                Text("正在扫描同网段的 Mac… 确保 Mac daemon serve=true + 同 Wi-Fi")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(discovery.peers) { peer in
                    HStack {
                        Image(systemName: peer.tls ? "lock.fill" : "lock.open")
                            .foregroundStyle(peer.tls ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(peer.displayName)
                            if let did = peer.deviceID {
                                Text(did)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospaced()
                            }
                        }
                        Spacer()
                    }
                }
            }
            if let pairingErrorText {
                Text(pairingErrorText)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } header: {
            Text("Bonjour 配对")
        } footer: {
            Text("Mac Settings > iOS 配对 > 显示二维码 → 用上面扫描按钮对准自动填好。Bonjour 发现失败也不影响扫码——找不到列表里那行直接扫即可。")
        }
    }

    private var discoveryStatusText: String {
        switch discovery.state {
        case .idle: "未扫描"
        case .browsing: "扫描中"
        case .unauthorized: "需要 Local Network 权限"
        case .failed(let m): "失败: \(m)"
        }
    }

    private func handleQRScan(_ raw: String) {
        do {
            let payload = try PairingPayload.parse(raw)
            peerURL = payload.url
            sharedSecretHex = payload.secret
            pairingErrorText = nil
            applyConfig()
        } catch {
            pairingErrorText = "解析失败: \(error.localizedDescription)"
        }
    }

    private var statusRow: some View {
        HStack {
            Text("连接")
            Spacer()
            Text(statusText)
                .foregroundStyle(statusColor)
                .monospaced()
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

    private func applyConfig() {
        do {
            let cfg = try PeerConfig.parse(urlString: peerURL, secretHex: sharedSecretHex)
            lastParseError = nil
            coordinator.reconfigure(cfg)
        } catch {
            lastParseError = error.localizedDescription
        }
    }
}

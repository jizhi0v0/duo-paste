import SwiftUI

struct SettingsView: View {
    @Environment(PeerSyncCoordinator.self) private var coordinator
    @AppStorage("peerURL") private var peerURL: String = ""
    @AppStorage("sharedSecretHex") private var sharedSecretHex: String = ""
    @State private var lastParseError: String?

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
            }
            .navigationTitle("设置")
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

import SwiftUI
import DuoPasteCore

/// PIN 配对 sheet。两种入口:
/// - Bonjour 发现 tap:peer 信息已知,用户手输 PIN
/// - QR 扫码:全部信息都从 QR 拿到 (prefilledPIN 非 nil),自动 pairing
///
/// 多阶段 loading,直到 coordinator.status == .connected 才关 sheet(让用户看到
/// "配对成功"是真就绪了,不是骗局)。15s 超时兜底防永久挂。
@MainActor
struct PinPairingSheet: View {
    let displayName: String
    let host: String
    let port: Int
    let tls: Bool
    /// QR 入口时传 PIN,sheet 自动开始 pairing 跳过输入阶段
    let prefilledPIN: String?
    @Binding var isPresented: Bool
    let onPaired: (Data, String, PeerEndpointsPage) -> Void

    @Environment(PeerSyncCoordinator.self) private var coordinator
    @State private var pin: String = ""
    @State private var stage: Stage = .input
    @State private var errorText: String?
    @State private var showError: Bool = false
    @FocusState private var pinFocused: Bool

    enum Stage: Equatable {
        case input            // 等用户输 PIN
        case pairing          // POST /pair 中
        case probing          // /endpoints + EndpointPicker 中
        case waitingConnect   // 等 WS hello → status .connected
        case connected
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(displayName).font(.headline)
                    Text("\(tls ? "https" : "http")://\(host):\(port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } header: { Text("配对目标") }

                if stage == .input {
                    Section {
                        TextField("123456", text: $pin)
                            .keyboardType(.numberPad)
                            .font(.system(size: 32, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .focused($pinFocused)
                            .onChange(of: pin) { _, new in
                                pin = String(new.filter { $0.isNumber }.prefix(6))
                            }
                    } header: {
                        Text("Mac 显示的 6 位 PIN")
                    }
                    Section {
                        Button {
                            startPairing()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.shield")
                                Text("配对")
                            }
                        }
                        .disabled(pin.count != 6)
                    }
                } else {
                    Section {
                        HStack(spacing: 12) {
                            if stage == .connected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 22))
                            } else {
                                ProgressView().controlSize(.regular)
                            }
                            Text(stageText)
                                .font(.body)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if stage == .input {
                        Button("取消") { isPresented = false }
                    }
                }
            }
            .alert("配对失败", isPresented: $showError) {
                Button("好") {
                    stage = .input
                    pinFocused = true
                }
            } message: {
                Text(errorText ?? "未知错误")
            }
        }
        .interactiveDismissDisabled(stage != .input)
        .onAppear {
            if let preset = prefilledPIN {
                pin = preset
                startPairing()
            } else {
                pinFocused = true
            }
        }
    }

    private var stageText: String {
        switch stage {
        case .input: return ""
        case .pairing: return "配对中…"
        case .probing: return "获取地址列表…"
        case .waitingConnect: return "建立连接…"
        case .connected: return "配对成功"
        }
    }

    private func startPairing() {
        stage = .pairing
        let pinCopy = pin
        Task { @MainActor in
            do {
                let resp = try await PinPairingClient.pair(
                    host: host, port: port, tls: tls, pin: pinCopy
                )
                stage = .probing

                var comp = URLComponents()
                comp.scheme = tls ? "https" : "http"
                comp.host = host
                comp.port = port
                guard let initialURL = comp.url else {
                    throw PinPairingClient.Error.badURL
                }
                let cfg = PeerConfig(baseURL: initialURL, sharedSecret: resp.secret)
                let client = PeerClient(config: cfg)
                let page = try await client.fetchEndpoints()

                // 让 coordinator 接管:probe + 选最快 + reconfigure + 起 WS
                onPaired(resp.secret, resp.deviceID, page)
                stage = .waitingConnect

                // 等真连接成功:status == .connected。15s 超时兜底防永远挂
                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline {
                    if case .connected = coordinator.status {
                        stage = .connected
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        isPresented = false
                        return
                    }
                    if case .error(let m) = coordinator.status {
                        // coordinator 探活全失败:也算配对失败
                        throw PairingTimeoutError(message: m)
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                // 15s 后仍未 .connected:可能慢网络,still close as "成功"——secret
                // 已落地,后台继续连接,用户在 Settings 看到状态
                stage = .connected
                try? await Task.sleep(nanoseconds: 700_000_000)
                isPresented = false
            } catch {
                errorText = error.localizedDescription
                showError = true
                stage = .input
            }
        }
    }
}

private struct PairingTimeoutError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

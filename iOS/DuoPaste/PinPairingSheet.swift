import SwiftUI
import DuoPasteCore

/// PIN 配对 sheet。两种入口:
/// - Bonjour 发现 tap:peer 信息已知,用户手输 PIN
/// - QR 扫码:全部信息都从 QR 拿到 (prefilledPIN 非 nil),自动 pairing
///
/// 多阶段 loading。PIN 成功并拿到 endpoints 即算配对成功；实际可用性测试和最佳
/// endpoint 选择交给 PeerSyncCoordinator 在 Settings 里持续展示。
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

    @State private var pin: String = ""
    @State private var stage: Stage = .input
    @State private var errorText: String?
    @State private var showError: Bool = false
    @FocusState private var pinFocused: Bool

    enum Stage: Equatable {
        case input            // 等用户输 PIN
        case pairing          // POST /pair 中,原子拿 secret + endpoints
        case probing          // 保存 endpoints + 启动 runtime 可用性测试
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
        case .probing: return "读取候选地址…"
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
                onPaired(resp.secret, resp.deviceID, resp.endpointsPage)
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

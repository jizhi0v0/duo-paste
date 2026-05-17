import SwiftUI
import Network
import DuoPasteCore

/// iOS Settings 端 PIN 配对 sheet。流程:
/// 1. 用户在 PeerDiscovery 列表里 tap Mac → 打开本 sheet
/// 2. 用户输入 Mac 显示的 6 位 PIN
/// 3. POST /pair/<pin> 拿 secret + device_id
/// 4. 用 secret 构 PeerConfig(初始 URL = Bonjour resolved host) → GET /endpoints 拿候选 list
/// 5. EndpointPicker 并发 probe 选最快 → 写进 PeerSyncCoordinator + AppStorage 持久化
@MainActor
struct PinPairingSheet: View {
    let peer: PeerDiscovery.DiscoveredPeer
    @Binding var isPresented: Bool
    let onPaired: (Data, String, [PeerEndpoint]) -> Void

    @State private var pin: String = ""
    @State private var status: Status = .input
    @State private var errorText: String?
    @FocusState private var focused: Bool

    enum Status: Equatable {
        case input
        case pairing       // POST /pair 中
        case probing       // GET /endpoints + 选最快中
        case done
        case failed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(peer.displayName)
                        .font(.headline)
                    if let did = peer.deviceID {
                        Text("device_id: \(did)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("配对目标")
                }
                Section {
                    pinInputRow
                } header: {
                    Text("输入 Mac 显示的 6 位数字")
                } footer: {
                    Text("Mac Settings > iOS 配对 > 显示配对码")
                }
                Section {
                    Button {
                        runPairing()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.shield")
                            Text(statusButtonText)
                        }
                    }
                    .disabled(!canSubmit)
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("PIN 配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
            }
        }
        .onAppear { focused = true }
    }

    private var pinInputRow: some View {
        TextField("123456", text: $pin)
            .keyboardType(.numberPad)
            .font(.system(size: 28, weight: .semibold, design: .monospaced))
            .multilineTextAlignment(.center)
            .focused($focused)
            .onChange(of: pin) { _, newValue in
                pin = String(newValue.filter { $0.isNumber }.prefix(6))
            }
    }

    private var canSubmit: Bool {
        pin.count == 6 && status != .pairing && status != .probing
    }

    private var statusButtonText: String {
        switch status {
        case .input, .failed: return "配对"
        case .pairing: return "配对中…"
        case .probing: return "选择最快连接…"
        case .done: return "完成"
        }
    }

    private func runPairing() {
        status = .pairing
        errorText = nil
        let tls = peer.tls
        let port = peer.port
        // peer.endpoint 是 NWBrowser 的原始 endpoint(.service 形式),pair() 内部转 .local hostname
        let endpoint = peer.endpoint
        let pinCopy = pin

        Task { @MainActor in
            do {
                // 1) POST /pair/<pin>
                let resp = try await PinPairingClient.pair(
                    endpoint: endpoint, port: port, tls: tls, pin: pinCopy
                )
                status = .probing

                // 2) 拿 secret 构 PeerConfig 用 .local URL 临时连接拉 /endpoints
                let host: String
                if case .service(let name, _, _, _) = endpoint {
                    host = "\(name).local"
                } else {
                    host = "\(endpoint)"
                }
                let scheme = tls ? "https" : "http"
                guard let initialURL = URL(string: "\(scheme)://\(host):\(port)") else {
                    throw PinPairingClient.Error.badURL
                }
                let cfg = PeerConfig(baseURL: initialURL, sharedSecret: resp.secret)
                let client = PeerClient(config: cfg)
                let endpoints = try await client.fetchEndpoints()

                // 3) callback 让 coordinator 接管:probe + 选最快 + 持久化
                onPaired(resp.secret, resp.deviceID, endpoints.endpoints)
                status = .done
                // 短暂展示成功后关闭
                try? await Task.sleep(nanoseconds: 600_000_000)
                isPresented = false
            } catch {
                status = .failed
                errorText = error.localizedDescription
            }
        }
    }
}

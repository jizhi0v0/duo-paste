import SwiftUI
import AVFoundation
import UIKit
import DuoPasteCore

/// 摄像头扫 Mac QR → 解析 JSON {host, port, tls, pin} → 直接 PinPairingClient.pair。
/// 用户体验:扫一下就配对成功,中间无手动输 PIN 步骤(PIN 已经在 QR 里)。
///
/// 权限:NSCameraUsageDescription Info.plist 必填,否则 startRunning() 静默挂
struct QRScannerView: View {
    @Binding var isPresented: Bool
    let onScanned: (QRPayload) -> Void

    @State private var error: String?
    @State private var didReport: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                if let error {
                    VStack(spacing: 16) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("打开设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } else {
                    QRScannerRepresentable(
                        onScan: handleScan,
                        onError: { self.error = $0 }
                    )
                    .ignoresSafeArea()
                    VStack {
                        Spacer()
                        Text("把 Mac 显示的 QR 对准方框")
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("扫码配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
            }
        }
    }

    private func handleScan(_ raw: String) {
        guard !didReport else { return }
        guard let payload = QRPayload.parse(raw) else {
            error = "QR 内容无效 — 不是 DuoPaste 配对码"
            return
        }
        didReport = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScanned(payload)
        isPresented = false
    }
}

/// Mac QR payload schema:`{"host":"x.local","port":8443,"tls":true,"pin":"123456","v":1}`
struct QRPayload: Equatable {
    let host: String
    let port: Int
    let tls: Bool
    let pin: String

    static func parse(_ raw: String) -> QRPayload? {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let host = dict["host"] as? String, !host.isEmpty,
              let pin = dict["pin"] as? String, pin.count == 6,
              pin.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        let port = (dict["port"] as? Int) ?? 8443
        let tls = (dict["tls"] as? Bool) ?? true
        return QRPayload(host: host, port: port, tls: tls, pin: pin)
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerVC {
        let vc = QRScannerVC()
        vc.onScan = onScan
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ vc: QRScannerVC, context: Context) {}
}

final class QRScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didReport: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func configureSession() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.onError?("没有摄像头权限。请在设置 > DuoPaste 里允许相机。")
                    return
                }
                self.startCapture()
            }
        }
    }

    private func startCapture() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onError?("当前设备没有可用摄像头(模拟器 / 限制设备)")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            onError?("摄像头初始化失败: \(error.localizedDescription)")
            return
        }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didReport else { return }
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let s = obj.stringValue else { return }
        didReport = true
        onScan?(s)
    }
}

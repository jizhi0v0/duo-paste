import SwiftUI
import AVFoundation
import UIKit
import DuoPasteCore

/// 摄像头扫 Mac QR → 解析 JSON {host, port, tls}，再由配对 sheet 要求用户输入
/// Mac 同屏显示的 6 位 PIN。QR 与 PIN 分离，避免一张截图同时泄露两个因子。
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
        let payload: QRPayload
        do {
            payload = try QRPayload.parse(raw)
        } catch {
            self.error = error.localizedDescription
            return
        }
        didReport = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScanned(payload)
        isPresented = false
    }
}

/// Mac QR v2 payload schema 附带 `cert_sha256`，把眼前 Mac 的 TLS leaf identity
/// 绑定进 pairing handshake。
/// **故意不含 PIN**——QR 泄露 ≠ 配对失守,PIN 在 Mac 屏幕另一区域显示让用户手输,
/// 两道防线分开
struct QRPayload: Equatable {
    let host: String
    let port: Int
    let tls: Bool
    let certificateSHA256: String

    enum ParseError: LocalizedError {
        case invalid
        case macUpgradeRequired
        case httpsRequired

        var errorDescription: String? {
            switch self {
            case .invalid: "QR 内容无效 — 不是 DuoPaste 配对码"
            case .macUpgradeRequired: "Mac 配对码版本过旧，请先升级 Mac 端 DuoPaste"
            case .httpsRequired: "Mac 未提供带 TLS leaf 绑定的安全配对码"
            }
        }
    }

    static func parse(_ raw: String) throws -> QRPayload {
        let wire: PairingQRPayload
        do {
            wire = try PairingQRPayload.parse(raw)
        } catch {
            throw ParseError.invalid
        }
        guard wire.version >= 2 else { throw ParseError.macUpgradeRequired }
        guard wire.tls,
              let certificateSHA256 = wire.normalizedCertificateSHA256,
              wire.isChannelBound else { throw ParseError.httpsRequired }
        return QRPayload(
            host: wire.host,
            port: wire.port,
            tls: true,
            certificateSHA256: certificateSHA256
        )
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

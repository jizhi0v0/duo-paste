import SwiftUI
import AVFoundation
import UIKit

/// 摄像头 QR 扫描 sheet。AVCaptureSession + MetadataOutput (.qr) 路径——简单可靠,
/// iOS 13+ 都跑。扫到 string → onScan callback → 父 view 解析 PairingPayload 后写 Settings。
///
/// 权限:NSCameraUsageDescription 必须在 Info.plist 配,否则 startRunning() 直接静默挂掉
/// (用户也看不到弹窗)。INFOPLIST_KEY_NSCameraUsageDescription 走 build settings 注入。
///
/// 失败路径:
/// - 拒权 → 显示提示 + "去设置" 按钮(UIApplication.openSettingsURLString)
/// - 设备没摄像头(模拟器)→ 显示 fallback 提示
struct QRScannerView: View {
    let onScan: (String) -> Void
    @Binding var isPresented: Bool

    @State private var error: String?
    @State private var lastScan: String?

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
                        onError: { msg in
                            self.error = msg
                        }
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
            .navigationTitle("扫描 QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
            }
        }
    }

    private func handleScan(_ s: String) {
        guard lastScan != s else { return }
        lastScan = s
        onScan(s)
        isPresented = false
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
        } else {
            onError?("无法添加 metadata output")
            return
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
        // 触觉反馈让用户知道扫到了
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(s)
    }
}

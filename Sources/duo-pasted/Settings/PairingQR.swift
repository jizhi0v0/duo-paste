import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DuoPasteCore
import DuoPasteSync

// MARK: - iOS PIN 配对(QR leaf pin + 独立 PIN)

/// QR v2 payload 不含 PIN/credential，只含 endpoint + 当前 TLS leaf SHA-256。扫码把
/// certificate identity 带到 iOS，手输 PIN 再授权一次签发；两条通道缺一不可。
enum PairingQR {
    /// 复用单例:每次 new CIContext 会启动 Metal device(~50-150ms)
    private static let ciContext = CIContext()

    static func fingerprint(for cfg: Config) -> String {
        if let payload = payload(config: cfg) {
            return "\(payload.host)|\(payload.port)|\(payload.certificateSHA256 ?? "")"
        }
        return "unavailable|\(cfg.serve)|\(cfg.serveTLS)|\(cfg.tlsCertPath ?? "")"
    }

    /// Pairing 发生在用户眼前的 Mac/iPhone，同 LAN `.local` 可达性最稳；TLS identity
    /// 已由 QR leaf pin 保证，不再从证书文件名猜 hostname。
    static func resolveHost(cfg _: Config) -> String {
        EndpointDiscovery.preferredLocalHostname()
    }

    static func payload(config: Config) -> PairingQRPayload? {
        guard config.serve,
              config.serveTLS,
              let certificatePath = config.tlsCertPath
        else { return nil }
        let certificateURL = URL(fileURLWithPath: certificatePath)
        guard
              (try? TLSCertificateInspector.inspect(at: certificateURL)) != nil,
              let fileData = try? Data(contentsOf: certificateURL),
              let leafDER = try? PairingCertificatePin.certificateDER(from: fileData)
        else { return nil }
        let sha256 = PairingCertificatePin.sha256Hex(certificateDER: leafDER)
        return try? PairingQRPayload.bound(
            host: resolveHost(cfg: config),
            port: config.servePort,
            certificateSHA256: sha256
        )
    }

    /// 同步生成 QR 图——CIContext 复用后 ~10ms,可 detached task 调
    static func generate(config: Config) -> NSImage? {
        guard let payload = payload(config: config),
              let data = try? payload.encodedData() else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scale: CGFloat = 240 / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 240, height: 240))
    }
}

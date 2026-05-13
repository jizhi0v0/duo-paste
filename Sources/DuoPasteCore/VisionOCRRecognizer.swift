import Foundation
import Vision
import AppKit

/// 生产用 OCR 实现，跑 Vision.framework `VNRecognizeTextRequest`。
///
/// 平台：macOS 14+（项目 platform 下限）。Vision 在主线程外调用安全——recognize
/// 在 detached DispatchQueue.global(qos: .utility) 跑，避免阻塞调用 actor。
///
/// **设计选择**：
/// - `.accurate` 默认（plan §1）。用户大多 OCR 文档 / 代码 / 中文聊天截图，
///   accurate 在中文上漏字明显少于 .fast。单图 0.5-3s 在 utility QoS 后台可接受。
/// - `usesLanguageCorrection=true` 默认，搭配 `recognitionLanguages` hint 让
///   Vision 优先返回符合语言模型的候选；中英文混合截图大多受益
/// - macOS 13+ 开 `automaticallyDetectsLanguage` —— Vision 自动猜语言，
///   不影响 hint 优先级（Apple 文档明确两者并行）
public struct VisionOCRRecognizer: OCRRecognizer {
    /// `.accurate`（默认）/ `.fast`。Config 字符串映射在 Bridge 层做。
    public let recognitionLevel: VNRequestTextRecognitionLevel
    /// 语言模型纠正。中英混合 / 词典强约束场景大多打开。
    public let usesLanguageCorrection: Bool
    public let log: @Sendable (String) -> Void

    public init(
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.log = log
    }

    public func recognize(imageURL: URL, languages: [String]) async throws -> OCRResult {
        let level = recognitionLevel
        let useLang = usesLanguageCorrection
        let langs = languages
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OCRResult, Error>) in
            // Vision request handler 是同步阻塞 API。挪到全局 utility queue 上跑，
            // 防止占着调用线程（actor）让其它工作排队。
            DispatchQueue.global(qos: .utility).async {
                // NSImage(contentsOf:) 失败大概率"文件不是图片格式"，归 imageLoadFailed
                guard let img = NSImage(contentsOf: imageURL) else {
                    cont.resume(throwing: OCRRecognizeError.imageLoadFailed)
                    return
                }
                // 某些容器格式（PDF stub / SVG）拿不到 CGImage；归 unsupportedFormat
                guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    cont.resume(throwing: OCRRecognizeError.unsupportedFormat)
                    return
                }

                let req = VNRecognizeTextRequest()
                req.recognitionLevel = level
                req.usesLanguageCorrection = useLang
                req.recognitionLanguages = langs
                if #available(macOS 13.0, *) {
                    req.automaticallyDetectsLanguage = true
                }
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([req])
                } catch {
                    cont.resume(throwing: OCRRecognizeError.visionTransient(error))
                    return
                }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { obs in
                    obs.topCandidates(1).first?.string
                }
                cont.resume(returning: OCRResult(text: lines.joined(separator: "\n")))
            }
        }
    }
}

extension VisionOCRRecognizer {
    /// 把 Config 字符串映射到 Vision enum。未知值回退 .accurate（Config.validate 应已
    /// 在更早阶段拒绝，这里只是兜底）。
    public static func level(fromConfig s: String) -> VNRequestTextRecognitionLevel {
        switch s.lowercased() {
        case "fast":     return .fast
        case "accurate": return .accurate
        default:         return .accurate
        }
    }
}

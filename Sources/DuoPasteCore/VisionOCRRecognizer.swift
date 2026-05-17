#if os(macOS)
import Foundation
import Vision
import AppKit

/// 生产用 OCR 实现，跑 Vision.framework `VNRecognizeTextRequest`。
///
/// 平台：macOS 14+（项目 platform 下限）。Vision 在主线程外调用安全。
///
/// **线程模型**：recognize 提交到 **专用 OperationQueue**（不是 GCD global / Swift
/// Concurrency cooperative pool）。理由——Vision 是同步阻塞 C API，扔进 GCD global
/// `.utility` queue 时跟 UI 端 ImageThumbnailCache 的 `Task.detached(.userInitiated)`
/// 抢同一进程的 QoS thread 配额——userInitiated 持续 fire 会让 utility 永久饥饿
/// （`recognize → handler.perform` 永不返），mini 上 2026-05-15 v9 backfill 18 张
/// 卡死就是这个 case。OperationQueue 给 Vision **独立 thread budget**，prefetch 跟
/// OCR 各跑各的，scheduler 不再串谋。详 plans/vivid-mapping-muffin.md "OCR starvation"。
///
/// QoS 调到 `.userInitiated`——OCR 是用户感知的索引动作（搜不到截图里的字 = 功能缺失），
/// 不该比 thumbnail decode 低优先级。max=2 限并发——Vision 单图 1-3s 占满 1 个 P-core，
/// 双 mini/mbp 配 4P/12P 都给 OCR 留 2 个并发不挤压 UI。
///
/// **设计选择**：
/// - `.accurate` 默认（plan §1）。用户大多 OCR 文档 / 代码 / 中文聊天截图，
///   accurate 在中文上漏字明显少于 .fast。单图 0.5-3s 可接受。
/// - `usesLanguageCorrection=true` 默认，搭配 `recognitionLanguages` hint 让
///   Vision 优先返回符合语言模型的候选；中英文混合截图大多受益
/// - `automaticallyDetectsLanguage=true` 让 Vision 自动猜语言，不影响 hint 优先级
///   （Apple 文档明确两者并行）。macOS 13+ 可用，项目最低 macOS 14，直接打开
public struct VisionOCRRecognizer: OCRRecognizer {
    /// `.accurate`（默认）/ `.fast`。Config 字符串映射在 Bridge 层做。
    public let recognitionLevel: VNRequestTextRecognitionLevel
    /// 语言模型纠正。中英混合 / 词典强约束场景大多打开。
    public let usesLanguageCorrection: Bool
    public let log: @Sendable (String) -> Void

    /// OCR 专用执行队列。`static let` 让进程内所有 VisionOCRRecognizer 实例共享同一个
    /// budget——多个 recognizer 不会互相加倍 thread 占用。max=2 + userInitiated 详
    /// 上面"线程模型"注释。
    private static let executor: OperationQueue = {
        let q = OperationQueue()
        q.name = "io.duopaste.ocr.vision"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

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
            // 专用 OperationQueue 隔离 Vision 同步阻塞工作。详 struct 注释"线程模型"。
            Self.executor.addOperation {
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
                // 项目最低支持 macOS 14，automaticallyDetectsLanguage 永远可用
                req.automaticallyDetectsLanguage = true
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([req])
                } catch {
                    cont.resume(throwing: OCRRecognizeError.visionTransient(
                        reason: String(describing: error)
                    ))
                    return
                }
                let observations = req.results ?? []
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
#endif

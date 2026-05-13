import Foundation

/// 抽象 OCR 提供方，让 OCRWorker 不直接耦合 Vision.framework，测试可注入 Stub。
///
/// 实现职责：拿到本地 image 文件 → 跑识别 → 返回多行 join("\n") 的 plain text。
/// **不**做 mime 嗅探 / 解码失败兜底 —— 调用方（OCRWorker）按 BlobStore 取到的字节
/// 已经是图片格式（CaptureService 入库时 kind 限定 .image），识别失败抛 typed error
/// 区分"图本身坏 vs Vision 临时抽风"。
public protocol OCRRecognizer: Sendable {
    /// 识别 `imageURL` 指向的图片。`languages` 作为 Vision 识别语言 hint（按优先级）。
    /// - Throws: `OCRRecognizeError` —— worker 据此决定 skipped / 重试 / 终态 failed。
    func recognize(imageURL: URL, languages: [String]) async throws -> OCRResult
}

public struct OCRResult: Sendable, Equatable {
    /// 识别出的全部文本，多行按 "\n" 连接。空字符串表示"图里没字"（仍是有效结果，
    /// worker 标 done 不重试）。调用方往 item.text_full 写入时需把空串归一化为 nil
    /// （详 plan §2 不变量 #3：FTS5 对空字符串匹配/snippet 行为有 corner case）。
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// OCR 失败的 typed error。OCRWorker 按 case 决定后续行为：
///
/// - `imageLoadFailed` / `unsupportedFormat` / `visionPermanent`
///   → 标 `skipped`，不再重试（图本身有问题）
/// - `visionTransient`
///   → bump 内存 attempts 计数，达到上限再标 `failed`（Vision 模型一过性抽风）
///
/// **存 String reason 而不是 `any Error`**：原版本是 `case visionTransient(Error)`，
/// 让枚举存 `any Error` 存在 Swift 6 strict-concurrency 顾虑——`any Error` 不静态
/// Sendable，underlying 的 NSError userInfo 里可能含 NSMutableArray 等非 Sendable 内容。
/// recognize 把 error 从 DispatchQueue.global 跨回 actor 边界时若未来开启 strict 模式
/// 会报。降级为 reason 字符串：消费者（OCRWorker）只用它走日志 + `last_push_error`
/// 列，不需要原 typed Error 对象
public enum OCRRecognizeError: Error, Sendable {
    /// NSImage init 失败（文件损坏 / 非图片格式 / 读不到字节）。
    case imageLoadFailed
    /// 拿 CGImage 失败（某些 PDF stub / SVG / 容器类格式）。
    case unsupportedFormat
    /// Vision 抛错可能临时（GPU 占用 / 模型加载竞争 / 系统休眠唤醒过渡期）。
    case visionTransient(reason: String)
    /// Vision 抛错并明确是永久性（罕见，预留语义；当前 VisionOCRRecognizer 不主动
    /// 产生，但 stub 测试用得到 + 未来可加 NSError code 判别）。
    case visionPermanent(reason: String)
}

extension OCRRecognizeError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .imageLoadFailed:      return "OCRRecognizeError.imageLoadFailed"
        case .unsupportedFormat:    return "OCRRecognizeError.unsupportedFormat"
        case .visionTransient(let r): return "OCRRecognizeError.visionTransient(\(r))"
        case .visionPermanent(let r): return "OCRRecognizeError.visionPermanent(\(r))"
        }
    }
}

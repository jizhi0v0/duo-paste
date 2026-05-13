import Foundation
@testable import DuoPasteCore

/// 计数器，让测试断言"recognize 被调几次 / 被调过谁"。actor 隔离让并发 worker tick
/// 互不打架
actor OCRCallRecorder {
    private(set) var calls: [String] = []

    func record(_ name: String) {
        calls.append(name)
    }

    func snapshot() -> [String] { calls }
    func count() -> Int { calls.count }
    func reset() { calls.removeAll() }
}

/// Stub OCR Recognizer：根据 imageURL.lastPathComponent 查表决定返回 success / 抛错。
/// 默认未配置的 key → 抛 imageLoadFailed（让"忘了 seed"在测试里立即可见）
struct StubOCRRecognizer: OCRRecognizer {
    typealias Outcome = Result<OCRResult, OCRRecognizeError>

    /// key = imageURL.lastPathComponent，常见取 BlobStore.locate 返回的 sha+ext 文件名
    let table: [String: Outcome]
    let recorder: OCRCallRecorder

    init(table: [String: Outcome] = [:], recorder: OCRCallRecorder = OCRCallRecorder()) {
        self.table = table
        self.recorder = recorder
    }

    func recognize(imageURL: URL, languages: [String]) async throws -> OCRResult {
        await recorder.record(imageURL.lastPathComponent)
        let key = imageURL.lastPathComponent
        // 也允许只匹配 sha 前缀（path 是 .../<ab>/<cd>/<sha>.<ext>）
        if let o = table[key] {
            switch o {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
        // 试试 sha 子串匹配——测试 seed table 用 sha 不带 ext 也能命中
        let nameWithoutExt = (key as NSString).deletingPathExtension
        if let o = table[nameWithoutExt] {
            switch o {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
        throw OCRRecognizeError.imageLoadFailed
    }
}

/// 永远抛 transient 的 recognizer，用于测试 max-attempts 路径
struct AlwaysTransientRecognizer: OCRRecognizer {
    let recorder: OCRCallRecorder
    func recognize(imageURL: URL, languages: [String]) async throws -> OCRResult {
        await recorder.record(imageURL.lastPathComponent)
        struct E: Error {}
        throw OCRRecognizeError.visionTransient(E())
    }
}

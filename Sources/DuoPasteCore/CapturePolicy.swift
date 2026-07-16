import Foundation

/// 当前 daemon 进程内的临时暂停状态。故意不持久化：daemon 重启后恢复捕获，避免一次
/// 忘记恢复的暂停跨重启永久漏记。
public enum CapturePause: Equatable, Sendable {
    case until(Date)
    case untilResumed

    public func isActive(at now: Date = Date()) -> Bool {
        switch self {
        case .until(let deadline):
            return now < deadline
        case .untilResumed:
            return true
        }
    }

    public var deadline: Date? {
        guard case .until(let date) = self else { return nil }
        return date
    }
}

/// 捕获入口的纯策略。bundle ID 匹配会 trim + case-fold；未知 source app 默认放行，
/// 因为某些系统 pasteboard 写入没有 frontmost bundle ID，不能把它们全部误伤。
public struct CapturePolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case allow
        case excludedApp(bundleID: String)
        case paused
    }

    private let normalizedExcludedBundleIDs: Set<String>

    public init(excludedBundleIDs: [String] = []) {
        self.normalizedExcludedBundleIDs = Set(
            excludedBundleIDs.compactMap(Self.normalizeBundleID)
        )
    }

    public func decision(
        sourceAppBundleID: String?,
        pause: CapturePause? = nil,
        now: Date = Date()
    ) -> Decision {
        if let pause, pause.isActive(at: now) {
            return .paused
        }
        guard let raw = sourceAppBundleID,
              let normalized = Self.normalizeBundleID(raw),
              normalizedExcludedBundleIDs.contains(normalized)
        else {
            return .allow
        }
        return .excludedApp(bundleID: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func normalizeBundleID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

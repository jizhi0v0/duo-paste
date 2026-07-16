import Foundation

/// 每台 Mac 的稳定标识，首次启动随机生成后落盘，之后只读。
/// 用作 item.origin_device，让 primary 能区分聚合来源。
public enum DeviceID {
    public enum DeviceIDError: Error, CustomStringConvertible, Sendable {
        case empty(URL)

        public var description: String {
            switch self {
            case .empty(let file): return "device-id 为空：\(file.path)"
            }
        }
    }

    /// 严格只读加载。灾难恢复不能悄悄生成新 ID，否则历史 own-origin 会永久失去 owner。
    public static func load(at file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { throw DeviceIDError.empty(file) }
        return value
    }

    public static func loadOrCreate(at file: URL) throws -> String {
        if let existing = try? load(at: file) { return existing }
        let new = UUID().uuidString.lowercased()
        try new.write(to: file, atomically: true, encoding: .utf8)
        return new
    }
}

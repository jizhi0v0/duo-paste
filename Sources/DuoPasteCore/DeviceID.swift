import Foundation

/// 每台 Mac 的稳定标识，首次启动随机生成后落盘，之后只读。
/// 用作 item.origin_device，让 primary 能区分聚合来源。
public enum DeviceID {
    public static func loadOrCreate(at file: URL) throws -> String {
        if let data = try? Data(contentsOf: file),
           let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty
        {
            return s
        }
        let new = UUID().uuidString.lowercased()
        try new.write(to: file, atomically: true, encoding: .utf8)
        return new
    }
}

import Foundation

/// Shared secret 持久化：`~/Library/Application Support/duo-paste/shared-secret`
/// 文件内容是 64 字符小写 hex（= 32 字节随机）。Plan 里说要放 keychain，
/// 现阶段先用文件，等 M3 稳定后再迁。
///
/// 生成方法（user 手动）：
///
///     openssl rand -hex 32 > ~/Library/Application\ Support/duo-paste/shared-secret
///     chmod 600 ~/Library/Application\ Support/duo-paste/shared-secret
///
/// 三台 Mac 上放同一份。primary 用它校验入站请求，client 用它签出站请求。
public enum SharedSecret {
    public static func load(from path: URL) throws -> Data {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            throw SharedSecretError.notFound(path: path)
        }
        // 检查文件权限——0600 是底线，更宽就拒绝（避免别的进程读到）。
        if let attrs = try? fm.attributesOfItem(atPath: path.path),
           let mode = attrs[.posixPermissions] as? NSNumber {
            // 允许 0600，禁止任何 group/other 可读
            if mode.uint16Value & 0o077 != 0 {
                throw SharedSecretError.permissionsTooOpen(
                    path: path,
                    mode: mode.uint16Value
                )
            }
        }
        let raw = try String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count == 64, raw.allSatisfy({ $0.isHexDigit }) else {
            throw SharedSecretError.invalidFormat(path: path)
        }
        guard let data = Data(hexString: raw), data.count == 32 else {
            throw SharedSecretError.invalidFormat(path: path)
        }
        return data
    }
}

public enum SharedSecretError: Error, CustomStringConvertible, Sendable {
    case notFound(path: URL)
    case permissionsTooOpen(path: URL, mode: UInt16)
    case invalidFormat(path: URL)

    public var description: String {
        switch self {
        case .notFound(let p):
            return "shared-secret 文件不存在 (\(p.path))。运行：openssl rand -hex 32 > \(p.path) && chmod 600 \(p.path)"
        case .permissionsTooOpen(let p, let m):
            return String(format: "shared-secret 权限过宽 (mode=%o)，应为 0600：chmod 600 %@", m, p.path)
        case .invalidFormat(let p):
            return "shared-secret 内容不是 64 字符 hex (\(p.path))"
        }
    }
}

private extension Character {
    var isHexDigit: Bool {
        isASCII && (isNumber || ("a"..."f").contains(self) || ("A"..."F").contains(self))
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i+1].hexDigitValue else {
                return nil
            }
            bytes.append(UInt8(hi * 16 + lo))
        }
        self.init(bytes)
    }
}

import Foundation

/// RFC 9562 UUID version 7：高位 48 bit = Unix ms 时间戳。
/// 跨设备插入到 primary 时仍大致有序，对 B-tree 友好。
public enum UUIDv7 {
    public static func generate() -> UUID {
        generate(timestampMs: currentTimestampMs())
    }

    public static func generate(timestampMs: UInt64) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)

        // 48 bit timestamp（big endian）
        bytes[0] = UInt8((timestampMs >> 40) & 0xff)
        bytes[1] = UInt8((timestampMs >> 32) & 0xff)
        bytes[2] = UInt8((timestampMs >> 24) & 0xff)
        bytes[3] = UInt8((timestampMs >> 16) & 0xff)
        bytes[4] = UInt8((timestampMs >> 8) & 0xff)
        bytes[5] = UInt8(timestampMs & 0xff)

        // 剩余 10 字节随机
        var rand = [UInt8](repeating: 0, count: 10)
        _ = SecRandomCopyBytes(kSecRandomDefault, rand.count, &rand)
        for i in 0..<10 {
            bytes[6 + i] = rand[i]
        }

        // version = 7（bits 48..51）
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        // variant = 10（bits 64..65）
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func generateString() -> String {
        generate().uuidString.lowercased()
    }

    /// 从 UUIDv7 取回高 48 bit Unix 毫秒。非 UUIDv7 / 非法字符串返 nil。
    /// Item 的 capturedAtNs 会在用户粘贴后 bump，不能用它判断最初 capture 时间；
    /// UUIDv7 里的时间戳不会随使用更新，适合做跨设备 Continuity 副本判定。
    public static func timestampMs(from string: String) -> UInt64? {
        guard let uuid = UUID(uuidString: string) else { return nil }
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        guard bytes.count == 16, (bytes[6] >> 4) == 0x7 else { return nil }

        var timestamp: UInt64 = 0
        for byte in bytes.prefix(6) {
            timestamp = (timestamp << 8) | UInt64(byte)
        }
        return timestamp
    }

    private static func currentTimestampMs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return UInt64(ts.tv_sec) * 1000 + UInt64(ts.tv_nsec) / 1_000_000
    }
}

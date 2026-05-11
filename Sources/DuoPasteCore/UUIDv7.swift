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

    private static func currentTimestampMs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return UInt64(ts.tv_sec) * 1000 + UInt64(ts.tv_nsec) / 1_000_000
    }
}

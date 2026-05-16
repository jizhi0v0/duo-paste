import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif
#if canImport(Darwin)
import Darwin
#endif

/// 从 Surge for Mac 的 `SGCore.plist` 里推断本机的 Ponte 主机名（`<ponteName>.sgponte`）。
///
/// 用途：daemon 想告诉对端"用这个名字找我"（mesh-doctor / 未来 iOS pairing / /health 广播）。
/// Surge 不暴露"self"字段，必须用硬件指纹（`hw.model` + `ComputerName`）从
/// `PonteDeviceList` 里挑出本机那条。匹配算法见 `matchSelf(_:hwModel:computerName:)`。
///
/// **不做**：
/// - 不对自己的 `.sgponte` 做 loopback 可达性探测（本机走不通 loopback 是正常的，从外部
///   iOS 来访才走得通；识别 self 只为了"告诉对端这个名字"）
/// - 不写死 PonteDeviceList 里的位置（Surge 没有"自己"标记，列表顺序也不稳定）
/// - 不信 ponteName 大小写（Surge 把"MAC" / "MBPMBP" 写进 plist，DNS 是大小写无关的，
///   但拼出来的主机名 lowercase 更卫生 + 用户阅读舒服）
public enum SurgePonte {
    /// 默认 plist 路径。可被测试覆盖。
    public static let defaultPlistPath: String = {
        let home = NSHomeDirectory()
        return home + "/Library/Application Support/com.nssurge.surge-mac/SGCore.plist"
    }()

    /// 已激活 Ponte 设备的 `ponteType` 值。Surge 内部约定，AppleTV 等其他类型走别的值。
    public static let activePonteType: Int = 3

    /// 发现 self 的 `.sgponte` 主机名。
    ///
    /// 任一前置（plist 读不到 / hw.model 读不到 / ComputerName 读不到 / 算法不命中）失败
    /// 返回 nil。**不抛错**——这是诊断/广告路径，永远 graceful degrade（没装 Surge / 没
    /// 配 Ponte 是合法状态）。
    ///
    /// 参数全部带默认值，测试可注入。
    public static func discoverSelfHostname(
        plistPath: String? = nil,
        hwModel: String? = nil,
        computerName: String? = nil
    ) -> String? {
        let path = plistPath ?? defaultPlistPath
        guard let list = try? loadPonteDeviceList(at: path) else { return nil }
        guard let model = hwModel ?? readHardwareModel() else { return nil }
        guard let name = computerName ?? readComputerName() else { return nil }
        return matchSelf(in: list, hwModel: model, computerName: name)
    }

    /// 读 `SGCore.plist` 的 `PonteDeviceList`。文件不存在 / 不是 plist / 没这个键
    /// 都 throw。每条记录返回原始 `[String: Any]` 让 `matchSelf` 自己挑字段。
    public static func loadPonteDeviceList(at path: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else {
            throw PlistShapeError.rootNotDict
        }
        guard let raw = dict["PonteDeviceList"] else {
            throw PlistShapeError.missingPonteDeviceList
        }
        guard let arr = raw as? [[String: Any]] else {
            throw PlistShapeError.ponteDeviceListWrongShape
        }
        return arr
    }

    /// 算法（顺序不能乱）：
    ///
    /// 1. 优先：筛 `ponteType == 3` 且 `deviceModel == hwModel` 且 `deviceName == computerName`。
    ///    - 恰好 1 条 → 命中
    ///    - 多于 1 条（同名同型号，理论罕见）→ 放弃返回 nil
    /// 2. 回退：精确匹配 0 条时，只按 `deviceModel` 筛 `ponteType == 3` 的条目。
    ///    - 恰好 1 条 → 命中
    ///    - 0 条 / 多于 1 条 → 返回 nil
    /// 3. 主机名 = `ponteName.lowercased() + ".sgponte"`。
    ///
    /// 公开是为了让测试不用造 plist 文件就能覆盖匹配语义。
    public static func matchSelf(
        in list: [[String: Any]],
        hwModel: String,
        computerName: String
    ) -> String? {
        // 只看已激活 Ponte 设备
        let active = list.filter { ($0["ponteParameter"] as? [String: Any])?["ponteType"] as? Int == activePonteType }

        let exact = active.filter { entry in
            guard let param = entry["ponteParameter"] as? [String: Any],
                  let model = param["deviceModel"] as? String,
                  let name = entry["deviceName"] as? String
            else { return false }
            return model == hwModel && name == computerName
        }
        if exact.count == 1, let host = hostname(from: exact[0]) {
            return host
        }
        if exact.count > 1 {
            // 同型同名多条无法区分，放弃。
            return nil
        }

        // exact.count == 0 → fallback：只按 model
        let byModel = active.filter { entry in
            guard let param = entry["ponteParameter"] as? [String: Any],
                  let model = param["deviceModel"] as? String
            else { return false }
            return model == hwModel
        }
        if byModel.count == 1, let host = hostname(from: byModel[0]) {
            return host
        }
        return nil
    }

    private static func hostname(from entry: [String: Any]) -> String? {
        guard let raw = entry["ponteName"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased() + ".sgponte"
    }

    // MARK: - 系统指纹读取

    /// `sysctlbyname("hw.model")`。物理 Mac 上拿到 "Mac16,10" / "MacBookPro18,3" 这类串。
    public static func readHardwareModel() -> String? {
        #if canImport(Darwin)
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return nil }
        // sysctlbyname 写入的串以 \0 结尾，去掉尾部 nul + 之后任何字节再 decode
        let trimmed: [UInt8]
        if let nulIdx = buf.firstIndex(of: 0) {
            trimmed = Array(buf[..<nulIdx])
        } else {
            trimmed = buf
        }
        let s = String(decoding: trimmed, as: UTF8.self)
        return s.isEmpty ? nil : s
        #else
        return nil
        #endif
    }

    /// `SCDynamicStoreCopyComputerName`——等同 `scutil --get ComputerName`。
    /// 注意 ComputerName 是用户可读串，可以含 Unicode（如 curly quote `'`）。返回值跟
    /// Surge 写进 plist 的 `deviceName` 字符串字节级一致——`scutil` 跟 Surge 都用同一
    /// SystemConfiguration API。
    public static func readComputerName() -> String? {
        #if canImport(SystemConfiguration)
        guard let cf = SCDynamicStoreCopyComputerName(nil, nil) else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
        #else
        return nil
        #endif
    }

    public enum PlistShapeError: Error {
        case rootNotDict
        case missingPonteDeviceList
        case ponteDeviceListWrongShape
    }
}

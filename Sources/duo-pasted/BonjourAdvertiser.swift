import Foundation

/// Mac daemon 起 `_duopaste._tcp` Bonjour 广播 + TXT record(device_id + tls 标记)。
/// iOS 端 NWBrowser 浏到这个 → 显示在 Settings 的"发现的 Mac"列表 → 用户 tap 选择 →
/// 扫描 Mac 显示的 QR 完成 secret 配对。
///
/// 限本网段(Bonjour 不跨 WAN);跟"不走公网"原则一致——secret 通过 QR 扫描而非
/// 网络传输,合法用户物理在 Mac 前才能拿到 secret。
///
/// **用 NetService 而非 NWListener** —— NWListener.service 强制绑定 listener 自己的 port,
/// 不能"通告 X 不绑 X"。SyncServer 已经占了 8443,所以走 NetService.publish 在 mDNS 层
/// 仅做广播,不开 socket。NetService 在 macOS 14+ 仍可用(API 标记 deprecated 不影响功能)。
///
/// 跟 SyncServer 解耦:advertiser 只广播"我在这"信号,不持有 server。daemon 同时
/// 起两个;停 daemon 时一起停
@MainActor
final class BonjourAdvertiser: NSObject {
    static let serviceType = "_duopaste._tcp"

    private let port: Int
    private let deviceID: String
    private let tls: Bool
    private var service: NetService?
    private let log: (String) -> Void

    init(
        port: Int,
        deviceID: String,
        tls: Bool,
        log: @escaping (String) -> Void = { msg in
            FileHandle.standardError.write(Data("bonjour: \(msg)\n".utf8))
        }
    ) {
        self.port = port
        self.deviceID = deviceID
        self.tls = tls
        self.log = log
    }

    /// Bonjour publish。已起则 noop
    func start() {
        guard service == nil else { return }
        // domain 空 = 本网段;name 空 = 系统用 hostname
        let s = NetService(domain: "", type: Self.serviceType, name: "", port: Int32(port))
        s.delegate = self
        let txt: [String: Data] = [
            "device_id": Data(deviceID.utf8),
            "tls": Data((tls ? "1" : "0").utf8),
            "v": Data("1".utf8),
        ]
        let txtData = NetService.data(fromTXTRecord: txt)
        // setTXTRecord 必须在 publish 之前;之后改 TXT 也走这个 API
        s.setTXTRecord(txtData)
        s.publish()
        service = s
    }

    func stop() {
        service?.stop()
        service = nil
    }
}

extension BonjourAdvertiser: NetServiceDelegate {
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor in
            self.log("published · type=\(Self.serviceType) port=\(self.port) device_id=\(self.deviceID)")
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in
            self.log("publish failed: \(errorDict)")
        }
    }
}

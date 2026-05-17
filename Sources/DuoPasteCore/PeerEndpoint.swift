import Foundation

/// Mac daemon 暴露的可达 URL 候选。iOS 拿到 list 后并发探活测 RTT,选最低延迟连接。
///
/// 候选来源:
/// - `tailscale`:TLS cert CN(由 `tailscale cert <host>` 产出),跨 LAN/WAN 通,iOS 需装
///   Tailscale 客户端才能解析 hostname
/// - `ponte`:`SurgePonte.discoverSelfHostname()`,iOS 装 Surge 才能解析
/// - `local`:`<hostname>.local` mDNS,同 Wi-Fi
/// - `lan_ip`:本机当前 LAN IPv4 / IPv6,无 DNS 也能连(但 TLS cert 不匹配 → iOS 用此条
///   走 HTTP 或自签名跳过)
///
/// `preferred` 给个 hint,iOS 探活前可先尝试该 endpoint(避免无谓并发),探活结果仍然以
/// 实测 RTT 为准。
public struct PeerEndpoint: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case tailscale, ponte, local, lanIP = "lan_ip"
    }

    public let url: String
    public let kind: Kind
    public let preferred: Bool

    public var id: String { url }

    public init(url: String, kind: Kind, preferred: Bool = false) {
        self.url = url
        self.kind = kind
        self.preferred = preferred
    }
}

/// 一台 mesh peer Mac 的 endpoint 候选 list(从 hub Mac 视角:本机周期 fetch peer 的
/// /endpoints 缓存)。iOS 配对任一 Mac 后就能通过 `PeerEndpointsPage.meshPeers` 拿全
/// mesh,picker 探活全部候选选全局最快。
///
/// `healthy = true` 表示 hub Mac 最近一次 fetch peer 成功;`false` 表示当前不通但缓存
/// 期内仍暴露(防 iOS 失去 fallback 候选)。`staleAfterSec` 之后 hub 把这条 peer 整个
/// 从 mesh_peers 列表删除
public struct MeshPeerEntry: Codable, Equatable, Sendable, Identifiable {
    public let peerDeviceID: String
    public let endpoints: [PeerEndpoint]
    public let learnedAtUnix: Int64
    public let healthy: Bool

    public var id: String { peerDeviceID }

    enum CodingKeys: String, CodingKey {
        case peerDeviceID = "peer_device_id"
        case endpoints
        case learnedAtUnix = "learned_at_unix"
        case healthy
    }

    public init(peerDeviceID: String, endpoints: [PeerEndpoint], learnedAtUnix: Int64, healthy: Bool) {
        self.peerDeviceID = peerDeviceID
        self.endpoints = endpoints
        self.learnedAtUnix = learnedAtUnix
        self.healthy = healthy
    }
}

/// `GET /endpoints` 响应。
/// - `device_id`:server 本机 device_id。hub Mac fetch peer 时拿到这个 stamp 进
///   `MeshPeerEntry.peerDeviceID`,避免还得读 pull_cursor DB
/// - `updated_at_unix`:server 算 endpoints 那一刻的时间戳。iOS 做 "已是最新" 比对
/// - `mesh_peers`:hub Mac 周期 fetch 其他 mesh peer 的 /endpoints 后聚合暴露。Optional
///   让老 iOS / 老 Mac daemon 也能解码(缺失 = 只看 self endpoints)
public struct PeerEndpointsPage: Codable, Equatable, Sendable {
    public let deviceID: String
    public let endpoints: [PeerEndpoint]
    public let updatedAtUnix: Int64
    public let meshPeers: [MeshPeerEntry]?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case endpoints
        case updatedAtUnix = "updated_at_unix"
        case meshPeers = "mesh_peers"
    }

    public init(
        deviceID: String,
        endpoints: [PeerEndpoint],
        updatedAtUnix: Int64,
        meshPeers: [MeshPeerEntry]? = nil
    ) {
        self.deviceID = deviceID
        self.endpoints = endpoints
        self.updatedAtUnix = updatedAtUnix
        self.meshPeers = meshPeers
    }
}

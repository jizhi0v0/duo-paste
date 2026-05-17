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

/// `GET /endpoints` 响应。`updated_at_unix` 给 iOS 做 "已是最新" 比对,避免无意义 re-probe
public struct PeerEndpointsPage: Codable, Equatable, Sendable {
    public let endpoints: [PeerEndpoint]
    public let updatedAtUnix: Int64

    enum CodingKeys: String, CodingKey {
        case endpoints
        case updatedAtUnix = "updated_at_unix"
    }

    public init(endpoints: [PeerEndpoint], updatedAtUnix: Int64) {
        self.endpoints = endpoints
        self.updatedAtUnix = updatedAtUnix
    }
}

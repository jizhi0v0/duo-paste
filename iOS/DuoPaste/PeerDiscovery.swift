import Foundation
import Network
import Observation

/// iOS Settings 端 NWBrowser 浏 `_duopaste._tcp.` 拿本网段 Mac peer 列表。
/// 跟 Mac BonjourAdvertiser 配对——Mac 那边 publish,这边 browse。
///
/// 列表只做附近设备发现；用户 tap 会被引导扫描 Mac 同屏 QR，取得 host/port/tls +
/// leaf pin 后再输入 PIN。Bonjour TXT 本身不作为 credential onboarding trust anchor。
///
/// **生命周期**:Settings 打开就 start(),关掉 stop()。不持久——每次重新打开重新 browse。
/// NWBrowser 本身是异步事件流,实例 alive 期间 browseResults 列表会随网络变化自动更新
/// (peer 上下线、TXT 改)。
@MainActor
@Observable
final class PeerDiscovery {
    struct DiscoveredPeer: Identifiable, Equatable {
        let id: String  // endpoint description string—稳定 key 让 SwiftUI ForEach 不丢 selection
        let displayName: String
        let deviceID: String?
        let tls: Bool
        let port: Int       // TXT record port=8443
        let host: String    // TXT record host (mDNS sanitized,如 "bobbys-mac-mini.local")—— PIN /pair URL 用这个
        let endpoint: NWEndpoint
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    enum State: Equatable {
        case idle
        case browsing
        case unauthorized(String)  // local network privacy 拒绝 / NSBonjourServices 漏配
        case failed(String)
    }

    private(set) var peers: [DiscoveredPeer] = []
    private(set) var state: State = .idle

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        state = .browsing
        let params = NWParameters()
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: "_duopaste._tcp",
            domain: nil
        )
        let b = NWBrowser(for: descriptor, using: params)
        // NWBrowser callbacks 走 `using:` queue(.main)。@Sendable 闭包 capture self 在
        // Swift 6 strict concurrency 下需要标 isolated; 走 Task @MainActor in 路径 + 显式
        // weak-rebind 让捕获在 hop 后做(避免 NWBrowser dispatch 队列上读 MainActor 字段)
        b.stateUpdateHandler = { [weak self] state in
            let stateCopy = state
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch stateCopy {
                case .failed(let err): self.state = .failed("\(err)")
                case .cancelled: self.state = .idle
                case .ready: self.state = .browsing
                case .waiting(let err): self.state = .unauthorized("\(err)")
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let snapshot = results
            Task { @MainActor [weak self] in
                self?.applyResults(snapshot)
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peers = []
        state = .idle
    }

    private func applyResults(_ results: Set<NWBrowser.Result>) {
        var out: [DiscoveredPeer] = []
        for r in results {
            let txt: [String: String]
            if case .bonjour(let record) = r.metadata {
                txt = Self.txtToDict(record)
            } else {
                txt = [:]
            }
            let name = Self.endpointDisplayName(r.endpoint)
            // port 从 TXT 拿(BonjourAdvertiser 也设 NetService.port,但 .service endpoint
            // 客户端拿不到 port,必须走 TXT 或 resolve)。默认 8443 兜底
            let port = txt["port"].flatMap { Int($0) } ?? 8443
            // host:Bonjour service.name 是 display name(含空格 / 撇号),不能直接拼 URL。
            // Mac 在 TXT 广播真 mDNS hostname(sanitized);TXT 没 host 时兜底走 service.name +
            // .local(老版本 Mac 兼容,但 PIN /pair URL 可能因含空格 fail)
            let host: String = txt["host"] ?? "\(name).local"
            let peer = DiscoveredPeer(
                id: "\(r.endpoint)",
                displayName: name,
                deviceID: txt["device_id"],
                tls: txt["tls"] == "1",
                port: port,
                host: host,
                endpoint: r.endpoint
            )
            out.append(peer)
        }
        // 按 display name 稳定排序避免列表抖动
        out.sort { $0.displayName < $1.displayName }
        peers = out
    }

    private static func endpointDisplayName(_ ep: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = ep {
            return name
        }
        return "\(ep)"
    }

    private static func txtToDict(_ record: NWTXTRecord) -> [String: String] {
        var d: [String: String] = [:]
        for (k, v) in record.dictionary {
            d[k] = v
        }
        return d
    }
}

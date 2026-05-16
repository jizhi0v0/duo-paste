import Testing
import Foundation
import DuoPasteCore
@testable import DuoPasteSync

/// PR 3 SmartTransport.decideOne 单元测试——用 fake probe 注入决策证据，验算法分支
/// 全覆盖。不起真 server，跑得快可在 CI 上稳

@Suite("SmartTransport discover algorithm")
struct SmartTransportTests {

    private func makePeer(url: String, deviceID: String? = nil, pullURL: String? = nil) -> Config.PeerConfig {
        Config.PeerConfig(
            url: URL(string: url)!,
            deviceID: deviceID,
            pullURL: pullURL.flatMap { URL(string: $0) }
        )
    }

    /// 构造可控 probe：给每个 URL 一个预设 outcome + RTT；其余 URL 返回 unreachable
    private func makeFakeProbe(
        responses: [String: (PrimaryHealthResult.Outcome, Int64)]
    ) -> SmartTransport.HealthProbe {
        return { url in
            let key = url.absoluteString
            if let r = responses[key] { return r }
            return (.unreachable(reason: "fake: no response for \(key)"), -1)
        }
    }

    @Test func tailscaleOnlyWhenPeerNotPonteAware() async {
        // 老 daemon /health 不返回 ponte_host → 没 candidate → tailscale 兜底
        let peer = makePeer(url: "https://mbp.tail.ts.net:8443")
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp-id", nowMs: 1000, ponteHost: nil), 100)
        ])
        let d = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe)
        #expect(d.chosenPullURL.absoluteString == "https://mbp.tail.ts.net:8443")
        #expect(d.chosenWSKind == .nio)
        #expect(d.learnedPonteHost == nil)
    }

    @Test func learnedPonteHostBuildsCandidate() async {
        // 对端 /health 报 ponte_host=mbp.sgponte → 拼 candidate https://mbp.sgponte:8443
        // → probe OK → 选 ponte
        let peer = makePeer(url: "https://mbp.tail.ts.net:8443")
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp-id", nowMs: 1000, ponteHost: "mbp.sgponte"), 120),
            "https://mbp.sgponte:8443": (.ok(deviceID: "mbp-id", nowMs: 1001, ponteHost: "mbp.sgponte"), 90)
        ])
        let d = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe)
        #expect(d.learnedPonteHost == "mbp.sgponte")
        #expect(d.chosenPullURL.host == "mbp.sgponte")
        #expect(d.chosenPullURL.port == 8443)
        #expect(d.chosenWSKind == .urlSession)
    }

    @Test func manualPullURLAlwaysWinsEvenIfPonteLearned() async {
        // 用户手抄了 pull_url（trump card），即便学到 ponte_host 也 trust manual
        let peer = makePeer(
            url: "https://mbp.tail.ts.net:8443",
            pullURL: "https://my-override.sgponte:9000"
        )
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp-id", nowMs: 1000, ponteHost: "mbp.sgponte"), 120),
            "https://my-override.sgponte:9000": (.ok(deviceID: "mbp-id", nowMs: 1001, ponteHost: nil), 50),
            "https://mbp.sgponte:8443": (.ok(deviceID: "mbp-id", nowMs: 1002, ponteHost: nil), 80)
        ])
        let d = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe)
        #expect(d.chosenPullURL.absoluteString == "https://my-override.sgponte:9000")
        // chosen URL host 末段 sgponte → WS 也走 URLSession
        #expect(d.chosenWSKind == .urlSession)
    }

    @Test func ponteProbeFailureFallsBackToTailscale() async {
        // 学到 ponte_host 但 candidate 不可达（Surge 没启 / proxy 端口断）→ 回 tailscale
        let peer = makePeer(url: "https://mbp.tail.ts.net:8443")
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp-id", nowMs: 1000, ponteHost: "mbp.sgponte"), 120),
            "https://mbp.sgponte:8443": (.unreachable(reason: "proxy down"), -1)
        ])
        let d = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe)
        #expect(d.chosenPullURL.host == "mbp.tail.ts.net")
        #expect(d.chosenWSKind == .nio)
        // 但 learnedPonteHost 应该被记下来——为了下次 reconcile 时不要再从头探（学到的值）
        #expect(d.learnedPonteHost == "mbp.sgponte")
    }

    @Test func manualPullURLUnreachableStillUsesIt() async {
        // 用户手抄 pull_url 失联——daemon 不该静默回 tailscale，应继续用手抄值让
        // PullWorker 自然失败 + 用户能看出问题。这是有意为之：manual = trump card
        let peer = makePeer(
            url: "https://mbp.tail.ts.net:8443",
            pullURL: "https://stale.sgponte:8443"
        )
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp-id", nowMs: 1000, ponteHost: "mbp.sgponte"), 120),
            "https://stale.sgponte:8443": (.unreachable(reason: "down"), -1),
            "https://mbp.sgponte:8443": (.ok(deviceID: "mbp-id", nowMs: 1002, ponteHost: nil), 50)
        ])
        let d = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe)
        // 手抄不可达 → 退到第二优先级（learned ponte），仍比 tailscale 优先
        #expect(d.chosenPullURL.host == "mbp.sgponte")
    }

    @Test func tailscaleHealthUnreachableButPonteCandidateReachable() async {
        // C1 (tailscale) 失败但能学到 ponte_host? 实际上学不到——/health 失败时
        // ponte_host 是 nil。所以这场景 → 没 ponte candidate → tailscale 兜底（仍 unreachable
        // 但 chosenPullURL 仍是 peer.url，PullWorker 自己再重试）
        let peer = makePeer(url: "https://mbp.tail.ts.net:8443")
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.unreachable(reason: "tailscale down"), -1)
        ])
        let d = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe)
        #expect(d.chosenPullURL.absoluteString == "https://mbp.tail.ts.net:8443")
        #expect(d.learnedPonteHost == nil)
        #expect(d.chosenWSKind == .nio)
    }

    @Test func transportLabelPonte() async {
        let peer = makePeer(url: "https://mbp.tail.ts.net:8443")
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp-id", nowMs: 1000, ponteHost: "mbp.sgponte"), 100),
            "https://mbp.sgponte:8443": (.ok(deviceID: "mbp-id", nowMs: 1001, ponteHost: nil), 50)
        ])
        let d = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe)
        #expect(d.transportLabel == "ponte (mbp.sgponte:8443)")
    }

    @Test func transportLabelTailscale() async {
        let peer = makePeer(url: "https://mbp.tail.ts.net:8443")
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp-id", nowMs: 1000, ponteHost: nil), 100)
        ])
        let d = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe)
        #expect(d.transportLabel == "tailscale (mbp.tail.ts.net:8443)")
    }

    @Test func multiPeerDiscover() async {
        // 两 peer 各自独立决策
        let smart = SmartTransport()
        let peers = [
            makePeer(url: "https://mbp.tail.ts.net:8443"),
            makePeer(url: "https://mini.tail.ts.net:8443")
        ]
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp", nowMs: 1, ponteHost: "mbp.sgponte"), 90),
            "https://mbp.sgponte:8443": (.ok(deviceID: "mbp", nowMs: 2, ponteHost: nil), 30),
            "https://mini.tail.ts.net:8443": (.ok(deviceID: "mini", nowMs: 3, ponteHost: nil), 80)
        ])
        let decisions = await smart.discover(
            peers: peers,
            auth: HMACAuth(secret: Data(repeating: 0xFF, count: 32)),
            tailscaleSession: .shared,
            probe: probe
        )
        #expect(decisions.count == 2)
        #expect(decisions[0].peerIndex == 0)
        #expect(decisions[0].chosenWSKind == .urlSession)
        #expect(decisions[1].peerIndex == 1)
        #expect(decisions[1].chosenWSKind == .nio)
    }
}

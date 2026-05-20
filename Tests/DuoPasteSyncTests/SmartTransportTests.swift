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

    // MARK: - B1: probeWithRetry

    /// 可脚本化 probe:第 N 次调返回 modes[min(N, modes.count-1)]。计数用 actor 安全
    private actor SequentialProbe {
        private let modes: [(PrimaryHealthResult.Outcome, Int64)]
        private(set) var calls: Int = 0
        init(_ modes: [(PrimaryHealthResult.Outcome, Int64)]) { self.modes = modes }
        func next() -> (PrimaryHealthResult.Outcome, Int64) {
            let idx = min(calls, modes.count - 1)
            calls += 1
            return modes[idx]
        }
    }

    @Test func probeWithRetryNoRetryOnOK() async {
        let url = URL(string: "https://x:8443")!
        let seq = SequentialProbe([
            (.ok(deviceID: "d", nowMs: 1, ponteHost: nil), 50)
        ])
        let probe: SmartTransport.HealthProbe = { _ in await seq.next() }
        let r = await SmartTransport.probeWithRetry(probe, url: url, retries: 1, backoffSec: 0.01)
        #expect(r.rttMs == 50)
        if case .ok = r.outcome {} else { Issue.record("expected .ok") }
        #expect(await seq.calls == 1)  // 不 retry
    }

    @Test func probeWithRetryRetriesOnUnreachable() async {
        let url = URL(string: "https://x:8443")!
        let seq = SequentialProbe([
            (.unreachable(reason: "first try fail"), -1),
            (.ok(deviceID: "d", nowMs: 2, ponteHost: nil), 80)  // 第二次成功
        ])
        let probe: SmartTransport.HealthProbe = { _ in await seq.next() }
        let r = await SmartTransport.probeWithRetry(probe, url: url, retries: 1, backoffSec: 0.01)
        #expect(r.rttMs == 80)
        if case .ok = r.outcome {} else { Issue.record("expected .ok after retry") }
        #expect(await seq.calls == 2)  // 失败+重试 = 2 次
    }

    @Test func probeWithRetryGivesUpAfterAllRetriesFail() async {
        let url = URL(string: "https://x:8443")!
        let seq = SequentialProbe([
            (.unreachable(reason: "always fail"), -1)
        ])
        let probe: SmartTransport.HealthProbe = { _ in await seq.next() }
        let r = await SmartTransport.probeWithRetry(probe, url: url, retries: 2, backoffSec: 0.01)
        if case .unreachable = r.outcome {} else { Issue.record("expected .unreachable") }
        #expect(await seq.calls == 3)  // 初次 + retries=2 = 3 次
    }

    @Test func probeWithRetryDoesNotRetryRejected() async {
        let url = URL(string: "https://x:8443")!
        let seq = SequentialProbe([
            (.rejected(reason: "401 hmac fail"), 30)
        ])
        let probe: SmartTransport.HealthProbe = { _ in await seq.next() }
        let r = await SmartTransport.probeWithRetry(probe, url: url, retries: 2, backoffSec: 0.01)
        if case .rejected = r.outcome {} else { Issue.record("expected .rejected") }
        #expect(await seq.calls == 1)  // .rejected 立即返回不 retry
    }

    // MARK: - candidate-level probe logging

    /// 线程安全 capture——@Sendable closure 内调 `append` 走 NSLock,主线程 / probe task /
    /// 其他并发上下文都能写。
    ///
    /// `lines` getter **显式拷贝**而不是直接 `return _lines + defer unlock`——后者依赖
    /// Swift ARC + Array COW + defer 时序的精确保证,显式拷让锁释放时机自描述,future
    /// reader 不必推理"return 表达式跟 defer unlock 谁先发生"
    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        func append(_ s: String) { lock.lock(); defer { lock.unlock() }; _lines.append(s) }
        var lines: [String] {
            lock.lock()
            let copy = _lines
            lock.unlock()
            return copy
        }
    }

    @Test func probeWithRetryLogsEveryAttempt() async {
        let cap = LogCapture()
        let url = URL(string: "https://x.tail.ts.net:8443")!
        let seq = SequentialProbe([
            (.unreachable(reason: "first try fail"), -1),
            (.ok(deviceID: "dev-x", nowMs: 1, ponteHost: "x.sgponte"), 50)
        ])
        let probe: SmartTransport.HealthProbe = { _ in await seq.next() }
        let logger: SmartTransport.ProbeLogger = { cap.append($0) }
        _ = await SmartTransport.probeWithRetry(
            probe, url: url, retries: 1, backoffSec: 0.01,
            peerIndex: 0, candidate: "tailscale", logger: logger
        )
        let lines = cap.lines
        #expect(lines.count == 2, "每次 attempt 都该打一行,实际 \(lines.count): \(lines)")
        // 第一次失败行应含 reason + attempt=1/2
        #expect(lines[0].contains("probe=unreachable"))
        #expect(lines[0].contains("reason=\"first try fail\""))
        #expect(lines[0].contains("attempt=1/2"))
        #expect(lines[0].contains("candidate=tailscale"))
        #expect(lines[0].contains("peer 0"))
        // 第二次成功行应含 device_id + ponte_host + rtt
        #expect(lines[1].contains("probe=ok"))
        #expect(lines[1].contains("rtt=50ms"))
        #expect(lines[1].contains("device_id=dev-x"))
        #expect(lines[1].contains("ponte_host=x.sgponte"))
        #expect(lines[1].contains("attempt=2/2"))
    }

    @Test func probeWithRetryNoAttemptSuffixWhenNoRetry() async {
        // retries=0 时 total=1,日志不该出现 attempt= 字段(只有一次,没必要)
        let cap = LogCapture()
        let url = URL(string: "https://x:8443")!
        let seq = SequentialProbe([(.ok(deviceID: "d", nowMs: 1, ponteHost: nil), 30)])
        let probe: SmartTransport.HealthProbe = { _ in await seq.next() }
        let logger: SmartTransport.ProbeLogger = { cap.append($0) }
        _ = await SmartTransport.probeWithRetry(
            probe, url: url, retries: 0, backoffSec: 0.01, logger: logger
        )
        let lines = cap.lines
        #expect(lines.count == 1)
        #expect(!lines[0].contains("attempt="), "single-attempt 不该带 attempt= 字段")
    }

    @Test func decideOneLogsAllCandidates() async {
        // 完整决策路径:tailscale OK + 学到 ponte_host + ponte probe OK
        // → 应该打 2 条日志(C1 tailscale + C3 ponte),不重复 probe C1
        let cap = LogCapture()
        let peer = makePeer(url: "https://mbp.tail.ts.net:8443")
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp", nowMs: 1, ponteHost: "mbp.sgponte"), 90),
            "https://mbp.sgponte:8443": (.ok(deviceID: "mbp", nowMs: 2, ponteHost: nil), 30)
        ])
        let logger: SmartTransport.ProbeLogger = { cap.append($0) }
        _ = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe, logger: logger)
        let lines = cap.lines
        #expect(lines.count == 2, "应有 2 条:tailscale + ponte;实际:\(lines)")
        #expect(lines.contains { $0.contains("candidate=tailscale") })
        #expect(lines.contains { $0.contains("candidate=ponte") })
    }

    @Test func decideOneLogsPonteFailureReason() async {
        // ponte unreachable 时日志必须含 reason 字段——这是修复诊断盲点的核心契约。
        // 不硬编码 retry 次数(跟 probeWithRetry 默认 retries 解耦),验证"每次 attempt 都
        // 打 unreachable + 携带 reason"
        let cap = LogCapture()
        let peer = makePeer(url: "https://mbp.tail.ts.net:8443")
        let probe = makeFakeProbe(responses: [
            "https://mbp.tail.ts.net:8443": (.ok(deviceID: "mbp", nowMs: 1, ponteHost: "mbp.sgponte"), 90),
            "https://mbp.sgponte:8443": (.unreachable(reason: "transport: bad URL"), -1)
        ])
        let logger: SmartTransport.ProbeLogger = { cap.append($0) }
        _ = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe, logger: logger)
        let lines = cap.lines
        let ponteLines = lines.filter { $0.contains("candidate=ponte") }
        #expect(ponteLines.count >= 1, "至少打一条 ponte probe log")
        // 关键契约:每条 ponte log 都含 unreachable + 完整 reason 字符串
        for line in ponteLines {
            #expect(line.contains("probe=unreachable"))
            #expect(line.contains("reason=\"transport: bad URL\""))
        }
    }

    @Test func formatProbeLogHandlesReasonWithSpecialChars() async {
        // reason 含双引号 / 换行 / 回车 / tab → 单行 log 必须把它们 escape/折,不撕裂字段
        let url = URL(string: "https://x:8443")!
        let line = SmartTransport.formatProbeLog(
            peerIndex: 0, candidate: "ponte", url: url,
            attempt: 1, total: 2,
            outcome: .unreachable(reason: "broken \"quote\"\nand\rnewline\twith\ttab"),
            rttMs: -1
        )
        // 不该有原生换行 / 回车 / tab
        #expect(!line.contains("\n"))
        #expect(!line.contains("\r"))
        #expect(!line.contains("\t"))
        // 双引号被替换成单引号
        #expect(line.contains("reason=\"broken 'quote' and newline with tab\""))
    }

    @Test func discoverWarnsWhenAllCandidatesUnreachable() async {
        // Step 3 兜底:所有 peer 全部 candidate unreachable 时打 WARN
        let cap = LogCapture()
        let smart = SmartTransport()
        let peers = [
            makePeer(url: "https://a.tail.ts.net:8443"),
            makePeer(url: "https://b.tail.ts.net:8443")
        ]
        let probe = makeFakeProbe(responses: [:])  // 全部 unreachable
        let logger: SmartTransport.ProbeLogger = { cap.append($0) }
        _ = await smart.discover(
            peers: peers,
            auth: HMACAuth(secret: Data(repeating: 0xFF, count: 32)),
            tailscaleSession: .shared,
            probe: probe,
            logger: logger
        )
        let warnLines = cap.lines.filter { $0.contains("WARN") }
        #expect(warnLines.count == 1, "应该有且仅一条 WARN,实际:\(warnLines)")
        #expect(warnLines[0].contains("all candidates unreachable"))
        #expect(warnLines[0].contains("2 peer(s)"))
    }

    @Test func discoverDoesNotWarnWhenAtLeastOneCandidateReachable() async {
        // 至少一条 candidate reachable → 不打 WARN
        let cap = LogCapture()
        let smart = SmartTransport()
        let peers = [makePeer(url: "https://a.tail.ts.net:8443")]
        let probe = makeFakeProbe(responses: [
            "https://a.tail.ts.net:8443": (.ok(deviceID: "a", nowMs: 1, ponteHost: nil), 50)
        ])
        let logger: SmartTransport.ProbeLogger = { cap.append($0) }
        _ = await smart.discover(
            peers: peers,
            auth: HMACAuth(secret: Data(repeating: 0xFF, count: 32)),
            tailscaleSession: .shared,
            probe: probe,
            logger: logger
        )
        let warnLines = cap.lines.filter { $0.contains("WARN") }
        #expect(warnLines.isEmpty, "有可达 candidate 不该打 WARN,实际:\(warnLines)")
    }

    @Test func discoverDoesNotWarnWhenNoPeersConfigured() async {
        // 空 peers config(standalone 模式)不打 WARN——这是合法配置不是异常
        let cap = LogCapture()
        let smart = SmartTransport()
        let logger: SmartTransport.ProbeLogger = { cap.append($0) }
        _ = await smart.discover(
            peers: [],
            auth: HMACAuth(secret: Data(repeating: 0xFF, count: 32)),
            tailscaleSession: .shared,
            probe: makeFakeProbe(responses: [:]),
            logger: logger
        )
        let warnLines = cap.lines.filter { $0.contains("WARN") }
        #expect(warnLines.isEmpty, "空 peers 不该打 WARN")
    }

    @Test func decideOnePonteRecoveredOnSecondTry() async {
        // 启动竞态典型场景:tailscale C1 第一次 fail 第二次 OK(顺带学到 ponte_host),
        // ponte C3 第一次 fail 第二次 OK → 最终选 ponte。这正是 B1 在真实环境想救的 case
        let peer = makePeer(url: "https://mbp.tail.ts.net:8443")
        // C1 调用2次(第一次 unreachable retry 后 OK),C3 调用2次,共4次
        let seq = SequentialProbe([
            (.unreachable(reason: "tailscale cold start"), -1),
            (.ok(deviceID: "mbp", nowMs: 1, ponteHost: "mbp.sgponte"), 100),
            (.unreachable(reason: "ponte cold start (Surge not ready)"), -1),
            (.ok(deviceID: "mbp", nowMs: 2, ponteHost: nil), 50),
        ])
        let probe: SmartTransport.HealthProbe = { _ in await seq.next() }
        let d = await SmartTransport.decideOne(peerIndex: 0, peer: peer, probe: probe)
        #expect(d.chosenPullURL.absoluteString == "https://mbp.sgponte:8443")
        #expect(d.chosenWSKind == .urlSession)
        #expect(d.learnedPonteHost == "mbp.sgponte")
    }
}

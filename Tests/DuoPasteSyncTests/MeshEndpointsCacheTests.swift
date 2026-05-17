import Testing
import Foundation
import DuoPasteCore
@testable import DuoPasteSync

/// MeshEndpointsCache 单元测试。用 DecisionsProvider + FetchProvider 注入 stub,
/// 避开 MeshSupervisor + 真 HTTP 让测试纯逻辑

private func makeDecision(index: Int, urlString: String) -> SmartTransport.PeerDecision {
    let url = URL(string: urlString)!
    return SmartTransport.PeerDecision(
        peerIndex: index,
        configuredURL: url,
        manualPullURL: nil,
        learnedPonteHost: nil,
        chosenPullURL: url,
        chosenWSURL: url,
        chosenWSKind: .nio,
        httpRttMs: [url: 50]
    )
}

private func makePage(deviceID: String, kinds: [PeerEndpoint.Kind] = [.tailscale]) -> PeerEndpointsPage {
    let eps = kinds.enumerated().map { (i, k) in
        PeerEndpoint(url: "https://\(deviceID)-\(i).example:8443", kind: k, preferred: i == 0)
    }
    return PeerEndpointsPage(deviceID: deviceID, endpoints: eps, updatedAtUnix: 100, meshPeers: nil)
}

@Suite struct MeshEndpointsCacheTests {
    @Test func snapshotEmptyWhenNoDecisions() async {
        let cache = MeshEndpointsCache(
            selfDeviceID: "self",
            decisionsProvider: { [] },
            fetchProvider: { _ in .success(makePage(deviceID: "other")) }
        )
        await cache.refreshNow()
        let snap = await cache.snapshot()
        #expect(snap.isEmpty)
    }

    @Test func snapshotIncludesFetchedPeersSortedByDeviceID() async {
        let decisions = [
            makeDecision(index: 0, urlString: "https://a.example:8443"),
            makeDecision(index: 1, urlString: "https://b.example:8443"),
        ]
        let cache = MeshEndpointsCache(
            selfDeviceID: "self",
            decisionsProvider: { decisions },
            fetchProvider: { url in
                if url.host == "a.example" {
                    return .success(makePage(deviceID: "peer-A"))
                } else {
                    return .success(makePage(deviceID: "peer-B"))
                }
            }
        )
        await cache.refreshNow()
        let snap = await cache.snapshot()
        #expect(snap.count == 2)
        // 排序按 peerDeviceID 字典序
        #expect(snap[0].peerDeviceID == "peer-A")
        #expect(snap[1].peerDeviceID == "peer-B")
        #expect(snap.allSatisfy { $0.healthy })
    }

    @Test func skipsSelfDeviceID() async {
        // peer 返回的 device_id == selfDeviceID → 跳过(防止自己 fetch 自己进 entries)
        let cache = MeshEndpointsCache(
            selfDeviceID: "self",
            decisionsProvider: { [makeDecision(index: 0, urlString: "https://x.example:8443")] },
            fetchProvider: { _ in .success(makePage(deviceID: "self")) }
        )
        await cache.refreshNow()
        #expect(await cache.snapshot().isEmpty)
    }

    /// 共享 mutable state 在测试里走 actor 安全跨 closure / TaskGroup
    private actor IntBox {
        private var n = 0
        func incrementAndGet() -> Int { n += 1; return n }
        func get() -> Int { n }
    }
    private actor PageBox {
        private var page: PeerEndpointsPage
        init(_ p: PeerEndpointsPage) { self.page = p }
        func set(_ p: PeerEndpointsPage) { self.page = p }
        func get() -> PeerEndpointsPage { page }
    }

    @Test func failedFetchKeepsLastGoodEndpointsButMarksUnhealthy() async {
        // 首次成功 → 接下来失败 → entry 应保留 endpoints 但 healthy=false
        let counter = IntBox()
        let cache = MeshEndpointsCache(
            selfDeviceID: "self",
            decisionsProvider: { [makeDecision(index: 0, urlString: "https://p.example:8443")] },
            fetchProvider: { _ in
                let c = await counter.incrementAndGet()
                if c == 1 {
                    return .success(makePage(deviceID: "peer-X", kinds: [.tailscale, .local]))
                } else {
                    return .failure(MeshEndpointsCache.FetchError("network down"))
                }
            }
        )
        await cache.refreshNow()
        var snap = await cache.snapshot()
        #expect(snap.count == 1)
        #expect(snap[0].healthy == true)
        let originalEps = snap[0].endpoints

        await cache.refreshNow()
        snap = await cache.snapshot()
        #expect(snap.count == 1)
        #expect(snap[0].healthy == false)
        #expect(snap[0].endpoints == originalEps)
    }

    @Test func snapshotChangeFiresCallback() async {
        let fired = IntBox()
        let onChange: @Sendable (Int64) -> Void = { _ in
            Task { _ = await fired.incrementAndGet() }
        }
        let pageBox = PageBox(makePage(deviceID: "peer-A"))
        let cache = MeshEndpointsCache(
            selfDeviceID: "self",
            decisionsProvider: { [makeDecision(index: 0, urlString: "https://a.example:8443")] },
            fetchProvider: { _ in
                .success(await pageBox.get())
            },
            onSnapshotChanged: onChange
        )
        await cache.refreshNow()
        // onChange 是 fire-and-forget Task,等一下让它跑完
        try? await Task.sleep(nanoseconds: 50_000_000)
        let firstFire = await fired.get()
        #expect(firstFire == 1)

        // 再 refresh 但 page 一样 → snapshot 没 diff → callback 不再 fire
        await cache.refreshNow()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let secondFire = await fired.get()
        #expect(secondFire == 1)

        // 换 endpoints → fire 一次
        await pageBox.set(makePage(deviceID: "peer-A", kinds: [.tailscale, .ponte]))
        await cache.refreshNow()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let thirdFire = await fired.get()
        #expect(thirdFire == 2)
    }

    @Test func stalePurgeAfterStaleAfterSec() async {
        // staleAfterSec 是 Int64 seconds 截断,精度只到 1s。用 1s 测,睡 2s 防边界
        let cache = MeshEndpointsCache(
            selfDeviceID: "self",
            decisionsProvider: { [makeDecision(index: 0, urlString: "https://a.example:8443")] },
            fetchProvider: { _ in .success(makePage(deviceID: "peer-A")) },
            config: MeshEndpointsCache.Config(refreshIntervalSec: 60, staleAfterSec: 1, fetchTimeoutSec: 5)
        )
        await cache.refreshNow()
        #expect(await cache.snapshot().count == 1)
        try? await Task.sleep(nanoseconds: 2_100_000_000) // 2.1s > 1s
        #expect(await cache.snapshot().isEmpty)
    }
}

import Foundation
import Testing
@testable import DuoPasteCore

/// `AppState` / `SearchView` 住在 duo-pasted 可执行 target(`@MainActor` + AppKit),
/// SwiftPM 测试拉不起来,所以沿用 `IOSOptimisticReconcileWiringTests` 的做法直接对源码断言。
///
/// 背景:搜索后 query / results / 滚动位置都会跨 panel 复用持久化。新增的两个出口
/// (左侧「回到开头」箭头 + 卡片右键「在完整列表中显示」)都要先清空 query 再定位,
/// 而清 query 只是**异步**触发 `SearchView.task(id: filterID)` 重搜——清完那一刻
/// `state.results` 还是被过滤的旧数组。若在同一 tick 直接 `scrollPulse &+= 1`,
/// scrollTo 锚的是一个马上就要从列表里消失的 id,表现为"点了没反应 / 滚到别处"。
/// 所以意图必须记进 `pendingFocus`,由新结果落地时的 `applySearchOutcome` 消费。
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func source(_ relativePath: String) throws -> String {
    try String(
        contentsOf: repositoryRoot().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

@Test func revealDefersFocusUntilFullResultsLand() throws {
    let appState = try source("Sources/duo-pasted/AppState.swift")

    #expect(
        appState.contains("func scrollToStart()"),
        "左侧箭头的 AppState 入口 scrollToStart() 不见了"
    )
    #expect(
        appState.contains("func revealInFullList(_ item: Item)"),
        "右键「在完整列表中显示」的 AppState 入口 revealInFullList(_:) 不见了"
    )

    // applySearchOutcome 是发布搜索结果的唯一入口;pendingFocus 必须在这里消费,
    // 且排在 updateSelection 之后——updateSelection 的 "kept 优先" 会保住旧选中项,
    // 先消费 pendingFocus 会被它盖掉
    guard let applyRange = appState.range(of: "private func applySearchOutcome(") else {
        Issue.record("applySearchOutcome 不见了")
        return
    }
    let body = String(appState[applyRange.lowerBound...].prefix(2000))
    guard let updateIdx = body.range(of: "updateSelection(forItems:"),
          let pendingIdx = body.range(of: "applyPendingFocus(items:") else {
        Issue.record("applySearchOutcome 里没有同时调用 updateSelection 和 applyPendingFocus")
        return
    }
    #expect(
        updateIdx.lowerBound < pendingIdx.lowerBound,
        "applyPendingFocus 必须排在 updateSelection 之后,否则 kept 优先策略会盖掉定位目标"
    )
}

@Test func revealDoesNotScrollSynchronously() throws {
    let appState = try source("Sources/duo-pasted/AppState.swift")

    guard let range = appState.range(of: "func revealInFullList(_ item: Item)") else {
        Issue.record("revealInFullList 不见了")
        return
    }
    let body = String(appState[range.lowerBound...].prefix(1800))
    #expect(
        body.contains("pendingRevealID ="),
        "revealInFullList 没有记录 pendingRevealID —— 清空 query 后的定位意图会丢"
    )
    #expect(
        body.contains("query = \"\""),
        "revealInFullList 没有清空搜索框"
    )
}

/// 定位**必须**走"前后各 N 条"的窗口,不能靠把 listLimit 调大或去掉。
/// 本机真实库实测(29,593 条 live item / 22,523 条 fold 行):
///   - 空查询 refresh: limit=200 → 7.9ms, 无界 → 717ms(每条约 33µs 线性)
///   - 定位最老一条: 位次查询 2.9ms + 401 条窗口 12.9ms ≈ 16ms,且跟深度无关
/// 无界那条路还要再加 2.2 万个 LazyHStack cell 的 main-thread reconciliation。
@Test func revealUsesBoundedWindowNotAnUnboundedList() throws {
    let appState = try source("Sources/duo-pasted/AppState.swift")

    #expect(
        appState.contains("static let listLimit = 200"),
        "listLimit 被改动了 —— 常态列表放大会线性拖慢每一次 refresh,定位请走窗口"
    )
    #expect(appState.contains("static let revealWindowRadius"), "定位窗口半径常量不见了")
    #expect(
        appState.contains("foldPosition(ofItemID:"),
        "revealInFullList 没有查位次 —— 没有位次就只能从最新一条一路拉到目标"
    )
    // 窗口自我作废:指纹对不上就丢弃,不需要在每个 chip toggle 上手动清
    #expect(
        appState.contains("window.filterID != filterID"),
        "定位窗口没有按 filterID 自我作废 —— 用户改筛选后列表会停在错误的窗口里"
    )
}

/// 清空 query 会先触发一轮**默认**视图的 refresh,它跟算位次的 detached task 并发。
/// 默认那轮很可能在窗口装好之后才落地(`listWindow != nil` 但 items 是最新 200 条),
/// 若拿当时的 `listWindow` 当判据就会误报"不在列表范围内"并把意图清掉——列表跳过去了
/// 却没有卡被选中。判据必须是"**这一份 results** 是不是窗口查出来的"。
@Test func pendingFocusJudgesTheOutcomeNotTheCurrentWindow() throws {
    let appState = try source("Sources/duo-pasted/AppState.swift")

    #expect(
        appState.contains("applyPendingFocus(items: outcome.items, fromRevealWindow: fromRevealWindow)"),
        "applyPendingFocus 没有接收 outcome 自身的窗口归属"
    )
    guard let range = appState.range(of: "private func applyPendingFocus(") else {
        Issue.record("applyPendingFocus 不见了")
        return
    }
    let body = String(appState[range.lowerBound...].prefix(900))
    #expect(
        !body.contains("listWindow"),
        "applyPendingFocus 又去读当时的 listWindow 了 —— 并发落地时会误报并吞掉定位意图"
    )
}

/// 窗口是一次性定位状态,不能跨 panel 生命周期粘着——否则用户下次打开面板看到的是
/// 三周前那一段,而且没有显而易见的回到最新的路。重开面板是窗口模式唯一的退出口。
@Test func panelShowResetsRevealWindow() throws {
    let controller = try source("Sources/duo-pasted/SearchPanelController.swift")
    #expect(
        controller.contains("state.resetListWindow()"),
        "panel show 没有重置定位窗口 —— 用户会被永久困在三周前那一段列表里"
    )
}

/// 左侧箭头是**纯滚动控件**。user 明确要求:"左键不要丢失条件，这只是移动到最左，
/// 如果你添加太多语义，会很糟糕"。所以 scrollToStart 只许 bump 自己的 pulse——
/// 不清 query、不改 selectedIDs / anchorID、不动 chip。
@Test func scrollToStartCarriesNoFilterSemantics() throws {
    let appState = try source("Sources/duo-pasted/AppState.swift")

    guard let range = appState.range(of: "func scrollToStart()") else {
        Issue.record("scrollToStart 不见了")
        return
    }
    let body = String(appState[range.lowerBound...].prefix(300))
    guard let end = body.range(of: "\n    }") else {
        Issue.record("scrollToStart 函数体解析失败")
        return
    }
    let fn = String(body[..<end.upperBound])

    #expect(fn.contains("scrollToStartPulse &+= 1"), "scrollToStart 没有 bump pulse")
    for forbidden in ["query = \"\"", "selectedIDs =", "anchorID =", "selectedKinds", "timeRange"] {
        #expect(!fn.contains(forbidden), "左侧箭头不许带筛选/选中语义,但函数体里出现了 \(forbidden)")
    }
    // scrollPulse 锚的是 selectedIDs.last,选中项不在开头时会滚到别处
    #expect(
        !fn.contains("scrollPulse &+= 1"),
        "scrollToStart 不能复用 scrollPulse —— 那条路锚 selectedIDs.last 而不是列表开头"
    )
}

@Test func searchViewWiresJumpToStartArrowAndRevealMenuItem() throws {
    let view = try source("Sources/duo-pasted/SearchView.swift")

    #expect(
        view.contains("state.scrollToStart()"),
        "SearchView 没有接上左侧箭头"
    )
    #expect(
        view.contains("state.revealInFullList(item)"),
        "卡片右键菜单没有接上「在完整列表中显示」"
    )
    // 箭头必须占独立 slot(HStack),不能改回 overlay —— overlay 会盖住第一张卡
    // offset(-9,-9) 的 source icon 并抢它的 hit-test
    #expect(
        view.contains("private var cardScrollerRow: some View"),
        "cardScrollerRow 不见了 —— 箭头别改回 overlay 盖在第一张卡上"
    )
}

/// 滚到列表开头必须锚开头那个 spacer,不能锚第一张卡本身:卡的 source icon 是
/// offset(-9,-9) 溢出到 frame 之外的,anchor .leading 把卡贴到视口左缘会切掉 icon。
@Test func scrollToStartAnchorsSpacerNotFirstCard() throws {
    let view = try source("Sources/duo-pasted/SearchView.swift")

    #expect(view.contains(".id(Self.startAnchorID)"), "开头的 scrollTo 锚点 spacer 不见了")
    #expect(
        view.contains("proxy.scrollTo(Self.startAnchorID, anchor: .leading)"),
        "没有任何路径锚到 startAnchorID"
    )
    // 容器 leading padding 挂不上 .id,所以 16pt slack 必须由 spacer 提供
    // (匹配行首缩进,避开正文里解释这段历史的注释)
    #expect(
        !view.contains("\n                .padding(.leading, 16)"),
        "leading slack 回退成容器 padding 了 —— scrollTo 锚不到它,第一张卡 icon 会被 clip"
    )
}

/// 高亮框必须跟卡片同帧出现。LazyHStack cell pool 把旧 cell 复用给新 item 时,
/// isSelected 上的隐式动画会被当成"同一视图的属性变化"播过渡 —— 表现为
/// "搜索后 card 已经出来,高亮框慢一点才飞过来"。
@Test func selectionBorderHasNoImplicitAnimation() throws {
    let view = try source("Sources/duo-pasted/SearchView.swift")

    // 只约束 ItemCard —— chip 上的 isSelected 动画是真实的同一视图状态变化,该留
    guard let cardRange = view.range(of: "private struct ItemCard") else {
        Issue.record("ItemCard 不见了")
        return
    }
    // 去掉注释行——正文里解释这段历史时会原样引用那行代码
    let card = view[cardRange.lowerBound...]
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    #expect(
        !card.contains("value: isSelected)"),
        "ItemCard 重新挂上了 .animation(value: isSelected) —— 高亮框会滞后于卡片飞过来"
    )
}

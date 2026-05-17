import Foundation
import UIKit
import Observation
import QuartzCore

/// 分享走 UIKit 直接 present UIActivityViewController,不套 SwiftUI `.sheet`。
///
/// 为什么不用 `ShareLink`:
/// - ShareLink Transferable 在 contextMenu 展开就被反复 evaluate,首次成本 500ms+
///
/// 为什么不套 SwiftUI `.sheet`:
/// - SwiftUI sheet 强制 page-sheet 全屏挂载 + 入场动画排队,首次体感慢
/// - 需要 180ms 人为延迟等 contextMenu dismiss,否则 sheet 渲染异常
/// - 直接 UIKit present 走系统原生 UIActivityViewController card style(iPhone)/
///   popover (iPad),无延迟、无 SwiftUI 动画开销
@Observable
@MainActor
final class ShareCoordinator {
    func share(_ items: [Any]) {
        UILatencyLog.mark("share coordinator present begin", "items=\(Self.describe(items))")
        let start = CACurrentMediaTime()
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { activityType, completed, _, error in
            let activity = activityType?.rawValue ?? "nil"
            let errorText = error?.localizedDescription ?? "nil"
            UILatencyLog.mark(
                "share completion",
                "activity=\(activity) completed=\(completed) error=\(errorText)"
            )
        }
        guard let presenter = Self.topPresenter() else {
            UILatencyLog.mark("share no presenter")
            return
        }
        // iPad popover anchor — 缺 sourceView 会崩
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.maxY - 20,
                width: 1, height: 1
            )
            pop.permittedArrowDirections = []
        }
        // 下一 runloop 兜底 contextMenu dismiss 收尾(0ms,非 sleep)
        DispatchQueue.main.async {
            presenter.present(vc, animated: true) {
                UILatencyLog.mark(
                    "share present complete",
                    "elapsed_ms=\(UILatencyLog.elapsedMS(since: start))"
                )
            }
        }
    }

    private static func topPresenter() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: \.isKeyWindow),
              let root = window.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private static func describe(_ items: [Any]) -> String {
        items.map { String(describing: type(of: $0)) }.joined(separator: ",")
    }
}

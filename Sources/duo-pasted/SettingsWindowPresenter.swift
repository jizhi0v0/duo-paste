import AppKit
import SwiftUI

/// Owns the single Settings window for the lifetime of the daemon.
///
/// DuoPaste is an `.accessory` app (`LSUIElement=1`, and `AppDelegate` sets `.accessory` at
/// launch). A SwiftUI `Settings` scene can report that `showSettingsWindow:` was handled without
/// ever materializing an `NSWindow` while another app is active. Owning the AppKit window removes
/// that responder-chain race and lets us move a previously closed window onto the user's current
/// Space before raising it.
///
/// ## Why there is no activation-policy dance here
///
/// This used to promote the app to `.regular` before showing, poll up to 20 times for
/// `NSApp.isActive && window.isKeyWindow`, fall back to `window.level = .floating`, and restore
/// `.accessory` on close. That whole apparatus existed to work around one wrong call, and it *was*
/// the bug users saw ("设置窗口闪一下就消失" + the menu bar jumping): the promotion inserts a Dock
/// icon and an app menu (which shifts the menu-bar extras), and the give-up path called
/// `setActivationPolicy(.accessory)`, which hides the very window it had just shown.
///
/// The actual rule, from AppKit's own header for `NSApplicationActivationPolicyAccessory`:
/// "The application does not appear in the Dock and does not have a menu bar, *but it may be
/// activated programmatically or by clicking on one of its windows*." An accessory app can hold a
/// key window; it never needed to be `.regular`. What it needs is the right activation call:
///
/// - `NSApp.activate()` is **cooperative** — "does not guarantee that the app will be activated at
///   all"; the currently-active app is expected to `yieldActivation(to:)` first, which no other app
///   does for us. The old retry loop was fighting that documented non-guarantee, and losing.
/// - `activate(ignoringOtherApps: true)` "activates regardless", which is what a user-invoked
///   Settings window wants.
///
/// So: stay `.accessory` forever, activate once, order front, done. `ignoringOtherApps:` is marked
/// "will be deprecated in a future release" in favour of `activate()`; when that lands, re-measure
/// rather than swap it blindly — a cooperative `activate()` that gets refused leaves this window
/// unfocused behind whatever the user was doing.
///
/// Caveat on measuring any of this: focus is global state. Driving Settings open from a script
/// while another app (Terminal, an editor) holds focus contaminates `key`/`isActive` readings — it
/// produced flatly contradictory numbers here. Judge focus by opening it by hand, or by looking at
/// the titlebar, not by a scripted loop.
@MainActor
final class SettingsWindowPresenter: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?

    func show() {
        let controller = windowController ?? makeWindowController()
        guard let window = controller.window else { return }

        if !window.isVisible {
            fitAndCenterOnPointerScreen(window)
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        // A reused Settings window may belong to the Space on which it was last closed.
        // `orderFrontRegardless` cannot cross Spaces by itself.
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.unhide(nil)
        // `ignoringOtherApps: true` on purpose — see the class comment. Cooperative `activate()`
        // is refused here (nobody yields to us) and leaves the window unfocused. Runs
        // synchronously inside the status-item action so it keeps the originating user event.
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        nudgeActivationIfNeeded(window)
        logState(window)
    }

    private func makeWindowController() -> NSWindowController {
        // `.fullSizeContentView` is what makes NavigationSplitView's sidebar render as a
        // *real* sidebar: full window height with the traffic lights sitting on it, and the
        // system's vibrant sidebar material. Without it the content area starts below an
        // opaque titlebar band and the sidebar renders as a plain flat List in the lower
        // portion — visibly not a macOS sidebar.
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        // Pass the final style mask at construction time. `NSWindow(contentViewController:)`
        // performs an initial hosting layout before a later styleMask assignment; on macOS 26
        // that stale safe area can leave SwiftUI's content underneath the titlebar.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(rootView: SettingsView())
        // The window is the size authority; SwiftUI must never push a size back.
        //
        // The default is `.preferredContentSize`, which feeds the root view's ideal size into
        // AppKit. `SettingsView` grows on state change — clicking an OCR field adds the ApplyBar
        // *and* its multi-line half-consistency warning through `.safeAreaInset(edge: .bottom)`.
        // With the default, that taller ideal is laid out against a window that cannot grow, so
        // the hosting view overhangs its content rect. NSWindow's origin is bottom-left, so the
        // overhang goes *up*: the sidebar rows and the page header get clipped above the titlebar
        // and the window reads as having jumped upward. Empty options pin the hosting view to the
        // content rect and leave sizing to `fitAndCenterOnPointerScreen` and the user.
        //
        // Same AppKit push-back path that made the preview panel auto-grow to image pixel size
        // (see CLAUDE.md, "空格预览浮窗"); there the fix was to tear the pushing view out of the
        // subtree, here the controller exposes the switch directly.
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.title = "DuoPaste"
        // Transparent titlebar so the sidebar reads as one surface up to the top edge.
        //
        // **Be careful with `window.titleVisibility = .hidden`.** It looks tidier (the title
        // stops floating over the detail pane), but back when this class still promoted to
        // `.regular` and polled for `isActive`, adding that one line made the handshake fail
        // 3/3 instead of succeed 3/3 — which then tripped the fallback that hid the window.
        // The handshake is gone now, so it may well be harmless; it is left out because nobody
        // has re-measured it. If you want it, open Settings ~5 times and read `key=` in the
        // `settings: shown` log line before keeping it.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self

        let controller = NSWindowController(window: window)
        windowController = controller
        return controller
    }

    /// The **first** open after launch gets its activation refused: the agent has just been
    /// started by launchd and has never been active, so the window lands visible but unfocused
    /// (grey titlebar, grey selection). Every later open is fine, because by then the app has
    /// been active once. Re-asking a moment later is enough.
    ///
    /// Exactly one retry, and it can only ever *add* focus — it never touches the activation
    /// policy and never hides or re-levels the window. That distinction is the whole point: the
    /// old code retried 20 times and then "gave up" by hiding the window, which is what made
    /// Settings flash and vanish. If this nudge fails, the window simply stays unfocused and one
    /// click fixes it.
    private func nudgeActivationIfNeeded(_ window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak window] in
            guard let window, window.isVisible, !window.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === windowController?.window else { return }
        // Nothing to undo: the app never left `.accessory`. The retained controller keeps
        // SettingsView state alive for the next open.
        fputs("settings: closed\n", stderr)
    }

    /// Logged one turn of the runloop later: `makeKeyAndOrderFront` and `activate` both settle
    /// asynchronously, so reading `isKeyWindow` inline always under-reports.
    private func logState(_ window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            fputs(
                "settings: shown · policy=\(NSApp.activationPolicy() == .accessory ? "accessory" : "regular") · visible=\(window.isVisible) · key=\(window.isKeyWindow) · active=\(NSApp.isActive)\n",
                stderr
            )
        }
    }

    private func fitAndCenterOnPointerScreen(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
            ?? window.screen
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }

        // Keep a 16pt gutter around the complete frame. Convert the available frame to content
        // coordinates so the titlebar is included in the fit instead of pushing the tab strip
        // above the visible area. This matters on scaled/narrow displays (e.g. 712pt wide).
        let margin: CGFloat = 16
        let availableFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let availableContent = NSWindow.contentRect(
            forFrameRect: availableFrame,
            styleMask: window.styleMask
        )
        window.setContentSize(NSSize(
            width: min(760, availableContent.width),
            height: min(620, availableContent.height)
        ))

        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        ))
    }
}

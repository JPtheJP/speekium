import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats above other apps.
///
/// `.nonactivatingPanel` is essential: if the HUD took focus, the paste would
/// land in the HUD instead of the app the user was typing into.
///
/// The panel is deliberately a **fixed, oversized canvas** with the capsule
/// centred inside it. Resizing an NSWindow is not animatable in step with
/// SwiftUI's layout spring, so growing the window per partial made the capsule
/// visibly snap. With a fixed window, SwiftUI owns every transition.
final class HUDPanel: NSPanel {
    private static let canvasHeight: CGFloat = 190
    private static let bottomMargin: CGFloat = 120

    init(state: AppState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: Self.canvasHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let host = NSHostingView(rootView: HUDView(state: state))
        host.translatesAutoresizingMaskIntoConstraints = false
        // NSHostingView draws an opaque backing by default, which would show as
        // a square behind the rounded capsule.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Centres the canvas horizontally near the bottom of the active screen.
    /// Only needs calling when the HUD appears — the size never changes.
    func reposition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(900, visible.width - 80)
        // HUDView pads itself for the shadow; subtract it so the capsule still
        // reads as `bottomMargin` above the bottom of the screen.
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + Self.bottomMargin - HUDView.shadowInset,
            width: width,
            height: Self.canvasHeight
        )
        setFrame(frame, display: false)
    }

    func present() {
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Fades out, then runs `completion` — callers must not reset state before
    /// it fires or the HUD visibly reverts mid-fade.
    func dismiss(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        }
    }
}

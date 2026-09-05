import AppKit
import SwiftUI

enum FirstDictationCoachPolicy {
    static func shouldOffer(
        needsFirstDictationCoach: Bool,
        isDeveloperFirstRunSimulation: Bool
    ) -> Bool {
        needsFirstDictationCoach || isDeveloperFirstRunSimulation
    }

    static func shouldPresent(
        isQueued: Bool,
        isSpeechEngineReady: Bool,
        hasMicrophonePermission: Bool,
        hasAccessibilityPermission: Bool
    ) -> Bool {
        isQueued
            && isSpeechEngineReady
            && hasMicrophonePermission
            && hasAccessibilityPermission
    }
}

/// A short, non-activating invitation shown after first-run onboarding.
/// It never takes keyboard focus, so the user's first transcript can still be
/// inserted into whichever app and text field they choose.
@MainActor
final class FirstDictationCoachPanel: NSPanel {
    private static let panelSize = NSSize(width: 600, height: 150)
    private static let bottomMargin: CGFloat = 90

    init(shortcut: TriggerShortcut, mode: ActivationMode) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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

        let host = NSHostingView(rootView: FirstDictationCoachView(shortcut: shortcut, mode: mode))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + Self.bottomMargin
        ))

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        guard animated else {
            orderOut(nil)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        }
    }
}

struct FirstDictationCoachView: View {
    let shortcut: TriggerShortcut
    let mode: ActivationMode

    @State private var animating = false

    var body: some View {
        HStack(spacing: 16) {
            animatedKey

            VStack(alignment: .leading, spacing: 4) {
                Text("Try your first dictation")
                    .font(.system(size: 15.5, weight: .semibold, design: .rounded))

                Text(Self.instruction(shortcut: shortcut, mode: mode))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 386, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                // A translucent material can sample a bright webpage while
                // SwiftUI still supplies dark-mode (white) text, leaving the
                // coach almost unreadable. An opaque semantic surface keeps
                // text and background in the same appearance on every app.
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
                }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { animating = true }
        .accessibilityElement(children: .combine)
    }

    private var animatedKey: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                .frame(width: 108, height: 60)
                .scaleEffect(animating ? 1.14 : 0.96)
                .opacity(animating ? 0 : 0.75)

            Text(Self.keyName(shortcut))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.accentColor)
                .frame(width: 104, height: 56)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.2)
                        }
                }
                .scaleEffect(animating ? 0.96 : 1)
        }
        .frame(width: 118, height: 68)
        .animation(
            .easeInOut(duration: 0.82).repeatForever(autoreverses: true),
            value: animating
        )
    }

    static func instruction(shortcut: TriggerShortcut, mode: ActivationMode) -> String {
        switch mode {
        case .hold:
            return "Click in any text field, then hold \(keyName(shortcut)), speak, and release."
        case .tap:
            return "Click in any text field, tap \(keyName(shortcut)), speak, then tap it again."
        }
    }

    /// Kept as a small compatibility helper for existing copy tests and any
    /// callers that still construct a coach from a legacy preset.
    static func instruction(key: TriggerKey, mode: ActivationMode) -> String {
        instruction(shortcut: .modifierOnly(key), mode: mode)
    }

    private static func keyName(_ shortcut: TriggerShortcut) -> String {
        shortcut.compactDisplay
    }
}

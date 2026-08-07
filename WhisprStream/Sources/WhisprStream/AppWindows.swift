import AppKit
import SwiftUI

/// Creates and reuses the app's auxiliary windows.
///
/// The app runs as an `.accessory` (no Dock icon), so it must explicitly
/// activate itself when showing a window or the window appears behind whatever
/// the user was using and can't take keyboard input.
@MainActor
final class AppWindows {
    private var onboarding: NSWindow?
    private var settings: NSWindow?
    private var about: NSWindow?

    // MARK: - Onboarding

    func showOnboarding(
        settings appSettings: Settings,
        runtime: RuntimeManager,
        onFinish: @escaping () -> Void
    ) {
        if let onboarding {
            present(onboarding)
            return
        }
        let window = makeWindow(
            title: "Welcome to WhisprStream",
            styleMask: [.titled, .closable, .fullSizeContentView]
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        let view = OnboardingView(settings: appSettings, runtime: runtime) { [weak self] in
            onFinish()
            self?.onboarding?.close()
            self?.onboarding = nil
        }
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(NSSize(width: 580, height: 620))
        onboarding = window
        present(window)
    }

    // MARK: - Settings

    func showSettings(_ appSettings: Settings, runtime: RuntimeManager) {
        if let settings {
            present(settings)
            return
        }
        let window = makeWindow(title: "Settings", styleMask: [.titled, .closable])
        let host = NSHostingView(rootView: SettingsView(settings: appSettings, runtime: runtime))
        window.contentView = host
        // Let the tabbed form declare its own size rather than forcing one —
        // a hard-coded height is what clipped the last section before.
        window.setContentSize(host.fittingSize)
        settings = window
        present(window)
    }

    // MARK: - About

    func showAbout() {
        if let about {
            present(about)
            return
        }
        let window = makeWindow(
            title: "About WhisprStream",
            styleMask: [.titled, .closable, .fullSizeContentView]
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: AboutView())
        window.setContentSize(NSSize(width: 380, height: 350))
        about = window
        present(window)
    }

    // MARK: - Plumbing

    private func makeWindow(title: String, styleMask: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

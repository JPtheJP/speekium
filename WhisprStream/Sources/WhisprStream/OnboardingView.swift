import AVFoundation
import SwiftUI

/// First-run guided setup: welcome, the two permissions, preferences, done.
///
/// Permission state is polled rather than pushed — macOS has no callback for
/// Accessibility — so a card flips to "granted" on its own moments after the
/// user flicks the switch in System Settings, without them coming back here.
struct OnboardingView: View {
    @ObservedObject var settings: Settings
    @StateObject private var permissions = Permissions()

    @State private var step: Step = .welcome
    @State private var direction: CGFloat = 1

    var onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, preferences, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Group {
                switch step {
                case .welcome: welcome
                case .microphone: microphoneStep
                case .accessibility: accessibilityStep
                case .preferences: preferencesStep
                case .ready: readyStep
                }
            }
            .transition(slide)
            .frame(maxWidth: 460)

            Spacer(minLength: 0)

            footer
        }
        .frame(width: 580, height: 620)
        .background(.regularMaterial)
        .onAppear { permissions.beginPolling() }
        .onDisappear { permissions.endPolling() }
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .offset(x: 40 * direction).combined(with: .opacity),
            removal: .offset(x: -40 * direction).combined(with: .opacity)
        )
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            AnimatedMark()
                .frame(width: 96, height: 96)

            VStack(spacing: 10) {
                Text("WhisprStream")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Dictation that runs entirely on your Mac.\nMixes languages mid-sentence without losing either.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    }

    private var microphoneStep: some View {
        StepLayout(
            icon: "mic.fill",
            title: "Microphone access",
            blurb: "WhisprStream needs to hear you. Audio is transcribed on-device and never leaves your Mac."
        ) {
            PermissionCard(
                title: "Microphone",
                granted: permissions.microphone == .authorized,
                denied: permissions.microphone == .denied,
                action: { permissions.requestMicrophone() }
            )
        }
    }

    private var accessibilityStep: some View {
        StepLayout(
            icon: "hand.raised.fill",
            title: "Accessibility access",
            blurb: "This lets WhisprStream see your trigger key from any app, and paste the transcript where your cursor is."
        ) {
            VStack(spacing: 14) {
                PermissionCard(
                    title: "Accessibility",
                    granted: permissions.accessibility,
                    denied: false,
                    action: { permissions.requestAccessibility() }
                )

                if !permissions.accessibility {
                    Text("In System Settings, switch on **WhisprStream** under Privacy & Security → Accessibility. This window updates by itself.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                }
            }
        }
    }

    private var preferencesStep: some View {
        StepLayout(
            icon: "slider.horizontal.3",
            title: "How would you like to talk?",
            blurb: "You can change this any time from the menu bar."
        ) {
            VStack(spacing: 18) {
                ModePicker(settings: settings)
                KeyPicker(settings: settings)
            }
        }
    }

    private var readyStep: some View {
        VStack(spacing: 24) {
            SuccessMark()
                .frame(width: 88, height: 88)

            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))

                Text(readyBlurb)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    }

    private var readyBlurb: String {
        switch settings.activationMode {
        case .hold:
            return "Hold \(settings.triggerKey.label) anywhere, speak,\nand let go. Your words appear at the cursor."
        case .tap:
            return "Tap \(settings.triggerKey.label) to start, speak,\nand tap again. Your words appear at the cursor."
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 18) {
            ProgressDots(count: Step.allCases.count, index: step.rawValue)

            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back") { go(back: true) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if canSkip {
                    Button("Skip for now") { go(back: false) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Button(primaryLabel) {
                    if step == .ready { onFinish() } else { go(back: false) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 13.5, weight: .medium))
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
    }

    private var canSkip: Bool {
        switch step {
        case .microphone: return permissions.microphone != .authorized
        case .accessibility: return !permissions.accessibility
        default: return false
        }
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get Started"
        case .ready: return "Start Dictating"
        default: return "Continue"
        }
    }

    private func go(back: Bool) {
        direction = back ? -1 : 1
        let next = step.rawValue + (back ? -1 : 1)
        guard let target = Step(rawValue: next) else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            step = target
        }
    }
}

// MARK: - Layout

private struct StepLayout<Content: View>: View {
    let icon: String
    let title: String
    let blurb: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(height: 44)

            VStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                Text(blurb)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            content
                .padding(.top, 6)
        }
    }
}

// MARK: - Permission card

private struct PermissionCard: View {
    let title: String
    let granted: Bool
    let denied: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(granted ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                    .frame(width: 34, height: 34)

                Image(systemName: granted ? "checkmark" : "lock.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(granted ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(granted ? "Granted" : (denied ? "Denied — open System Settings" : "Not granted yet"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 12)

            if !granted {
                Button("Grant", action: action)
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            granted ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07),
                            lineWidth: 1
                        )
                }
        }
        .frame(width: 400)
        .animation(.spring(response: 0.34, dampingFraction: 0.75), value: granted)
    }
}

// MARK: - Pickers

struct ModePicker: View {
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 12) {
            ForEach(ActivationMode.allCases) { mode in
                let selected = settings.activationMode == mode
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        settings.activationMode = mode
                    }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 20, weight: .medium))
                        Text(mode.label)
                            .font(.system(size: 13, weight: .medium))
                        Text(mode.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 176, height: 116)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        selected ? Color.accentColor : Color.primary.opacity(0.07),
                                        lineWidth: selected ? 1.5 : 1
                                    )
                            }
                    }
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .scaleEffect(selected ? 1.0 : 0.97)
            }
        }
    }
}

struct KeyPicker: View {
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 10) {
            Text("Trigger key")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("", selection: $settings.triggerKey) {
                ForEach(TriggerKey.allCases) { key in
                    Text("\(key.symbol)  \(key.label)").tag(key)
                }
            }
            .labelsHidden()
            .frame(width: 210)
        }
    }
}

// MARK: - Decorations

private struct ProgressDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: i == index ? 20 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: index)
    }
}

/// Waveform bars that idle in a gentle loop — the welcome screen's mark.
private struct AnimatedMark: View {
    @State private var animating = false
    private let heights: [CGFloat] = [0.35, 0.62, 1.0, 0.72, 0.45]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: 8, height: 64 * heights[i] * (animating ? 1.0 : 0.42))
                    .animation(
                        .easeInOut(duration: 0.72)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.09),
                        value: animating
                    )
            }
        }
        .frame(height: 76)
        .onAppear { animating = true }
    }
}

/// Checkmark that draws itself in, then settles.
private struct SuccessMark: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .scaleEffect(appeared ? 1 : 0.5)
                .opacity(appeared ? 1 : 0)

            Image(systemName: "checkmark")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .scaleEffect(appeared ? 1 : 0.3)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { appeared = true }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical, compact ? 6 : 9)
            .background {
                Capsule().fill(Color.accentColor)
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

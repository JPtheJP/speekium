import AppKit
import Darwin

/// Local-development entry point used by `e2e-context-aware.sh`.
///
/// The packaged app must own the probe because macOS grants synthetic-input
/// permission to the signed app identity, not to a `swift test` subprocess.
/// Public builds ignore this hidden launch argument.
@MainActor
enum ContextAwareCapitalizationE2E {
    static let launchArgument = "--whispr-e2e-context-aware-capitalization"
    private static let statusArgumentPrefix = "--whispr-e2e-status="
    private static let targetPIDArgumentPrefix = "--whispr-e2e-target-pid="
    private static let sourceText = "Testing works."
    private static let expectedContext = "Hello this "
    private static let maximumPrefetchDuration: TimeInterval = 0.9

    static var isRequested: Bool {
        guard CommandLine.arguments.contains(launchArgument) else { return false }
        let identifier = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleIdentifier"
        ) as? String ?? ""
        return identifier.hasPrefix("dev.")
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        guard AXIsProcessTrusted() else {
            fail(
                "Accessibility permission is required for the signed "
                    + "development WhisprStream.app."
            )
        }

        guard let targetPID = integerArgument(withPrefix: targetPIDArgumentPrefix) else {
            fail("The E2E editor PID was not supplied.")
        }

        var finished = false
        var deliveryGate = TranscriptDeliveryGate()
        let queuedDelivery = DeferredTranscriptDelivery(
            text: sourceText,
            adjustForCursor: true
        )
        guard deliveryGate.submit(
            queuedDelivery,
            whileContextIsResolving: true
        ) == nil else {
            fail("Transcript delivery was not deferred during the cursor probe.")
        }

        let prefetchStartedAt = ProcessInfo.processInfo.systemUptime
        TextInserter.resolveTextBeforeCursor(
            fallback: nil,
            forceKeyboardFallback: true,
            allowWhilePhysicalModifiersPressed: true,
            targetProcessID: targetPID
        ) { precedingText in
            let prefetchDuration = ProcessInfo.processInfo.systemUptime - prefetchStartedAt
            guard prefetchDuration <= maximumPrefetchDuration else {
                fail(
                    "Cursor-context prefetch took "
                        + "\(Int(prefetchDuration * 1_000))ms; expected at most "
                        + "\(Int(maximumPrefetchDuration * 1_000))ms."
                )
            }
            guard precedingText == expectedContext else {
                fail(
                    "Expected cursor context \(expectedContext.debugDescription), got "
                        + "\(precedingText.debugDescription)."
                )
            }

            guard let delivery = deliveryGate.takePending() else {
                fail("Deferred transcript delivery was lost.")
            }
            let deliveredText = TranscriptFormatter.adjustedForCursor(
                delivery.text,
                precedingText: precedingText
            )
            guard deliveredText == "testing works." else {
                fail("Context-aware capitalization returned \(deliveredText.debugDescription).")
            }

            TextInserter.deliver(
                deliveredText,
                insertionText: TranscriptFormatter.textForInsertion(deliveredText),
                insertAtCursor: true,
                copyToClipboard: false,
                targetProcessID: targetPID
            )
            finished = true

            // `deliver` posts Cmd-V on the next main-loop turn and restores the
            // clipboard later. Keep the process alive until both have settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                writeStatus("completed")
                print(
                    "WhisprStream context-aware E2E injection completed "
                        + "prefetch=\(Int(prefetchDuration * 1_000))ms"
                )
                fflush(stdout)
                exit(EXIT_SUCCESS)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            guard !finished else { return }
            fail("Timed out while resolving cursor context.")
        }
        app.run()
    }

    private static func fail(_ message: String) -> Never {
        writeStatus("failed: \(message)")
        fputs("WhisprStream context-aware E2E failed: \(message)\n", stderr)
        fflush(stderr)
        exit(EXIT_FAILURE)
    }

    private static func writeStatus(_ value: String) {
        guard let argument = CommandLine.arguments.first(where: {
            $0.hasPrefix(statusArgumentPrefix)
        }) else { return }
        let path = String(argument.dropFirst(statusArgumentPrefix.count))
        guard !path.isEmpty else { return }
        try? Data(value.utf8).write(
            to: URL(fileURLWithPath: path),
            options: .atomic
        )
    }

    private static func integerArgument(withPrefix prefix: String) -> pid_t? {
        guard let argument = CommandLine.arguments.first(where: {
            $0.hasPrefix(prefix)
        }) else { return nil }
        return pid_t(argument.dropFirst(prefix.count))
    }
}

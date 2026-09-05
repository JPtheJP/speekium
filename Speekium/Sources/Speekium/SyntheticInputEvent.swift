import AppKit

/// Tags keyboard events emitted by Speekium itself. The global shortcut
/// monitor receives CGEvents posted by this process just like physical input;
/// without a marker, a user-selected shortcut such as Command-V can trigger a
/// second dictation while the app is inserting the first transcript.
enum SyntheticInputEvent {
    private static let marker: Int64 = 0x5748_4953_5052_5354 // "SPEEKIUMST"

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func wasGeneratedBySpeekium(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }
}

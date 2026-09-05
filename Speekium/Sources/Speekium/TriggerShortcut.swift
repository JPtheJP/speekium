import AppKit

/// The logical modifiers that participate in a recorded shortcut.
///
/// `NSEvent.ModifierFlags` contains device, keyboard-layout, and system flags
/// in addition to the four modifiers users expect to see in a shortcut. Keep
/// the persisted representation independent from those AppKit bit values.
struct TriggerModifiers: OptionSet, Codable, Equatable, Hashable {
    let rawValue: UInt8

    static let command = TriggerModifiers(rawValue: 1 << 0)
    static let control = TriggerModifiers(rawValue: 1 << 1)
    static let option = TriggerModifiers(rawValue: 1 << 2)
    static let shift = TriggerModifiers(rawValue: 1 << 3)

    static let all: TriggerModifiers = [.command, .control, .option, .shift]

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var result: TriggerModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        return flags
    }

    var compactSymbol: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }

    var spokenName: String {
        var names: [String] = []
        if contains(.control) { names.append("Control") }
        if contains(.option) { names.append("Option") }
        if contains(.shift) { names.append("Shift") }
        if contains(.command) { names.append("Command") }
        return names.joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rawValue: try container.decode(UInt8.self, forKey: .rawValue))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

/// Stable names for special keys that are useful as a shortcut primary key.
enum NamedTriggerKey: String, CaseIterable, Codable, Equatable, Hashable {
    case space
    case tab
    case `return`
    case delete
    case forwardDelete
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case home
    case end
    case pageUp
    case pageDown

    var label: String {
        switch self {
        case .space: return "Space"
        case .tab: return "Tab"
        case .return: return "Return"
        case .delete: return "Delete"
        case .forwardDelete: return "Forward Delete"
        case .leftArrow: return "Left Arrow"
        case .rightArrow: return "Right Arrow"
        case .upArrow: return "Up Arrow"
        case .downArrow: return "Down Arrow"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        }
    }

    var compactLabel: String {
        switch self {
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .forwardDelete: return "⌫"
        default: return label
        }
    }

    var spokenLabel: String { label }
}

/// The semantic identity used to describe a primary key after it has been
/// persisted. Matching still uses the observed physical key code.
enum TriggerKeyDescriptor: Codable, Equatable, Hashable {
    case modifier(TriggerKey)
    case printable(fallbackLabel: String)
    case function(number: Int)
    case named(NamedTriggerKey)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case modifier
        case printable
        case function
        case named
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .modifier:
            self = .modifier(try container.decode(TriggerKey.self, forKey: .value))
        case .printable:
            self = .printable(fallbackLabel: try container.decode(String.self, forKey: .value))
        case .function:
            self = .function(number: try container.decode(Int.self, forKey: .value))
        case .named:
            self = .named(try container.decode(NamedTriggerKey.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .modifier(key):
            try container.encode(Kind.modifier, forKey: .kind)
            try container.encode(key, forKey: .value)
        case let .printable(fallbackLabel):
            try container.encode(Kind.printable, forKey: .kind)
            try container.encode(fallbackLabel, forKey: .value)
        case let .function(number):
            try container.encode(Kind.function, forKey: .kind)
            try container.encode(number, forKey: .value)
        case let .named(key):
            try container.encode(Kind.named, forKey: .kind)
            try container.encode(key, forKey: .value)
        }
    }

    var compactLabel: String {
        switch self {
        case let .modifier(key):
            return key == .function ? "Fn" : "\(key.symbol) \(key.label)"
        case let .printable(fallbackLabel): return fallbackLabel
        case let .function(number): return "F\(number)"
        case let .named(key): return key.compactLabel
        }
    }

    var spokenLabel: String {
        switch self {
        case let .modifier(key): return key == .function ? "Fn" : key.label
        case let .printable(fallbackLabel):
            switch fallbackLabel {
            case ";": return "Semicolon"
            case ",": return "Comma"
            case ".": return "Period"
            case "/": return "Slash"
            case "\\": return "Backslash"
            case "-": return "Hyphen"
            case "=": return "Equals"
            case "[": return "Left Bracket"
            case "]": return "Right Bracket"
            case "'": return "Apostrophe"
            case "`": return "Grave Accent"
            default: return fallbackLabel
            }
        case let .function(number): return "F\(number)"
        case let .named(key): return key.spokenLabel
        }
    }
}

enum TriggerShortcutValidationError: LocalizedError, Equatable {
    case ordinaryKeyRequiresModifier
    case escapeIsReserved
    case unsupportedKey
    case invalidStoredShortcut

    var errorDescription: String? {
        switch self {
        case .ordinaryKeyRequiresModifier:
            return "Add Command, Control, Option, or Shift to that key."
        case .escapeIsReserved:
            return "Escape cancels shortcut recording and cannot be saved."
        case .unsupportedKey:
            return "That key cannot be used as a recording shortcut."
        case .invalidStoredShortcut:
            return "That saved shortcut is no longer valid."
        }
    }
}

/// A recorded push-to-talk shortcut.
struct TriggerShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: TriggerModifiers
    let key: TriggerKeyDescriptor

    static let defaultValue = TriggerShortcut.modifierOnly(.rightOption)

    init(keyCode: UInt16, modifiers: TriggerModifiers, key: TriggerKeyDescriptor) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    static func modifierOnly(_ key: TriggerKey) -> TriggerShortcut {
        TriggerShortcut(keyCode: key.keyCode, modifiers: [], key: .modifier(key))
    }

    /// Builds a candidate from a key-down event or a modifier flags-change
    /// event. The caller can keep listening after an error and present the
    /// returned validation message without changing the saved preference.
    static func candidate(from event: NSEvent) throws -> TriggerShortcut {
        if event.type == .flagsChanged {
            guard let key = TriggerKey.allCases.first(where: { $0.keyCode == event.keyCode }),
                  event.modifierFlags.contains(key.flag) else {
                throw TriggerShortcutValidationError.unsupportedKey
            }
            let shortcut = modifierOnly(key)
            try validate(shortcut)
            return shortcut
        }

        guard event.type == .keyDown, !event.isARepeat else {
            throw TriggerShortcutValidationError.unsupportedKey
        }
        if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            throw TriggerShortcutValidationError.escapeIsReserved
        }

        let modifiers = TriggerModifiers(event.modifierFlags)
        let descriptor = descriptor(from: event)
        guard let descriptor else {
            throw TriggerShortcutValidationError.unsupportedKey
        }

        let shortcut = TriggerShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers,
            key: descriptor
        )
        try validate(shortcut)
        return shortcut
    }

    static func validate(_ shortcut: TriggerShortcut) throws {
        guard shortcut.modifiers.isSubset(of: .all) else {
            throw TriggerShortcutValidationError.invalidStoredShortcut
        }

        switch shortcut.key {
        case let .modifier(key):
            guard shortcut.modifiers.isEmpty, shortcut.keyCode == key.keyCode else {
                throw TriggerShortcutValidationError.invalidStoredShortcut
            }
        case let .function(number):
            guard (1...24).contains(number) else {
                throw TriggerShortcutValidationError.invalidStoredShortcut
            }
            if shortcut.modifiers.isEmpty, !(13...24).contains(number) {
                throw TriggerShortcutValidationError.ordinaryKeyRequiresModifier
            }
        case let .printable(label):
            guard label.count == 1, shortcut.modifiers.isEmpty == false else {
                throw shortcut.modifiers.isEmpty
                    ? TriggerShortcutValidationError.ordinaryKeyRequiresModifier
                    : TriggerShortcutValidationError.invalidStoredShortcut
            }
        case .named:
            guard !shortcut.modifiers.isEmpty else {
                throw TriggerShortcutValidationError.ordinaryKeyRequiresModifier
            }
        }
    }

    var compactDisplay: String {
        switch key {
        case .modifier:
            return key.compactLabel
        default:
            return modifiers.compactSymbol + key.compactLabel
        }
    }

    var spokenDisplay: String {
        switch key {
        case .modifier:
            return key.spokenLabel
        default:
            let prefix = modifiers.spokenName
            return [prefix, key.spokenLabel].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    var accessibilityLabel: String {
        "Recording shortcut: \(spokenDisplay)"
    }

    private static func descriptor(from event: NSEvent) -> TriggerKeyDescriptor? {
        if let functionNumber = functionNumber(for: event.specialKey) {
            return .function(number: functionNumber)
        }

        if let named = namedKey(for: event) {
            return .named(named)
        }

        // AppKit uses specialKey for arrows, function keys, navigation keys,
        // and media/system keys alike. Only the stable named keys above are
        // supported; do not turn an unsupported system event into a printable
        // one just because it exposes a private Unicode scalar.
        if event.specialKey != nil {
            return nil
        }

        let fallback = event.charactersIgnoringModifiers ?? ""
        guard fallback.count == 1 else { return nil }
        return .printable(fallbackLabel: fallback.uppercased())
    }

    private static func functionNumber(for specialKey: NSEvent.SpecialKey?) -> Int? {
        guard let specialKey else { return nil }
        let keys: [(NSEvent.SpecialKey, Int)] = [
            (.f1, 1), (.f2, 2), (.f3, 3), (.f4, 4), (.f5, 5), (.f6, 6),
            (.f7, 7), (.f8, 8), (.f9, 9), (.f10, 10), (.f11, 11), (.f12, 12),
            (.f13, 13), (.f14, 14), (.f15, 15), (.f16, 16), (.f17, 17),
            (.f18, 18), (.f19, 19), (.f20, 20), (.f21, 21), (.f22, 22),
            (.f23, 23), (.f24, 24)
        ]
        return keys.first(where: { $0.0 == specialKey })?.1
    }

    private static func namedKey(for event: NSEvent) -> NamedTriggerKey? {
        if let specialKey = event.specialKey {
            let keys: [(NSEvent.SpecialKey, NamedTriggerKey)] = [
                (.leftArrow, .leftArrow), (.rightArrow, .rightArrow),
                (.upArrow, .upArrow), (.downArrow, .downArrow),
                (.home, .home), (.end, .end), (.pageUp, .pageUp),
                (.pageDown, .pageDown), (.deleteForward, .forwardDelete),
                (.enter, .return), (.carriageReturn, .return),
                (.newline, .return), (.backspace, .delete),
                (.delete, .delete), (.tab, .tab), (.backTab, .tab)
            ]
            if let named = keys.first(where: { $0.0 == specialKey })?.1 {
                return named
            }
            return nil
        }

        switch event.keyCode {
        case 36: return .return
        case 48: return .tab
        case 49: return .space
        case 51: return .delete
        case 117: return .forwardDelete
        default: return nil
        }
    }
}

extension TriggerShortcut {
    /// Used by Settings when loading persisted data. Keeping validation in one
    /// place prevents corrupt defaults from reaching the event monitor.
    static func validated(_ shortcut: TriggerShortcut) -> TriggerShortcut? {
        guard (try? validate(shortcut)) != nil else { return nil }
        return shortcut
    }
}

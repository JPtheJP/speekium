import AVFoundation
import Foundation

/// Plays macOS's built-in alert sounds via AudioServices.
///
/// `AudioServicesPlaySystemSound` comes from AudioToolbox, which AVFoundation
/// re-exports — importing AVFoundation is enough.
///
/// The iOS shorthand of hardcoding a numeric id:
///
///     let systemSoundID: SystemSoundID = 1016   // iOS "tweet"
///     AudioServicesPlaySystemSound(systemSoundID)
///
/// is silently a no-op on macOS: those ids aren't defined here, and macOS's own
/// ids start at 4096 (`kSystemSoundID_UserPreferredAlert`). On macOS you
/// register a file first with `AudioServicesCreateSystemSoundID`, which hands
/// back an id you then play.
///
/// Chosen over `AVAudioPlayer` because these *are* system alert sounds: they
/// follow the user's alert-volume setting and duck correctly, which is the
/// behaviour you want for a notification chime.
final class SoundPlayer {
    static let shared = SoundPlayer()

    private var ids: [String: SystemSoundID] = [:]
    private let lock = NSLock()

    private init() {}

    /// Directories scanned for sounds, in priority order.
    private static let directories = [
        "/System/Library/Sounds",
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds"),
    ]

    /// Every playable sound name, de-duplicated, system first then user.
    static let available: [String] = {
        var seen = Set<String>()
        var names: [String] = []
        for dir in directories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for file in files.sorted() {
                let name = (file as NSString).deletingPathExtension
                guard !name.isEmpty, !seen.contains(name), url(for: name) != nil else { continue }
                seen.insert(name)
                names.append(name)
            }
        }
        return names
    }()

    static func url(for name: String) -> URL? {
        for dir in directories {
            for ext in ["aiff", "aif", "wav", "m4a", "caf"] {
                let path = (dir as NSString).appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    /// Marks an id as one of the app's own sounds rather than a macOS alert
    /// sound, so the two namespaces can share one cache without colliding.
    private static let bundledPrefix = "bundled:"

    static func bundledID(_ file: String) -> String { bundledPrefix + file }

    /// Resolves either namespace to a file on disk.
    private static func resolve(_ id: String) -> URL? {
        guard id.hasPrefix(bundledPrefix) else { return url(for: id) }
        let file = String(id.dropFirst(bundledPrefix.count))
        return Bundle.main.url(forResource: file, withExtension: "caf", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: file, withExtension: "caf")
    }

    /// Registers a sound and caches its id. Safe to call repeatedly.
    @discardableResult
    func prepare(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if ids[name] != nil { return true }
        guard let url = Self.resolve(name) else { return false }

        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        guard status == noErr else { return false }

        ids[name] = id
        return true
    }

    func play(_ name: String) {
        guard prepare(name) else { return }
        lock.lock()
        let id = ids[name]
        lock.unlock()
        guard let id else { return }
        AudioServicesPlaySystemSound(id)
    }

    /// Plays one of the app's own bundled sounds.
    func playBundled(_ file: String) { play(Self.bundledID(file)) }

    func prepareBundled(_ file: String) { prepare(Self.bundledID(file)) }

    /// Whatever alert sound the user picked in System Settings → Sound.
    func playUserAlert() {
        AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert)
    }

    deinit {
        for id in ids.values {
            AudioServicesDisposeSystemSoundID(id)
        }
    }
}

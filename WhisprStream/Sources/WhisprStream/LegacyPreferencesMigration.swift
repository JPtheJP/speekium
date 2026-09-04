import Foundation

struct LegacyPreferencesMigrationSummary: Equatable {
    let vocabularyAdded: Int
    let shortcutsAdded: Int
    let shortcutConflictsSkipped: Int
    let invalidShortcutsSkipped: Int
}

struct LegacyPreferencesMigrationPlan {
    let vocabulary: [String]
    let encodedShortcuts: Data
    let summary: LegacyPreferencesMigrationSummary
}

enum LegacyPreferencesMigrationError: Error {
    case invalidVocabulary
    case invalidCurrentVocabulary
    case invalidLegacyShortcuts
    case invalidCurrentShortcuts
}

/// Keeps user-authored content available when alternating between development
/// and release builds. Each launch imports additions from the other domain;
/// the current domain wins shortcut conflicts and neither source is deleted.
enum LegacyPreferencesMigration {
    static let releaseBundleIdentifier = "com.leoleo.whisprstream"
    static let legacyDevelopmentDomain = "dev.local.whisprstream"
    /// Retained so installations that completed the old one-time import remain
    /// readable. Continuous merge deliberately ignores this marker.
    static let completionKey = "legacyDevelopmentContentMigration.v1"

    private enum Keys {
        static let contextTerms = "contextTerms"
        static let vocabularyEntries = "vocabularyEntries"
        static let voiceShortcuts = "voiceShortcuts.v1"
    }

    static func pendingPlan(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        destination: UserDefaults = .standard
    ) throws -> LegacyPreferencesMigrationPlan? {
        guard let sourceName = counterpartDomain(for: bundleIdentifier),
              let sourceDomain = destination.persistentDomain(forName: sourceName)
        else { return nil }
        return try prepareIfNeeded(
            destination: destination,
            sourceDomain: sourceDomain
        )
    }

    static func counterpartDomain(for bundleIdentifier: String) -> String? {
        switch bundleIdentifier {
        case releaseBundleIdentifier:
            return legacyDevelopmentDomain
        case legacyDevelopmentDomain:
            return releaseBundleIdentifier
        default:
            return nil
        }
    }

    /// Builds an immutable merge plan without changing either preferences
    /// domain. Startup applies it only when the counterpart has new content.
    static func prepareIfNeeded(
        destination: UserDefaults,
        sourceDomain: [String: Any]
    ) throws -> LegacyPreferencesMigrationPlan? {
        let hasVocabulary = sourceDomain[Keys.vocabularyEntries] != nil
            || sourceDomain[Keys.contextTerms] != nil
        let hasShortcuts = sourceDomain[Keys.voiceShortcuts] != nil
        guard hasVocabulary || hasShortcuts else { return nil }

        // Decode and validate everything before writing anything, so malformed
        // counterpart data cannot leave the current domain half-merged.
        let importedVocabulary = try vocabulary(from: sourceDomain)
        let currentVocabulary = try vocabulary(from: destination)
        let currentShortcuts = try shortcuts(from: destination)
        let imported = try importedShortcuts(from: sourceDomain)
        guard !importedVocabulary.isEmpty
                || !imported.shortcuts.isEmpty
                || imported.invalidCount > 0 else { return nil }

        let mergedVocabulary = VocabularyTransfer.appending(
            importedVocabulary,
            to: currentVocabulary
        )
        let mergedShortcuts = VoiceShortcutTransfer.appending(
            imported.shortcuts,
            to: currentShortcuts
        )
        let encodedShortcuts = try JSONEncoder().encode(mergedShortcuts)

        let vocabularyAdded = mergedVocabulary.count - currentVocabulary.count
        let shortcutsAdded = mergedShortcuts.count - currentShortcuts.count
        guard vocabularyAdded > 0 || shortcutsAdded > 0 else { return nil }
        return LegacyPreferencesMigrationPlan(
            vocabulary: mergedVocabulary,
            encodedShortcuts: encodedShortcuts,
            summary: LegacyPreferencesMigrationSummary(
                vocabularyAdded: vocabularyAdded,
                shortcutsAdded: shortcutsAdded,
                shortcutConflictsSkipped: imported.shortcuts.count - shortcutsAdded,
                invalidShortcutsSkipped: imported.invalidCount
            )
        )
    }

    static func apply(
        _ plan: LegacyPreferencesMigrationPlan,
        to destination: UserDefaults = .standard
    ) {
        destination.set(plan.vocabulary, forKey: Keys.vocabularyEntries)
        destination.set(plan.encodedShortcuts, forKey: Keys.voiceShortcuts)
    }

    private static func vocabulary(from domain: [String: Any]) throws -> [String] {
        if let value = domain[Keys.vocabularyEntries] {
            guard let entries = value as? [String] else {
                throw LegacyPreferencesMigrationError.invalidVocabulary
            }
            return VocabularyEntry.normalizedUnique(entries)
        }
        guard let value = domain[Keys.contextTerms] else { return [] }
        guard let legacy = value as? String else {
            throw LegacyPreferencesMigrationError.invalidVocabulary
        }
        return VocabularyEntry.normalizedUnique(
            legacy.split(whereSeparator: \.isWhitespace).map(String.init)
        )
    }

    private static func vocabulary(from defaults: UserDefaults) throws -> [String] {
        if let value = defaults.object(forKey: Keys.vocabularyEntries) {
            guard let entries = value as? [String] else {
                throw LegacyPreferencesMigrationError.invalidCurrentVocabulary
            }
            return VocabularyEntry.normalizedUnique(entries)
        }
        let legacy: String
        if let value = defaults.object(forKey: Keys.contextTerms) {
            guard let stored = value as? String else {
                throw LegacyPreferencesMigrationError.invalidCurrentVocabulary
            }
            legacy = stored
        } else {
            legacy = ""
        }
        return VocabularyEntry.normalizedUnique(
            legacy.split(whereSeparator: \.isWhitespace).map(String.init)
        )
    }

    private static func shortcuts(from defaults: UserDefaults) throws -> [VoiceShortcut] {
        guard let data = defaults.data(forKey: Keys.voiceShortcuts) else { return [] }
        do {
            return try JSONDecoder().decode([VoiceShortcut].self, from: data)
        } catch {
            throw LegacyPreferencesMigrationError.invalidCurrentShortcuts
        }
    }

    private static func importedShortcuts(
        from domain: [String: Any]
    ) throws -> (shortcuts: [VoiceShortcut], invalidCount: Int) {
        guard let value = domain[Keys.voiceShortcuts] else { return ([], 0) }
        guard let data = value as? Data else {
            throw LegacyPreferencesMigrationError.invalidLegacyShortcuts
        }

        let decoded: [VoiceShortcut]
        do {
            decoded = try JSONDecoder().decode([VoiceShortcut].self, from: data)
        } catch {
            throw LegacyPreferencesMigrationError.invalidLegacyShortcuts
        }

        var validated: [VoiceShortcut] = []
        var invalidCount = 0
        for oldShortcut in decoded {
            // IDs are domain-local implementation details. Fresh IDs prevent a
            // coincidental collision with a shortcut already in the release
            // domain while preserving every user-visible field.
            let shortcut = VoiceShortcut(
                id: UUID(),
                trigger: oldShortcut.trigger,
                replacement: oldShortcut.replacement,
                isEnabled: oldShortcut.isEnabled
            )
            do {
                try VoiceShortcutValidation.validate(shortcut, against: validated)
                validated.append(shortcut)
            } catch {
                invalidCount += 1
            }
        }
        return (validated, invalidCount)
    }
}

import XCTest
@testable import WhisprStream

@MainActor
final class LegacyPreferencesMigrationTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "LegacyPreferencesMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    private func encoded(_ shortcuts: [VoiceShortcut]) throws -> Data {
        try JSONEncoder().encode(shortcuts)
    }

    func testMergesOnlyVocabularyAndVoiceShortcutsWithoutOverwritingConflicts() throws {
        let defaults = makeDefaults()
        defaults.set(["Release term", "Shared term"], forKey: "vocabularyEntries")
        defaults.set("Qwen/Qwen3-ASR-1.7B", forKey: "model")

        let releaseShortcut = VoiceShortcut(
            id: UUID(),
            trigger: "hello world",
            replacement: "keep release replacement",
            isEnabled: false
        )
        defaults.set(try encoded([releaseShortcut]), forKey: "voiceShortcuts.v1")

        let conflictingDevelopmentShortcut = VoiceShortcut(
            id: UUID(),
            trigger: "HELLO, WORLD!",
            replacement: "do not overwrite",
            isEnabled: true
        )
        let developmentShortcut = VoiceShortcut(
            id: UUID(),
            trigger: "shortcut website",
            replacement: "https://example.com",
            isEnabled: true
        )
        let invalidDevelopmentShortcut = VoiceShortcut(
            id: UUID(),
            trigger: "shortcut invalid",
            replacement: "   ",
            isEnabled: true
        )
        let source: [String: Any] = [
            "vocabularyEntries": ["Shared term", "  Development phrase  "],
            "voiceShortcuts.v1": try encoded([
                conflictingDevelopmentShortcut,
                developmentShortcut,
                invalidDevelopmentShortcut,
            ]),
            "model": "must not migrate",
        ]

        let plan = try XCTUnwrap(
            LegacyPreferencesMigration.prepareIfNeeded(
                destination: defaults,
                sourceDomain: source
            )
        )

        // Detection and planning remain read-only until startup applies them.
        XCTAssertEqual(
            defaults.array(forKey: "vocabularyEntries") as? [String],
            ["Release term", "Shared term"]
        )
        LegacyPreferencesMigration.apply(plan, to: defaults)

        XCTAssertEqual(
            defaults.array(forKey: "vocabularyEntries") as? [String],
            ["Release term", "Shared term", "Development phrase"]
        )
        let merged = try JSONDecoder().decode(
            [VoiceShortcut].self,
            from: XCTUnwrap(defaults.data(forKey: "voiceShortcuts.v1"))
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], releaseShortcut)
        XCTAssertEqual(merged[1].trigger, developmentShortcut.trigger)
        XCTAssertEqual(merged[1].replacement, developmentShortcut.replacement)
        XCTAssertEqual(merged[1].isEnabled, developmentShortcut.isEnabled)
        XCTAssertNotEqual(merged[1].id, developmentShortcut.id)
        XCTAssertEqual(defaults.string(forKey: "model"), "Qwen/Qwen3-ASR-1.7B")
        XCTAssertEqual(
            plan.summary,
            LegacyPreferencesMigrationSummary(
                vocabularyAdded: 1,
                shortcutsAdded: 1,
                shortcutConflictsSkipped: 1,
                invalidShortcutsSkipped: 1
            )
        )
    }

    func testMergeRunsAgainWhenCounterpartLaterAddsContent() throws {
        let defaults = makeDefaults()
        let firstSource: [String: Any] = ["vocabularyEntries": ["First term"]]

        let plan = try XCTUnwrap(LegacyPreferencesMigration.prepareIfNeeded(
            destination: defaults,
            sourceDomain: firstSource
        ))
        LegacyPreferencesMigration.apply(plan, to: defaults)
        let secondPlan = try XCTUnwrap(LegacyPreferencesMigration.prepareIfNeeded(
            destination: defaults,
            sourceDomain: ["vocabularyEntries": ["First term", "Later term"]]
        ))
        LegacyPreferencesMigration.apply(secondPlan, to: defaults)
        XCTAssertEqual(
            defaults.array(forKey: "vocabularyEntries") as? [String],
            ["First term", "Later term"]
        )
        XCTAssertNil(try LegacyPreferencesMigration.prepareIfNeeded(
            destination: defaults,
            sourceDomain: ["vocabularyEntries": ["First term", "Later term"]]
        ))
    }

    func testOldCompletionMarkerDoesNotBlockNewAdditions() throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: LegacyPreferencesMigration.completionKey)
        defaults.set(["Existing term"], forKey: "vocabularyEntries")

        let plan = try XCTUnwrap(LegacyPreferencesMigration.prepareIfNeeded(
            destination: defaults,
            sourceDomain: ["vocabularyEntries": ["Existing term", "New term"]]
        ))

        XCTAssertEqual(plan.vocabulary, ["Existing term", "New term"])
        XCTAssertEqual(plan.summary.vocabularyAdded, 1)
    }

    func testFindsCounterpartForDevelopmentAndReleaseBuilds() {
        XCTAssertEqual(
            LegacyPreferencesMigration.counterpartDomain(
                for: LegacyPreferencesMigration.releaseBundleIdentifier
            ),
            LegacyPreferencesMigration.legacyDevelopmentDomain
        )
        XCTAssertEqual(
            LegacyPreferencesMigration.counterpartDomain(
                for: LegacyPreferencesMigration.legacyDevelopmentDomain
            ),
            LegacyPreferencesMigration.releaseBundleIdentifier
        )
        XCTAssertNil(LegacyPreferencesMigration.counterpartDomain(for: "example.test"))
    }

    func testUnrelatedDevelopmentSettingsDoNotTriggerMigration() throws {
        let defaults = makeDefaults()

        XCTAssertNil(try LegacyPreferencesMigration.prepareIfNeeded(
            destination: defaults,
            sourceDomain: ["model": "Qwen/Qwen3-ASR-1.7B", "playSound": false]
        ))
        XCTAssertFalse(defaults.bool(forKey: LegacyPreferencesMigration.completionKey))
        XCTAssertNil(defaults.object(forKey: "model"))
        XCTAssertNil(defaults.object(forKey: "playSound"))
    }

    func testMalformedLegacyShortcutDataLeavesDestinationUntouchedAndRetryable() throws {
        let defaults = makeDefaults()
        defaults.set(["Release term"], forKey: "vocabularyEntries")

        XCTAssertThrowsError(try LegacyPreferencesMigration.prepareIfNeeded(
            destination: defaults,
            sourceDomain: [
                "vocabularyEntries": ["Development term"],
                "voiceShortcuts.v1": Data([0x01, 0x02, 0x03]),
            ]
        ))
        XCTAssertEqual(
            defaults.array(forKey: "vocabularyEntries") as? [String],
            ["Release term"]
        )
        XCTAssertNil(defaults.data(forKey: "voiceShortcuts.v1"))
        XCTAssertFalse(defaults.bool(forKey: LegacyPreferencesMigration.completionKey))
    }

    func testMalformedCurrentVocabularyIsPreservedAndMigrationRemainsRetryable() throws {
        let defaults = makeDefaults()
        let malformed = ["unexpected": "value"]
        defaults.set(malformed, forKey: "vocabularyEntries")
        let source: [String: Any] = ["vocabularyEntries": ["Development term"]]

        XCTAssertThrowsError(try LegacyPreferencesMigration.prepareIfNeeded(
            destination: defaults,
            sourceDomain: source
        )) { error in
            guard case LegacyPreferencesMigrationError.invalidCurrentVocabulary = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            defaults.dictionary(forKey: "vocabularyEntries") as? [String: String],
            malformed
        )
        XCTAssertFalse(defaults.bool(forKey: LegacyPreferencesMigration.completionKey))

        defaults.set(["Release term"], forKey: "vocabularyEntries")
        let plan = try XCTUnwrap(LegacyPreferencesMigration.prepareIfNeeded(
            destination: defaults,
            sourceDomain: source
        ))
        XCTAssertEqual(plan.vocabulary, ["Release term", "Development term"])
    }

    func testMigratesWhitespaceDelimitedLegacyVocabulary() throws {
        let defaults = makeDefaults()

        let plan = try XCTUnwrap(LegacyPreferencesMigration.prepareIfNeeded(
            destination: defaults,
            sourceDomain: ["contextTerms": "Claude   Codex\nGitHub"]
        ))

        XCTAssertNil(defaults.array(forKey: "vocabularyEntries"))
        LegacyPreferencesMigration.apply(plan, to: defaults)

        XCTAssertEqual(
            defaults.array(forKey: "vocabularyEntries") as? [String],
            ["Claude", "Codex", "GitHub"]
        )
        XCTAssertEqual(plan.summary.vocabularyAdded, 3)
        XCTAssertEqual(plan.summary.shortcutsAdded, 0)
    }
}

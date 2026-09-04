/// Chooses optional language guidance for a completed short clip. Automatic
/// multilingual mode deliberately returns no hint: nearby text and the active
/// keyboard describe what the user is writing, not necessarily what they are
/// saying, and forcing that guess can make the ASR model translate a language
/// switch. Fixed preferences remain deterministic for isolated-word workflows.
enum ShortUtteranceLanguageResolver {
    static func modelLanguage(
        for preference: ShortUtteranceLanguage
    ) -> String? {
        preference.fixedModelLanguage
    }
}

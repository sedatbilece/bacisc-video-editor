import Foundation

/// AI preferences: the OpenRouter key lives in the keychain, model choices in user defaults.
enum AISettings {
    static let speechToTextModelKey = "ai.speechToText.model"
    static let speechToTextLanguageKey = "ai.speechToText.language"
    static let glossaryKey = "ai.speechToText.glossary"
    static let defaultSpeechToTextModel = "openai/whisper-large-v3"

    private static let apiKeyAccount = "openrouter-api-key"

    static var apiKey: String? {
        KeychainStore.string(for: apiKeyAccount)
    }

    static func setAPIKey(_ key: String?) throws {
        try KeychainStore.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: apiKeyAccount)
    }

    static var speechToTextModel: String {
        let value = UserDefaults.standard.string(forKey: speechToTextModelKey) ?? ""
        return value.isEmpty ? defaultSpeechToTextModel : value
    }

    /// ISO-639-1 code; empty means auto-detect.
    static var speechToTextLanguage: String {
        UserDefaults.standard.string(forKey: speechToTextLanguageKey) ?? ""
    }

    /// Speech-to-text glossary, stored as JSON in user defaults.
    static var glossary: [GlossaryEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: glossaryKey) else { return [] }
            return (try? JSONDecoder().decode([GlossaryEntry].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: glossaryKey)
        }
    }

    /// Languages offered in pickers; "" is auto-detect.
    static let languages: [(code: String, name: String)] = [
        ("", "Auto-detect"),
        ("tr", "Turkish"),
        ("en", "English"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
    ]
}

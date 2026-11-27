import Foundation

public enum LyricLanguage: String, Sendable {
    case chinese
    case english
}

/// Small shared vocabulary boundary for the native app and its reusable modules.
/// The app follows macOS language preferences; an explicit language keeps tests
/// deterministic without changing global defaults or the process locale.
public enum LyricLocalization {
    public static let language = resolve(preferredLanguages: Locale.preferredLanguages)

    public static func resolve(preferredLanguages: [String]) -> LyricLanguage {
        for preference in preferredLanguages {
            let identifier = preference.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-").lowercased()
            if identifier == "zh" || identifier.hasPrefix("zh-") { return .chinese }
            if identifier == "en" || identifier.hasPrefix("en-") { return .english }
        }
        return .english
    }

    public static func text(_ chinese: String, _ english: String,
                            language: LyricLanguage? = nil) -> String {
        (language ?? Self.language) == .chinese ? chinese : english
    }
}

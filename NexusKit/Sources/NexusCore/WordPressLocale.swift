import Foundation

// The language of a new WordPress site (3l). The window offers the languages of macOS first. Only
// the locales that WordPress has go in the list, because wp core download fails for another one.
public struct WordPressLocale: Sendable, Hashable, Identifiable {
    public static let english = "en_US"

    // The locale of WordPress for each language code, and for a language with more than one, for
    // each region.
    static let known: [String: String] = [
        "ar": "ar", "bg": "bg_BG", "ca": "ca", "cs": "cs_CZ", "da": "da_DK", "de": "de_DE", "el": "el",
        "es": "es_ES", "et": "et", "fi": "fi", "fr": "fr_FR", "he": "he_IL", "hr": "hr", "hu": "hu_HU",
        "id": "id_ID", "it": "it_IT", "ja": "ja", "ko": "ko_KR", "lt": "lt_LT", "lv": "lv", "nb": "nb_NO",
        "nl": "nl_NL", "pl": "pl_PL", "pt": "pt_PT", "ro": "ro_RO", "ru": "ru_RU", "sk": "sk_SK",
        "sl": "sl_SI", "sr": "sr_RS", "sv": "sv_SE", "th": "th", "tr": "tr_TR", "uk": "uk", "vi": "vi",
        "zh": "zh_CN",
        "de-CH": "de_CH", "en-AU": "en_AU", "en-CA": "en_CA", "en-GB": "en_GB", "en-NZ": "en_NZ",
        "en-ZA": "en_ZA", "es-AR": "es_AR", "es-MX": "es_MX", "fr-BE": "fr_BE", "fr-CA": "fr_CA",
        "nl-BE": "nl_BE", "pt-BR": "pt_BR", "zh-HK": "zh_HK", "zh-TW": "zh_TW",
    ]

    public let code: String
    public let displayName: String

    public var id: String { code }

    // The preferred languages of macOS first, then English (United States).
    public static func choices(preferred: [String], displayLocale: Locale = .current) -> [WordPressLocale] {
        var codes = preferred.compactMap(code(for:))
        codes.append(english)

        var seen: Set<String> = []

        return codes.filter { seen.insert($0).inserted }.map { code in
            WordPressLocale(code: code, displayName: displayLocale.localizedString(forIdentifier: code) ?? code)
        }
    }

    public static func code(for identifier: String) -> String? {
        let locale = Locale(identifier: identifier)

        guard let language = locale.language.languageCode?.identifier else {
            return nil
        }

        if let region = locale.region?.identifier, let regional = known["\(language)-\(region)"] {
            return regional
        }

        if language == "en" {
            return english
        }

        return known[language]
    }
}

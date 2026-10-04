import Foundation

/// The language the interface speaks. It affects no build output: map labels follow the
/// recipe's `Labels` field and the code page.
enum Lang: String, CaseIterable, Codable {
    case en, ru

    /// The language's endonym, for a language picker.
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        }
    }

    /// Returns the first of `preferred` that is a supported language, else `.en`. Tags are
    /// matched on their base subtag.
    static func fromSystem(_ preferred: [String] = Locale.preferredLanguages) -> Lang {
        for tag in preferred {
            guard
                let base = tag.split(whereSeparator: { $0 == "-" || $0 == "_" })
                    .first?.lowercased()
            else { continue }
            if let match = Lang(rawValue: base) { return match }
        }
        return .en
    }
}

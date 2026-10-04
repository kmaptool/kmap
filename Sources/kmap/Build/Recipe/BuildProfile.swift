import Foundation

/// A named set of build choices, one per device or per kind of map. Chosen at the top of
/// the build form, which it fills in; a profile is rewritten only from the profile screen.
struct BuildProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var choices: BuildChoices

    init(id: String = UUID().uuidString, name: String, choices: BuildChoices = BuildChoices()) {
        self.id = id
        self.name = name
        self.choices = choices
    }

    /// The name the first profile carries on a fresh install. Not translated: it is stored
    /// data, and a stored name must not change with the interface language.
    static let firstName = "Default"

    /// Orders profiles by name: Latin first, then Cyrillic, then everything else. The order
    /// is fixed by script rather than by locale, so it does not change with the interface
    /// language.
    static func precedes(_ a: BuildProfile, _ b: BuildProfile) -> Bool {
        let left = script(of: a.name), right = script(of: b.name)
        if left != right { return left < right }
        // Compared in the alphabet's own locale rather than the interface's, so the order
        // within a script is stable whatever language the screen is in.
        let locale = Locale(identifier: left == 1 ? "ru" : "en")
        let order = a.name.compare(
            b.name,
            options: [.caseInsensitive],
            range: nil,
            locale: locale
        )
        if order != .orderedSame { return order == .orderedAscending }
        return a.id < b.id
    }

    /// 0 Latin, 1 Cyrillic, 2 anything else — digits, punctuation, another script.
    private static func script(of name: String) -> Int {
        guard let first = name.trimmingCharacters(in: .whitespaces).unicodeScalars.first
        else { return 2 }
        switch first.value {
        case 0x0000...0x024F where first.properties.isAlphabetic: return 0
        case 0x0400...0x04FF: return 1
        default: return 2
        }
    }
}

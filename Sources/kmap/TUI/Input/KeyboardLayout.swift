import Foundation

/// Turning a typed character into the command it stands for.
enum Keys {
    /// The Latin letter on the same physical key, mapping the Cyrillic layout onto QWERTY
    /// position for position so key bindings survive a layout switch. Any other character
    /// is returned lowercased.
    static func latin(_ character: Character) -> Character {
        let lowered = Character(character.lowercased())
        return cyrillicToQwerty[lowered] ?? lowered
    }

    private static let cyrillicToQwerty: [Character: Character] = [
        "й": "q", "ц": "w", "у": "e", "к": "r", "е": "t", "н": "y", "г": "u", "ш": "i",
        "щ": "o", "з": "p", "х": "[", "ъ": "]",
        "ф": "a", "ы": "s", "в": "d", "а": "f", "п": "g", "р": "h", "о": "j", "л": "k",
        "д": "l", "ж": ";", "э": "'",
        "я": "z", "ч": "x", "с": "c", "м": "v", "и": "b", "т": "n", "ь": "m",
        "б": ",", "ю": ".", "ё": "`"
    ]
}

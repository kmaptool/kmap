import Foundation

/// Turning a typed character into the command it stands for.
enum Keys {

    /// Returns the Latin letter on the same physical key, mapping ЙЦУКЕН onto QWERTY
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

/// Where the pointer was and what it did. Coordinates are the terminal's own, counted
/// from zero at the top-left; screens convert to their own rectangles.
struct MouseEvent: Equatable {
    enum Action: Equatable {
        /// The pointer moved with nothing held down. Reported only while a screen has
        /// motion tracking on.
        case move
        case press, drag, release, scrollUp, scrollDown
    }
    let action: Action
    let x: Int
    let y: Int
    /// Whether the left button was involved; no other button is acted on.
    let isPrimary: Bool
}

/// A decoded keyboard event.
extension KeyEvent {
    /// The same event with a Cyrillic letter replaced by the Latin one on that key. For
    /// key bindings only: text entry must take the raw event first.
    var command: KeyEvent {
        if case .char(let c) = self { return .char(Keys.latin(c)) }
        return self
    }
}

enum KeyEvent: Equatable {
    case mouse(MouseEvent)
    case char(Character)
    case enter
    case newline        // Ctrl+J — insert a line break without submitting
    case backspace
    case tab
    case backTab
    case esc
    case up, down, left, right
    case home, end
    case pageUp, pageDown
    case delete
    case ctrl(Character)
    case paste(String)  // bracketed-paste content (newlines preserved)
}

import Foundation

/// A decoded keyboard event.
enum KeyEvent: Equatable {
    case mouse(MouseEvent)
    case char(Character)
    case enter
    /// Ctrl+J: a line break inserted without submitting.
    case newline
    case backspace
    case tab
    case backTab
    case esc
    case up, down, left, right
    case home, end
    case pageUp, pageDown
    case delete
    case ctrl(Character)
    /// Bracketed-paste content, newlines preserved.
    case paste(String)

    /// The same event with a Cyrillic letter replaced by the Latin one on that key. For
    /// key bindings only: text entry must take the raw event first.
    var command: KeyEvent {
        if case .char(let c) = self { return .char(Keys.latin(c)) }
        return self
    }
}

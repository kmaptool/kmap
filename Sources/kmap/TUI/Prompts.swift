import Foundation

/// The key handling shared by list screens: a search box, a single-line text entry and a
/// yes/no question.

/// A filter being typed over a list.
struct SearchPrompt {
    var query = ""
    /// Whether the box is taking keys; a query stays applied after it closes.
    var open = false

    enum Outcome {
        /// The query changed; the list should start from the top.
        case changed
        /// Enter: the query stays applied, the keys go back to the list.
        case closed
        /// Esc: the query is discarded.
        case cleared
        case unchanged
        case quit
    }

    mutating func handle(_ key: KeyEvent) -> Outcome {
        switch key {
        case .char(let c):
            query.append(c)
            return .changed
        case .paste(let text):
            query += text.replacingOccurrences(of: "\n", with: " ")
            return .changed
        case .backspace:
            guard !query.isEmpty else { return .unchanged }
            query.removeLast()
            return .changed
        case .enter:
            open = false
            return .closed
        case .esc:
            open = false
            query = ""
            return .cleared
        case .ctrl("c"):
            return .quit
        default:
            return .unchanged
        }
    }
}

/// A single line of text being typed. Pasted newlines are stripped.
struct TextPrompt {
    var text = ""

    enum Outcome {
        case typing
        /// Enter, carrying the text with surrounding whitespace trimmed.
        case accepted(String)
        case cancelled
        case quit
    }

    mutating func handle(_ key: KeyEvent) -> Outcome {
        switch key {
        case .char(let c):
            text.append(c)
            return .typing
        case .paste(let pasted):
            text += pasted.replacingOccurrences(of: "\n", with: "")
            return .typing
        case .backspace:
            if !text.isEmpty { text.removeLast() }
            return .typing
        case .esc:
            text = ""
            return .cancelled
        case .enter:
            let wanted = text.trimmingCharacters(in: .whitespaces)
            text = ""
            return .accepted(wanted)
        case .ctrl("c"):
            return .quit
        default:
            return .typing
        }
    }
}

/// A yes/no question. `y` on any layout is yes; `n` and Esc are no; any other key
/// returns nil and leaves the question open.
enum YesNo {
    enum Answer { case yes, no, quit }

    static func answer(_ key: KeyEvent) -> Answer? {
        switch key {
        case .char(let c) where Keys.latin(c) == "y": return .yes
        case .char(let c) where Keys.latin(c) == "n": return .no
        case .esc: return .no
        case .ctrl("c"): return .quit
        default: return nil
        }
    }
}

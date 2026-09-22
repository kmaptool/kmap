import Foundation

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

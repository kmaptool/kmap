import Foundation

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

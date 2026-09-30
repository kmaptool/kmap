import Foundation

/// A list narrowed by what is typed: the query, the cursor, and the keys both answer to.
/// Letters go into the query, so a screen using one has no lettered commands.
struct TypedFilter {
    var query = ""
    var list = ListState()

    var isEmpty: Bool { query.isEmpty }

    /// Whether any of `fields` contains the query, case aside.
    func matches(_ fields: [String]) -> Bool {
        let q = query.lowercased()
        return fields.contains { $0.lowercased().contains(q) }
    }

    /// Cursor keys, typing and deleting. False for a key the list has no use for.
    mutating func take(_ key: KeyEvent, count: Int) -> Bool {
        switch key {
        case .up: list.move(-1, count: count)
        case .down: list.move(1, count: count)
        case .pageUp: list.page(-1, count: count)
        case .pageDown: list.page(1, count: count)
        case .home: list.jump(to: 0, count: count)
        case .end: list.jump(to: count - 1, count: count)
        case .backspace:
            guard !query.isEmpty else { return true }
            query.removeLast()
            list.selected = 0
        case .char(let c):
            query.append(c)
            list.selected = 0
        case .paste(let text):
            query += text.replacingOccurrences(of: "\n", with: "")
            list.selected = 0
        default: return false
        }
        return true
    }

    /// Esc with a query drops it instead of leaving the screen. True if it did.
    mutating func clear() -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
        list.selected = 0
        return true
    }

    mutating func reset() {
        query = ""
        list = ListState()
    }

    var nothingMatches: String { t("nothing matches \"%@\"", query) }

    /// The filter line with a note at the right, and the rule under it. Returns the row
    /// under the rule.
    func drawHeader(
        into s: Surface,
        trailing: String,
        trailingStyle: Style,
        rect: Rect,
        y: Int,
        theme: Theme
    ) -> Int {
        s.filterHeader(
            query: query,
            trailing: trailing,
            trailingStyle: trailingStyle,
            rect: rect,
            y: y,
            theme: theme
        )
    }
}

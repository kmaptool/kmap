import Foundation

/// What every list screen does with its search box, in one place.
extension SearchPrompt {
    /// Shown while the query is typed or kept.
    var showing: Bool { open || !query.isEmpty }

    var subject: String? { showing ? t("search") : nil }

    /// The footer while the box takes keys.
    var hints: [Hint] {
        [Hint(key: Glyph.enter, label: t("keep")), Hint(key: "esc", label: t("clear"))]
    }

    /// Routes a key to the open box. A changed query starts the list from the top.
    mutating func take(_ key: KeyEvent, list: inout ListState) -> Route {
        switch handle(key) {
        case .changed, .cleared: list.selected = 0
        case .quit: return .quit
        case .closed, .unchanged: break
        }
        return .none
    }

    /// Esc with a kept query drops it instead of leaving the screen. True if it did.
    mutating func drop(list: inout ListState) -> Bool {
        guard !query.isEmpty else { return false }
        query = ""
        list.selected = 0
        return true
    }

    /// Draws `search: query`, with the cursor while the box is open. Returns the x after it.
    @discardableResult
    func draw(into s: Surface, x: Int, y: Int, theme: Theme) -> Int {
        var end = s.text(x, y, t("search") + ": ", Style(fg: theme.dim, bg: theme.appBg))
        end = s.text(end, y, query, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        if open {
            s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
            end += 1
        }
        return end
    }

    var nothingMatches: String { t("nothing matches \"%@\"", query) }
}

import Foundation

/// The lines every screen draws the same way: wrapped prose, a typed value with its
/// cursor, a filter header, and the status line at the bottom.
extension Surface {
    /// Wrapped prose from `y` down, one row per line. Stops short of `maxY` where one is
    /// given. Returns the next free row.
    @discardableResult
    func paragraph(
        _ text: String,
        x: Int,
        y: Int,
        width: Int,
        style: Style,
        maxY: Int = .max
    ) -> Int {
        var y = y
        for chunk in wrapText(text, width: width) {
            guard y < maxY else { break }
            self.text(x, y, chunk, style)
            y += 1
        }
        return y
    }

    /// `label` then the draft being typed, with the cursor after it. Returns the x after
    /// the draft.
    @discardableResult
    func prompt(_ label: String, draft: String, x: Int, y: Int, labelStyle: Style, theme: Theme) -> Int {
        let start = text(x, y, label, labelStyle)
        let end = text(start, y, draft, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        return end
    }

    /// `filter: query|`, a note at the right edge, and the rule under both. Returns the
    /// row under the rule.
    func filterHeader(
        query: String,
        trailing: String,
        trailingStyle: Style,
        rect: Rect,
        y: Int,
        theme: Theme
    ) -> Int {
        prompt(
            t("filter") + ": ",
            draft: query,
            x: rect.x,
            y: y,
            labelStyle: Style(fg: theme.dim, bg: theme.appBg),
            theme: theme
        )
        textRight(rect.maxX, y, trailing, trailingStyle)
        hline(rect.x, y + 1, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        return y + 2
    }

    /// The screen's last row: what it has to say, in green, or red for an error.
    func statusLine(_ message: String?, isError: Bool = false, rect: Rect, theme: Theme) {
        guard let message else { return }
        text(
            rect.x,
            rect.maxY - 1,
            truncate(message, to: rect.w),
            Style(fg: isError ? theme.danger : theme.ok, bg: theme.appBg)
        )
    }
}

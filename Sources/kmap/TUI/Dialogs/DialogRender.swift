import Foundation

/// The dialog on screen: a box of the tone's colours, the wrapped body, the detail rows
/// and the two buttons.
extension Dialog {
    /// The box width, between these two, leaving a margin on either side.
    private static let narrowest = 24, widest = 76, margin = 8
    /// Columns the borders and the text inset take from the width.
    private static let inset = 6
    /// The label column of a detail row is at least this wide, and never more than half
    /// the box, so a long label is truncated rather than crowding out the value.
    private static let labelColumnFloor = 12

    private struct Colours {
        let fill: Color, edge: Color, ink: Color, quiet: Color
    }

    /// Fill, edge and text colours for the tone, independent of the theme.
    private var colours: Colours {
        switch tone {
        case .danger:
            return Colours(
                fill: .rgb(122, 16, 16),
                edge: .rgb(214, 60, 60),
                ink: .rgb(255, 255, 255),
                quiet: .rgb(246, 196, 196)
            )
        case .plain:
            return Colours(fill: .xterm(236), edge: .xterm(240), ink: .xterm(255), quiet: .xterm(250))
        }
    }

    private func width(in rect: Rect) -> Int {
        max(Self.narrowest, min(rect.w - Self.margin, Self.widest))
    }

    private func lines(in rect: Rect) -> [String] {
        let inner = width(in: rect) - Self.inset
        var out: [String] = []
        for (i, paragraph) in body.enumerated() {
            if i > 0 { out.append("") }
            out += wrapText(paragraph, width: inner)
        }
        return out
    }

    /// The box height for the wrapped contents, capped at the height available.
    func height(in rect: Rect) -> Int {
        // Border, title, rule, body, blank, detail, blank, buttons, border.
        var rows = 2 + 2 + lines(in: rect).count + 2
        if !detail.isEmpty { rows += detail.count + 1 }
        return min(rect.h, rows)
    }

    func render(into s: Surface, rect: Rect, theme: Theme) {
        let w = width(in: rect)
        let h = height(in: rect)
        let box = Rect(x: rect.x + (rect.w - w) / 2, y: rect.y + max(0, (rect.h - h) / 2), w: w, h: h)
        let c = colours

        s.fill(box, Style(fg: c.ink, bg: c.fill))
        s.box(box, Style(fg: c.edge, bg: c.fill))

        var y = box.y + 1
        s.text(box.x + 3, y, title.uppercased(), Style(fg: c.ink, bg: c.fill, bold: true))
        y += 1
        s.hline(box.x + 1, y, box.w - 2, Glyph.h, Style(fg: c.edge, bg: c.fill))
        y += 1

        // When the body does not fit, the last visible row is replaced by an ellipsis.
        let text = lines(in: rect)
        for (at, line) in text.enumerated() {
            guard y < box.maxY - 2 else { break }
            let last = y == box.maxY - 3 && at < text.count - 1
            s.text(box.x + 3, y, last ? String(Glyph.ellipsis) : line, Style(fg: c.ink, bg: c.fill))
            y += 1
        }

        if !detail.isEmpty {
            y += 1
            let widest = detail.map(\.label.count).max() ?? 0
            let labelWidth = min(widest + 2, max(Self.labelColumnFloor, (box.w - Self.inset) / 2))
            for row in detail {
                guard y < box.maxY - 2 else { break }
                s.text(box.x + 3, y, truncate(row.label, to: labelWidth - 1), Style(fg: c.quiet, bg: c.fill))
                s.text(
                    box.x + 3 + labelWidth,
                    y,
                    truncate(row.value, to: max(0, box.maxX - box.x - 4 - labelWidth)),
                    Style(fg: c.ink, bg: c.fill, bold: true)
                )
                y += 1
            }
        }

        drawButtons(into: s, box: box, colours: c)
    }

    /// Both buttons right-aligned on the bottom row, cancel first.
    private func drawButtons(into s: Surface, box: Rect, colours c: Colours) {
        let y = box.maxY - 2
        let labels = [(cancel, Focus.cancel), (confirm, Focus.confirm)]
        // A label is drawn with a two-cell mark before it and two cells after.
        let widths = labels.map { $0.0.count + 4 }
        var x = box.maxX - 3 - widths.reduce(0, +) - (widths.count - 1) * 2
        for entry in labels {
            let picked = focus == entry.1
            let style = picked ? Style(fg: c.fill, bg: c.ink, bold: true) : Style(fg: c.ink, bg: c.fill)
            let label = (picked ? "▸ " : "  ") + entry.0 + "  "
            s.fill(Rect(x: x, y: y, w: label.count, h: 1), style)
            s.text(x, y, label, style)
            x += label.count + 2
        }
    }
}

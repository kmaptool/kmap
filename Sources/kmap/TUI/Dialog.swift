import Foundation

/// A modal question drawn over the screen, with a title, wrapped body paragraphs, optional
/// label/value rows, and two buttons. The cursor starts on cancel, so confirming needs a
/// deliberate move.
struct Dialog {

    enum Outcome: Equatable {
        case none
        case confirmed
        case cancelled
    }

    /// How the box is coloured: `danger` fills red, `plain` uses the interface greys.
    enum Tone {
        case danger
        case plain
    }

    enum Focus { case cancel, confirm }

    let title: String
    /// Paragraphs, wrapped to the box.
    let body: [String]
    /// Label and value rows drawn below the body.
    let detail: [(label: String, value: String)]
    let confirm: String
    let cancel: String
    let tone: Tone

    /// Which button has the cursor. Starts on cancel.
    private(set) var focus: Focus = .cancel

    init(title: String, body: [String], detail: [(label: String, value: String)] = [],
         confirm: String, cancel: String, tone: Tone = .danger) {
        self.title = title
        self.body = body
        self.detail = detail
        self.confirm = confirm
        self.cancel = cancel
        self.tone = tone
    }

    /// Footer hints for the current focus. The Esc hint appears only while the cursor is
    /// on confirm.
    var footerHints: [Hint] {
        var hints = [Hint(key: "←→", label: t("choose")),
                     Hint(key: Glyph.enter, label: focus == .confirm ? confirm : cancel)]
        if focus == .confirm { hints.append(Hint(key: "esc", label: cancel)) }
        return hints
    }

    // MARK: Input

    mutating func handle(_ key: KeyEvent) -> Outcome {
        switch key {
        case .left, .right, .tab, .backTab:
            focus = focus == .cancel ? .confirm : .cancel
        case .enter, .char(" "):
            return focus == .confirm ? .confirmed : .cancelled
        case .esc, .ctrl("c"):
            return .cancelled
        default:
            break
        }
        return .none
    }

    // MARK: Drawing

    /// Fill, edge and text colours for the tone, independent of the theme.
    private var colours: (fill: Color, edge: Color, ink: Color, quiet: Color) {
        switch tone {
        case .danger:
            return (fill: .rgb(122, 16, 16), edge: .rgb(214, 60, 60),
                    ink: .rgb(255, 255, 255), quiet: .rgb(246, 196, 196))
        case .plain:
            return (fill: .xterm(236), edge: .xterm(240),
                    ink: .xterm(255), quiet: .xterm(250))
        }
    }

    /// The box width for the space available, between 24 and 76 columns.
    private func width(in rect: Rect) -> Int {
        max(24, min(rect.w - 8, 76))
    }

    private func lines(in rect: Rect) -> [String] {
        let inner = width(in: rect) - 6
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
        let box = Rect(x: rect.x + (rect.w - w) / 2,
                       y: rect.y + max(0, (rect.h - h) / 2),
                       w: w, h: h)
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
            s.text(box.x + 3, y, last ? "…" : line, Style(fg: c.ink, bg: c.fill))
            y += 1
        }

        if !detail.isEmpty {
            y += 1
            // The label column is capped at half the box, so a long label is truncated
            // rather than crowding out the value.
            let widest = detail.map(\.label.count).max() ?? 0
            let labelWidth = min(widest + 2, max(12, (box.w - 6) / 2))
            for row in detail {
                guard y < box.maxY - 2 else { break }
                s.text(box.x + 3, y, truncate(row.label, to: labelWidth - 1),
                       Style(fg: c.quiet, bg: c.fill))
                s.text(box.x + 3 + labelWidth, y,
                       truncate(row.value, to: max(0, box.maxX - box.x - 4 - labelWidth)),
                       Style(fg: c.ink, bg: c.fill, bold: true))
                y += 1
            }
        }

        drawButtons(into: s, box: box, colours: c)
    }

    /// Draws both buttons right-aligned on the bottom row, cancel first.
    private func drawButtons(into s: Surface, box: Rect,
                             colours c: (fill: Color, edge: Color, ink: Color, quiet: Color)) {
        let y = box.maxY - 2
        let labels = [(cancel, Focus.cancel), (confirm, Focus.confirm)]
        var widths = labels.map { $0.0.count + 4 }
        // Both buttons and a gap, right-aligned inside the box.
        var x = box.maxX - 3 - widths.reduce(0, +) - (widths.count - 1) * 2
        for (i, entry) in labels.enumerated() {
            let picked = focus == entry.1
            let style = picked
                ? Style(fg: c.fill, bg: c.ink, bold: true)
                : Style(fg: c.ink, bg: c.fill)
            let label = (picked ? "▸ " : "  ") + entry.0 + "  "
            widths[i] = label.count
            s.fill(Rect(x: x, y: y, w: label.count, h: 1), style)
            s.text(x, y, label, style)
            x += label.count + 2
        }
    }
}

import Foundation

/// The order polygons are painted in: which fill lies over which. Read-only. Level 1 is
/// painted first and every later level covers it, so the list reads from the bottom of
/// the stack downward.
final class DrawOrderScreen: Screen {
    var page: Page {
        Page(t("draw order"), subject: document.style.name,
             keys: [Hint(key: "↑↓", label: t("scroll")), Hint(key: "esc", label: t("back"))])
    }

    private let document: StyleDocument
    private var scroll = 0

    init(document: StyleDocument) {
        self.document = document
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch key.command {
        case .up, .char("k"): scroll = max(0, scroll - 1)
        case .down, .char("j"): scroll += 1
        case .pageUp: scroll = max(0, scroll - 10)
        case .pageDown: scroll += 10
        case .home: scroll = 0
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        guard let source = document.source, !source.drawOrder.isEmpty else {
            s.text(rect.x, rect.y, t("this TYP declares no draw order"),
                   Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        // One line per entry, grouped by level, flattened so scrolling is line counting.
        var lines: [(level: Int?, code: Int?)] = []
        var level = Int.min
        for entry in source.drawOrder {
            if entry.level != level {
                level = entry.level
                lines.append((level, nil))
            }
            lines.append((nil, entry.code))
        }

        var y = rect.y
        let intro = t("Polygons are painted level by level: level 1 first, every later"
                    + " level on top of it. Within a level the order does not matter.")
        for chunk in wrapText(intro, width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        let visible = max(1, rect.maxY - y)
        scroll = max(0, min(scroll, max(0, lines.count - visible)))

        for (i, line) in lines.dropFirst(scroll).prefix(visible).enumerated() {
            let row = y + i
            if let level = line.level {
                s.sectionRule(rect, row, t("level %d", level),
                              labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                              ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
                continue
            }
            guard let code = line.code else { continue }
            var x = s.text(rect.x + 2, row, String(format: "0x%02x", code),
                           Style(fg: theme.dim, bg: theme.appBg))
            let section = source.section(.polygon, code)
            x = Widgets.swatch(s, x: x + 2, y: row,
                               colour: section?.representativeColours.day,
                               width: 3, theme: theme)
            let name = section?.label(language: L10n.current == .ru ? 0x04 : 0x00)
                ?? section?.label(language: 0x00)
            s.text(x + 2, row,
                   name ?? t("not styled by this TYP — the device draws its own"),
                   Style(fg: name == nil ? theme.faint : theme.text, bg: theme.appBg),
                   limit: max(0, rect.maxX - x - 2))
        }

        if lines.count > visible {
            Widgets.scrollHint(s, rect: Rect(x: rect.x, y: y, w: rect.w, h: visible),
                               offset: scroll, count: lines.count,
                               visible: visible, theme: theme)
        }
    }
}

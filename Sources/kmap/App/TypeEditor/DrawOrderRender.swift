import Foundation

/// Drawing the draw order: a caption per level and one row per polygon.
extension DrawOrderScreen {
    private static let leastWidthForTags = 60

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let rows = self.rows
        guard let source = document.source, !rows.isEmpty else {
            s.text(rect.x, rect.y, t("this TYP declares no draw order"), Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        var y = s.paragraph(
            t(
                "Polygons are painted level by level: level 1 first, every later level on top of it. Within a level the order does not matter."
            ),
            x: rect.x,
            y: rect.y,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1

        // The last line holds the message or the prompt.
        let visible = max(1, rect.maxY - y - 1)
        if rows[safe: list.selected]?.code == nil { settle(forward: true) }
        let rowRect = Rect(x: rect.x, y: rect.y, w: rect.w - 1, h: rect.h)
        for index in list.window(count: rows.count, visible: visible) {
            let line = y + index - list.offset
            switch rows[index] {
            case .caption(let caption):
                s.sectionRule(
                    rect,
                    line,
                    caption,
                    labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                    ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
                )
            case .polygon(let code, let level):
                draw(
                    code: code,
                    drawn: level != nil,
                    in: source,
                    into: s,
                    rect: rowRect,
                    y: line,
                    theme: theme,
                    selected: index == list.selected
                )
            }
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: y, w: rect.w, h: visible),
            offset: list.offset,
            count: rows.count,
            visible: visible,
            theme: theme
        )

        if typing {
            s.prompt(
                t("move to level") + ": ",
                draft: level.text,
                x: rect.x,
                y: rect.maxY - 1,
                labelStyle: Style(fg: theme.text, bg: theme.appBg),
                theme: theme
            )
        } else {
            notice.draw(into: s, rect: rect, theme: theme)
        }
    }

    /// Code, day colour, name, and at the right the tag the rules draw it for.
    private func draw(
        code: Int,
        drawn: Bool,
        in source: TypSource,
        into s: Surface,
        rect: Rect,
        y: Int,
        theme: Theme,
        selected: Bool
    ) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        s.text(rect.x, y, selected ? "\(Glyph.arrowRight) " : "  ", Style(fg: theme.accent, bg: bg))

        var x = s.text(rect.x + 2, y, String(format: "0x%02x", code), Style(fg: theme.dim, bg: bg))
        let section = source.section(.polygon, code)
        x = Widgets.swatch(s, x: x + 2, y: y, colour: section?.representativeColours.day, width: 3, theme: theme)

        let name = (L10n.current == .ru ? section?.russianLabel : nil) ?? section?.englishLabel
        let text = name ?? (drawn ? t("not styled by this TYP — the device draws its own") : t("no name"))
        var limit = rect.maxX - x - 2
        if let tag = tagsByCode[code], rect.w > Self.leastWidthForTags {
            let width = min(tag.count, rect.w / 3)
            s.textRight(rect.maxX, y, truncate(tag, to: width), Style(fg: theme.faint, bg: bg))
            limit -= width + 2
        }
        s.text(x + 2, y, text, Style(fg: name == nil ? theme.faint : theme.text, bg: bg), limit: max(0, limit))
    }
}

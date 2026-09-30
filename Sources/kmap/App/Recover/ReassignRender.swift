import Foundation

/// Drawing the three stages of a reassignment: the feature, the rule, the target.
extension ReassignScreen {
    private static let hexColumn = 8
    private static let nameColumn = 26
    /// Rows under the target list for the warnings about the selected code.
    private static let noteRows = 6

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        switch stage {
        case .source: renderSources(s, rect: rect, theme: ctx.theme)
        case .rule: renderRules(s, rect: rect, theme: ctx.theme)
        case .target: renderTargets(s, rect: rect, theme: ctx.theme)
        }
    }

    private func renderSources(_ s: Surface, rect: Rect, theme: Theme) {
        var y = s.paragraph(
            t(
                "%@ is free. Pick the feature to bind to it — its rule moves here and takes effect on the next build.",
                TypeMeaning.hex(fixedTarget ?? code)
            ),
            x: rect.x,
            y: rect.y,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1
        let shown = sources
        y = filter.drawHeader(
            into: s,
            trailing: tn("%d feature(s)", shown.count),
            trailingStyle: Style(fg: theme.faint, bg: theme.appBg),
            rect: rect,
            y: y,
            theme: theme
        )
        guard !shown.isEmpty else {
            s.text(rect.x, y, t("nothing matches"), Style(fg: theme.faint, bg: theme.appBg))
            return
        }
        for index in filter.list.window(count: shown.count, visible: max(1, rect.maxY - y - 1)) {
            let row = shown[index]
            let line = y + index - filter.list.offset
            Widgets.row(
                s,
                rect: Rect(x: rect.x, y: line, w: rect.w, h: 1),
                y: line,
                text: "\(row.hex)  \(row.name(preferringRussian: true))",
                trailing: truncate(row.tags.joined(separator: ", "), to: rect.w / 2),
                theme: theme,
                selected: index == filter.list.selected
            )
        }
        notice.draw(into: s, rect: rect, theme: theme)
    }

    private func renderRules(_ s: Surface, rect: Rect, theme: Theme) {
        let rules = self.rules
        var y = s.paragraph(
            t(
                "Moving a rule changes which Garmin type the thing gets — the "
                    + "map, not the drawing. It takes effect on the next build, "
                    + "and undoing it puts the rule back where mkgmap had it."
            ),
            x: rect.x,
            y: rect.y,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1
        s.text(
            rect.x,
            y,
            tn("%2$@ is emitted by %1$d rule(s):", rules.count, TypeMeaning.hex(code)),
            Style(fg: theme.text, bg: theme.appBg)
        )
        y += 1

        guard !rules.isEmpty else {
            s.text(
                rect.x,
                y,
                t("no rule in this style emits it — nothing to move"),
                Style(fg: theme.warn, bg: theme.appBg)
            )
            return
        }
        for index in filter.list.window(count: rules.count, visible: max(1, rect.maxY - y - 1)) {
            guard y < rect.maxY - 1 else { break }
            let rule = rules[index]
            Widgets.row(
                s,
                rect: Rect(x: rect.x, y: y, w: rect.w, h: 1),
                y: y,
                text: rule.condition,
                trailing: rule.tail,
                theme: theme,
                selected: index == filter.list.selected
            )
            y += 1
        }
        notice.draw(into: s, rect: rect, theme: theme)
    }

    private func renderTargets(_ s: Surface, rect: Rect, theme: Theme) {
        var y = rect.y
        if let chosen {
            let x = s.text(rect.x, y, t("moving") + " ", Style(fg: theme.dim, bg: theme.appBg))
            s.text(
                x,
                y,
                truncate(chosen.condition, to: max(0, rect.maxX - x - 12)),
                Style(fg: theme.text, bg: theme.appBg)
            )
            s.textRight(rect.maxX, y, t("off %@", TypeMeaning.hex(code)), Style(fg: theme.dim, bg: theme.appBg))
            y += 1
        }

        if typing {
            drawTypedTarget(into: s, rect: rect, y: y, theme: theme)
            notice.draw(into: s, rect: rect, theme: theme)
            return
        }

        let shown = targets
        y = filter.drawHeader(
            into: s,
            trailing: tn("%d known code(s)", shown.count),
            trailingStyle: Style(fg: theme.faint, bg: theme.appBg),
            rect: rect,
            y: y,
            theme: theme
        )
        guard !shown.isEmpty else {
            s.text(
                rect.x,
                y,
                t("nothing matches — press ⇥ to type a code instead"),
                Style(fg: theme.faint, bg: theme.appBg)
            )
            return
        }

        let listHeight = max(1, rect.maxY - y - Self.noteRows - 1)
        let listTop = y
        for index in filter.list.window(count: shown.count, visible: listHeight) {
            drawTarget(shown[index], into: s, rect: rect, y: y, theme: theme, selected: index == filter.list.selected)
            y += 1
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
            offset: filter.list.offset,
            count: shown.count,
            visible: listHeight,
            theme: theme
        )
        if let row = shown[safe: filter.list.selected] {
            s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
            _ = warnings(about: row.code, into: s, rect: rect, y: y + 1, theme: theme)
        }
        notice.draw(into: s, rect: rect, theme: theme)
    }

    /// The code being typed, and what moving onto it would mean once it parses.
    private func drawTypedTarget(into s: Surface, rect: Rect, y: Int, theme: Theme) {
        s.text(rect.x, y, t("New type code:"), Style(fg: theme.text, bg: theme.appBg))
        s.prompt(
            "",
            draft: typed,
            x: rect.x,
            y: y + 1,
            labelStyle: Style(fg: theme.text, bg: theme.appBg),
            theme: theme
        )
        if let target = Self.parseCode(typed) {
            _ = warnings(about: target, into: s, rect: rect, y: y + 3, theme: theme)
        } else {
            s.text(
                rect.x,
                y + 3,
                t("written the way the rule files write it, such as 0x2f01"),
                Style(fg: theme.faint, bg: theme.appBg)
            )
        }
    }

    private func drawTarget(_ row: StyleTypeRow, into s: Surface, rect: Rect, y: Int, theme: Theme, selected: Bool) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w - 1, h: 1), Style(fg: theme.text, bg: bg))
        var x = s.text(rect.x, y, selected ? "\(Glyph.arrowRight) " : "  ", Style(fg: theme.accent, bg: bg))
        x = s.text(
            x,
            y,
            row.hex.padding(toLength: Self.hexColumn, withPad: " ", startingAt: 0),
            Style(fg: row.isStyled ? theme.text : theme.faint, bg: bg)
        )
        x = s.text(
            x,
            y,
            truncate(row.name(preferringRussian: true), to: Self.nameColumn).padding(
                toLength: Self.nameColumn,
                withPad: " ",
                startingAt: 0
            ),
            Style(fg: theme.text, bg: bg, bold: selected)
        )
        let note = row.isStyled ? "" : t("device default")
        let room = max(0, rect.maxX - 1 - x - note.count - 2)
        s.text(x, y, truncate(row.tags.joined(separator: ", "), to: room), Style(fg: theme.faint, bg: bg))
        if !note.isEmpty {
            s.textRight(rect.maxX - 1, y, note, Style(fg: theme.warn, bg: bg))
        }
    }

    /// What moving onto this code would mean, said before the move.
    private func warnings(about target: Int, into s: Surface, rect: Rect, y: Int, theme: Theme) -> Int {
        var y = y
        let row = rows.first { $0.code == target }
        if kind == .point, !ReassignScreen.poiCardRange.contains(target >> 8), y < rect.maxY {
            s.text(
                rect.x,
                y,
                t("outside the POI range 0x2900–0x30ff — the device will draw it but show no card for it"),
                Style(fg: theme.danger, bg: theme.appBg)
            )
            y += 1
        }
        if row?.isStyled != true, y < rect.maxY {
            s.text(
                rect.x,
                y,
                t("this TYP has no section for it — the device draws its own idea"),
                Style(fg: theme.warn, bg: theme.appBg)
            )
            y += 1
        }
        if let row, !row.tags.isEmpty, y < rect.maxY {
            s.text(
                rect.x,
                y,
                truncate(t("already carries") + ": " + row.tags.joined(separator: ", "), to: rect.w),
                Style(fg: theme.dim, bg: theme.appBg)
            )
            y += 1
        }
        return y
    }
}

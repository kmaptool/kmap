import Foundation

/// Drawing the zoom grid: the rungs across the top, a bar per family, and the panel.
extension ZoomPlanEditScreen {
    private static let onRung = "███"
    private static let wasRung = "░░░"
    private static let noRung = " · "

    /// Where the columns of the grid sit.
    struct Grid {
        /// The least column width: a scale label still fits.
        static let leastStep = 4

        let x: Int, width: Int, count: Int
        var step: Int { max(Self.leastStep, count > 0 ? width / count : width) }
        func column(_ rung: Int) -> Int { x + rung * step }
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let (formRect, panel) = Layout.split(rect)
        let intro =
            plan.isBuiltin
            ? t(
                "This plan comes with kmap and cannot be edited. Copy it on the plans "
                    + "page, and the copy is yours to change."
            )
            : t(
                "Choose the zoom levels where each kind of feature is shown. Arrows "
                    + "move the cursor, space turns a level on or off; the range is always "
                    + "continuous."
            )
        var y = s.paragraph(
            intro,
            x: formRect.x,
            y: formRect.y,
            width: formRect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1

        fieldRows[Row.ladder.key] = y
        Widgets.field(
            s,
            rect: Rect(x: formRect.x, y: y, w: formRect.w, h: 1),
            y: y,
            label: t("Zoom levels"),
            value: levels.name,
            theme: theme,
            labelWidth: Layout.fieldLabel,
            selected: list.selected == 0
        )
        y += 2

        let rungs = self.rungs
        let gridX = formRect.x + 2 + Layout.fieldLabel
        let grid = Grid(x: gridX, width: formRect.maxX - gridX, count: rungs.bits.count)
        renderHeader(s, grid: grid, rungs: rungs, y: y, theme: theme)
        y += 1

        // The families, a window that keeps the cursor's row on screen; rows[0] is the ladder.
        let families = rows.count - 1
        let visible = max(1, formRect.maxY - 2 - y)
        let cursor = list.selected - 1
        if cursor >= 0, cursor < familyScroll { familyScroll = cursor }
        if cursor >= familyScroll + visible { familyScroll = cursor - visible + 1 }
        familyScroll = max(0, min(familyScroll, families - visible))
        let top = y
        for i in (familyScroll + 1)..<max(familyScroll + 1, min(rows.count, familyScroll + 1 + visible)) {
            guard case .family(let family) = rows[i] else { continue }
            fieldRows[rows[i].key] = y
            renderFamily(
                family,
                selected: i == list.selected,
                into: s,
                rect: formRect,
                y: y,
                grid: grid,
                rungs: rungs,
                theme: theme
            )
            y += 1
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: formRect.x, y: top, w: formRect.w, h: visible),
            offset: familyScroll,
            count: families,
            visible: visible,
            theme: theme
        )

        // Once under the grid rather than in every row.
        let note =
            survey?.isEmpty == false
            ? message : (message ?? t("no rule set on disk yet — build once and this fills in"))
        if let note, y + 1 < formRect.maxY {
            y =
                s.paragraph(
                    note,
                    x: formRect.x + 2,
                    y: y + 1,
                    width: formRect.w - 2,
                    style: Style(fg: theme.warn, bg: theme.appBg),
                    maxY: formRect.maxY
                ) - 1
        }

        guard let panel else { return }
        renderPanel(s, rect: panel, theme: theme)
    }

    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        changingLadder?.render(into: s, rect: rect, theme: ctx.theme)
        guard picking != nil, let at = fieldRows[Row.ladder.key] else { return }
        Widgets.optionList(
            s,
            within: Layout.split(rect).form,
            anchorRow: at,
            options: LevelsProfile.all.map(\.name),
            at: picking ?? 0,
            theme: ctx.theme
        )
    }

    private func renderFamily(
        _ family: ZoomFamily,
        selected: Bool,
        into s: Surface,
        rect: Rect,
        y: Int,
        grid: Grid,
        rungs: ZoomRungs,
        theme: Theme
    ) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        s.text(rect.x, y, selected ? "\(Glyph.arrowRight) " : "  ", Style(fg: theme.accent, bg: bg))
        s.text(
            rect.x + 2,
            y,
            family.name,
            Style(fg: selected ? theme.selectionFg : theme.text, bg: bg),
            limit: Layout.fieldLabel
        )
        renderBar(s, family: family, grid: grid, rungs: rungs, y: y, theme: theme, bg: bg, cursorHere: selected)
    }

    /// Each rung's map scale, or its index where there is no scale for it.
    private func renderHeader(_ s: Surface, grid: Grid, rungs: ZoomRungs, y: Int, theme: Theme) {
        for (rung, bits) in rungs.bits.enumerated() {
            let head = ZoomRungs.shortScale(bits: bits) ?? "\(rung)"
            s.text(
                grid.column(rung),
                y,
                head,
                Style(fg: rung == column ? theme.accent : theme.faint, bg: theme.appBg, bold: rung == column)
            )
        }
    }

    /// The rungs a family occupies, the style's own spread shaded behind where the plan
    /// has changed them.
    private func renderBar(
        _ s: Surface,
        family: ZoomFamily,
        grid: Grid,
        rungs: ZoomRungs,
        y: Int,
        theme: Theme,
        bg: Color,
        cursorHere: Bool
    ) {
        guard let survey, let spread = survey.spread(family) else {
            for rung in rungs.bits.indices {
                s.text(grid.column(rung), y, Self.noRung, Style(fg: theme.rule, bg: bg))
            }
            return
        }
        let now = window(family) ?? .init(finest: spread.finest, coarsest: spread.coarsest)
        let changed = plan.window(family) != nil

        for rung in rungs.bits.indices {
            let glyph: String
            let colour: Color
            if now.contains(rung) {
                glyph = Self.onRung
                colour = changed ? theme.ok : theme.text
            } else if rung >= spread.finest && rung <= spread.coarsest {
                glyph = Self.wasRung
                colour = theme.faint
            } else {
                glyph = Self.noRung
                colour = theme.rule
            }
            let onCursor = cursorHere && rung == column
            s.text(
                grid.column(rung),
                y,
                glyph,
                Style(fg: onCursor ? theme.strong : colour, bg: onCursor ? theme.raisedBg : bg, bold: onCursor)
            )
        }
    }

    private func renderPanel(_ s: Surface, rect: Rect, theme: Theme) {
        s.vline(rect.x - 2, rect.y, rect.h, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))
        var column = SummaryColumn(s: s, rect: rect, theme: theme, y: rect.y)

        if case .family(let family)? = rows[safe: list.selected] {
            column.caption(family.name.uppercased())
            column.line(family.note, tone: theme.dim)
            column.gap()
            if let survey, let spread = survey.spread(family) {
                if let now = window(family) {
                    column.line(survey.startsAt(rung: now.rungs.upperBound))
                    if now.rungs.lowerBound > 0 {
                        column.line(survey.stopsAt(rung: now.rungs.lowerBound), tone: theme.dim)
                    }
                }
                if plan.window(family) != nil {
                    column.line(t("as it comes: %@", survey.rungLabel(spread.coarsest)), tone: theme.faint)
                }
                column.line(tn("%d rule(s) in the style", spread.rules), tone: theme.faint)
            } else {
                column.line(t("no rule set on disk yet — build once and this fills in"), tone: theme.faint)
            }
            column.gap()
        }

        column.caption(t("zoom levels"))
        for (i, bits) in rungs.bits.enumerated() {
            guard column.y < rect.maxY else { return }
            let scale = ZoomRungs.scale(bits: bits).map { "  ·  " + $0 } ?? ""
            s.text(
                rect.x,
                column.y,
                t("level %d", i) + scale,
                Style(fg: i == self.column ? theme.text : theme.faint, bg: theme.appBg)
            )
            column.y += 1
        }
    }
}

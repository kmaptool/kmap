import Foundation

/// Edits which rungs of the ladder each family of features is drawn on.
///
/// A grid: families down the side, the ladder's rungs across the top. The rungs themselves
/// are fixed, since every `resolution` in the rule set is written against them. Space adds
/// or removes the rung under the cursor, always leaving a continuous run. See `ZoomPlan`.
final class ZoomPlanEditScreen: Screen {
    var page: Page { Page(t("zoom plan"), subject: t(plan.name), keys: keys) }

    private var keys: [Hint] {
        if picking != nil {
            return [Hint(key: "↑↓", label: t("move")),
                    Hint(key: Glyph.enter, label: t("take it")),
                    Hint(key: "esc", label: t("cancel"))]
        }
        if plan.isBuiltin {
            return [Hint(key: "↑↓", label: t("move")), Hint(key: "esc", label: t("back"))]
        }
        return [Hint(key: "↑↓←→", label: t("move")),
                Hint(key: "space", label: t("add / remove")),
                Hint(key: "0", label: t("as it comes")),
                Hint(key: "esc", label: t("back"))]
    }

    /// What the screen lists, the ladder first: every row under it is counted in its rungs.
    enum Row: Equatable {
        case ladder
        case family(ZoomFamily)

        var key: String {
            switch self {
            case .ladder: return "#ladder"
            case .family(let f): return f.id
            }
        }
    }

    private var plan: ZoomPlan
    private let settings: SettingsStore
    private var list = ListState()
    /// Which rung the cursor is on, kept across rows so moving down stays in one column.
    private var column = 0
    private var survey: ZoomSurvey?
    private var message: String?
    /// The ladder row's open list.
    private var picking: Int?
    /// The screen row each field was drawn on, so an open list can be anchored to it.
    private var fieldRows: [String: Int] = [:]

    init(plan: ZoomPlan, settings: SettingsStore) {
        self.plan = plan
        self.settings = settings
    }

    private var levels: LevelsProfile {
        LevelsProfile.all.first { $0.id == plan.levelsID } ?? .smooth
    }

    private var rungs: ZoomRungs { ZoomRungs(levels: levels.levels) }
    private var rows: [Row] { [.ladder] + ZoomFamily.all.map(Row.family) }

    func tick(_ ctx: AppContext) {
        // Surveyed once: the rule set does not change while this screen is open.
        if survey == nil {
            survey = ZoomSurvey(styleAt: StyleCatalog.baseStyleDirectory, levels: levels)
        }
    }

    /// The rungs a family occupies: the plan's window, else the style's own spread.
    private func window(_ family: ZoomFamily) -> ZoomPlan.Window? {
        if let asked = plan.window(family) { return asked }
        guard let spread = survey?.spread(family) else { return nil }
        return ZoomPlan.Window(finest: spread.finest, coarsest: spread.coarsest)
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if picking != nil { return handlePicking(key) }
        let rows = self.rows
        switch key {
        case .up: list.move(-1, count: rows.count)
        case .down: list.move(1, count: rows.count)
        case .home: list.jump(to: 0, count: rows.count)
        case .end: list.jump(to: rows.count - 1, count: rows.count)
        case .left: column = max(0, column - 1)
        case .right: column = min(rungs.bits.count - 1, column + 1)

        case .enter:
            guard case .ladder? = rows[safe: list.selected] else { return .none }
            guard !plan.isBuiltin else { return refuse() }
            picking = LevelsProfile.all.firstIndex { $0.id == plan.levelsID } ?? 0
            message = nil

        case .char(let typed) where typed == " ":
            toggle()
        case .char(let typed) where Keys.latin(typed) == "0":
            guard !plan.isBuiltin else { return refuse() }
            guard case .family(let family)? = rows[safe: list.selected] else { return .none }
            plan.setWindow(nil, for: family)
            settings.saveZoomPlan(plan)
            message = nil

        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    private func refuse() -> Route {
        message = t("this plan ships with kmap — copy it to make changes")
        return .none
    }

    /// Adds the rung under the cursor to the family's window, or removes it. A window is a
    /// continuous run: adding beyond the far end fills the gap, and removing from the middle
    /// drops the shorter side, since the rule syntax cannot express a gap.
    private func toggle() {
        guard !plan.isBuiltin else { _ = refuse(); return }
        guard case .family(let family)? = rows[safe: list.selected] else { return }
        guard let now = window(family) else {
            message = t("no rule set on disk yet — build once and this fills in")
            return
        }
        let rung = column
        var next = now
        if now.contains(rung) {
            guard now.count > 1 else {
                // Removing a family entirely is the hide catalogue's job: it takes the type
                // off the rule and keeps its actions.
                message = t("a family has to be drawn somewhere — use Hide on map instead")
                return
            }
            if rung == now.rungs.lowerBound {
                next = .init(finest: rung + 1, coarsest: now.rungs.upperBound)
            } else if rung == now.rungs.upperBound {
                next = .init(finest: now.rungs.lowerBound, coarsest: rung - 1)
            } else if rung - now.rungs.lowerBound <= now.rungs.upperBound - rung {
                next = .init(finest: rung + 1, coarsest: now.rungs.upperBound)
            } else {
                next = .init(finest: now.rungs.lowerBound, coarsest: rung - 1)
            }
        } else if rung < now.rungs.lowerBound {
            next = .init(finest: rung, coarsest: now.rungs.upperBound)
        } else {
            next = .init(finest: now.rungs.lowerBound, coarsest: rung)
        }

        // A window matching the style's own spread is stored as nil, so the plan holds only
        // deliberate changes.
        if let spread = survey?.spread(family),
           next.rungs.lowerBound == spread.finest, next.rungs.upperBound == spread.coarsest {
            plan.setWindow(nil, for: family)
        } else {
            plan.setWindow(next, for: family)
        }
        settings.saveZoomPlan(plan)
        message = nil
    }

    private func handlePicking(_ key: KeyEvent) -> Route {
        guard var at = picking else { return .none }
        switch key {
        case .up: at = max(0, at - 1); picking = at
        case .down: at = min(LevelsProfile.all.count - 1, at + 1); picking = at
        case .enter:
            picking = nil
            setLadder(LevelsProfile.all[at])
        case .esc: picking = nil
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// Puts the plan on another ladder, dropping every window: a window is a pair of indexes
    /// into one ladder, and the same index means a different rung on another.
    private func setLadder(_ ladder: LevelsProfile) {
        guard ladder.id != plan.levelsID else { return }
        plan.levelsID = ladder.id
        plan.windows = [:]
        settings.saveZoomPlan(plan)
        survey = nil
        column = 0
        message = t("moved to %@ — the rows are back to what the style does", ladder.name)
    }

    // MARK: Drawing

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let (formRect, panel) = Layout.split(rect)
        var y = formRect.y

        let intro = plan.isBuiltin
            ? t("This plan comes with kmap and cannot be edited. Copy it on the plans "
              + "page, and the copy is yours to change.")
            : t("Choose the zoom levels where each kind of feature is shown. Arrows "
              + "move the cursor, space turns a level on or off; the range is always "
              + "continuous.")
        for chunk in wrapText(intro, width: formRect.w) {
            s.text(formRect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1

        fieldRows[Row.ladder.key] = y
        Widgets.field(s, rect: Rect(x: formRect.x, y: y, w: formRect.w, h: 1), y: y,
                      label: t("Zoom levels"), value: levels.name,
                      theme: theme, labelWidth: Layout.fieldLabel,
                      selected: list.selected == 0)
        y += 2

        let rungs = self.rungs
        let grid = Grid(x: formRect.x + 2 + Layout.fieldLabel,
                        width: formRect.maxX - (formRect.x + 2 + Layout.fieldLabel),
                        count: rungs.bits.count)
        renderHeader(s, grid: grid, rungs: rungs, y: y, theme: theme)
        y += 1

        for (i, row) in rows.enumerated() {
            guard case .family(let family) = row, y < formRect.maxY - 2 else { continue }
            fieldRows[row.key] = y
            let selected = i == list.selected
            let bg = selected ? theme.selectionBg : theme.appBg
            s.fill(Rect(x: formRect.x, y: y, w: formRect.w, h: 1),
                   Style(fg: theme.text, bg: bg))
            s.text(formRect.x, y, selected ? "\(Glyph.arrowRight) " : "  ",
                   Style(fg: theme.accent, bg: bg))
            s.text(formRect.x + 2, y, family.name,
                   Style(fg: selected ? theme.selectionFg : theme.text, bg: bg),
                   limit: Layout.fieldLabel)
            renderBar(s, family: family, grid: grid, rungs: rungs, y: y,
                      theme: theme, bg: bg, cursorHere: selected)
            y += 1
        }

        // Shown once under the grid rather than in every row.
        let note = survey?.isEmpty == false ? message
            : (message ?? t("no rule set on disk yet — build once and this fills in"))
        if let note, y + 1 < formRect.maxY {
            for chunk in wrapText(note, width: formRect.w - 2) {
                guard y + 1 < formRect.maxY else { break }
                s.text(formRect.x + 2, y + 1, chunk,
                       Style(fg: theme.warn, bg: theme.appBg))
                y += 1
            }
        }

        guard let panel else { return }
        renderPanel(s, rect: panel, theme: theme)
    }

    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        guard picking != nil, let at = fieldRows[Row.ladder.key] else { return }
        Widgets.optionList(s, within: Layout.split(rect).form, anchorRow: at,
                           options: LevelsProfile.all.map(\.name), at: picking ?? 0,
                           theme: ctx.theme)
    }

    /// Where the columns of the grid sit.
    private struct Grid {
        let x: Int, width: Int, count: Int
        /// Column width, at least four so a scale label still fits.
        var step: Int { max(4, count > 0 ? width / count : width) }
        func column(_ rung: Int) -> Int { x + rung * step }
    }

    /// Draws the rungs across the top: each one's map scale, or its index where there is no
    /// scale for it.
    private func renderHeader(_ s: Surface, grid: Grid, rungs: ZoomRungs, y: Int,
                              theme: Theme) {
        for (rung, bits) in rungs.bits.enumerated() {
            let head = ZoomRungs.shortScale(bits: bits) ?? "\(rung)"
            s.text(grid.column(rung), y, head,
                   Style(fg: rung == column ? theme.accent : theme.faint, bg: theme.appBg,
                         bold: rung == column))
        }
    }

    /// Draws one family's bar: the rungs it occupies, with the style's own spread shaded
    /// behind where the plan has changed them.
    private func renderBar(_ s: Surface, family: ZoomFamily, grid: Grid, rungs: ZoomRungs,
                           y: Int, theme: Theme, bg: Color, cursorHere: Bool) {
        guard let survey, let spread = survey.spread(family) else {
            // Nothing read from disk: empty rungs, with the explanation under the grid.
            for rung in rungs.bits.indices {
                s.text(grid.column(rung), y, " · ", Style(fg: theme.rule, bg: bg))
            }
            return
        }
        let now = window(family) ?? .init(finest: spread.finest, coarsest: spread.coarsest)
        let changed = plan.window(family) != nil

        for rung in rungs.bits.indices {
            let here = now.contains(rung)
            let was = rung >= spread.finest && rung <= spread.coarsest
            let glyph: String
            let colour: Color
            if here {
                glyph = "███"
                colour = changed ? theme.ok : theme.text
            } else if was {
                glyph = "░░░"
                colour = theme.faint
            } else {
                glyph = " · "
                colour = theme.rule
            }
            let onCursor = cursorHere && rung == column
            s.text(grid.column(rung), y, glyph,
                   Style(fg: onCursor ? theme.strong : colour,
                         bg: onCursor ? theme.raisedBg : bg, bold: onCursor))
        }
    }

    private func renderPanel(_ s: Surface, rect: Rect, theme: Theme) {
        s.vline(rect.x - 2, rect.y, rect.h, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))
        var y = rect.y
        func caption(_ text: String) {
            guard y < rect.maxY else { return }
            s.sectionRule(rect, y, text, labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                          ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
            y += 2
        }
        func line(_ text: String, tone: Color? = nil) {
            for chunk in wrapText(text, width: rect.w) {
                guard y < rect.maxY else { return }
                s.text(rect.x, y, chunk, Style(fg: tone ?? theme.text, bg: theme.appBg))
                y += 1
            }
        }

        if case .family(let family)? = rows[safe: list.selected] {
            caption(family.name.uppercased())
            line(family.note, tone: theme.dim)
            y += 1
            if let survey, let spread = survey.spread(family) {
                if let now = window(family) {
                    line(survey.startsAt(rung: now.rungs.upperBound))
                    if now.rungs.lowerBound > 0 {
                        line(survey.stopsAt(rung: now.rungs.lowerBound), tone: theme.dim)
                    }
                }
                if plan.window(family) != nil {
                    line(t("as it comes: %@",
                           survey.rungLabel(spread.coarsest)), tone: theme.faint)
                }
                line(tn("%d rule(s) in the style", spread.rules), tone: theme.faint)
            } else {
                line(t("no rule set on disk yet — build once and this fills in"),
                     tone: theme.faint)
            }
            y += 1
        }

        caption(t("zoom levels"))
        for (i, bits) in rungs.bits.enumerated() {
            guard y < rect.maxY else { return }
            let scale = ZoomRungs.scale(bits: bits).map { "  ·  " + $0 } ?? ""
            s.text(rect.x, y, t("level %d", i) + scale,
                   Style(fg: i == column ? theme.text : theme.faint, bg: theme.appBg))
            y += 1
        }
    }
}

import Foundation

/// The zoom plans, kept by name: which rung of the zoom ladder each kind of feature starts
/// on. The ladder itself is fixed, being the coordinate system every style rule is written
/// against; only its population is editable. The plans that ship cannot be edited or
/// deleted.
final class ZoomPlansScreen: Screen {
    var page: Page { Page(t("zoom plans"), keys: keys) }

    private var keys: [Hint] {
        if confirming != nil {
            return [Hint(key: "y", label: t("delete")), Hint(key: "n", label: t("keep it"))]
        }
        if naming != nil {
            return [Hint(key: Glyph.enter, label: t("accept")), Hint(key: "esc", label: t("cancel"))]
        }
        return [Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("open")),
                Hint(key: "c", label: t("copy")),
                Hint(key: "r", label: t("rename")),
                Hint(key: "d", label: t("delete")),
                Hint(key: "esc", label: t("back"))]
    }

    private enum Naming {
        case copy(ZoomPlan)
        case rename(String)
    }

    private var plans: [ZoomPlan] = []
    private var list = ListState()
    private var naming: Naming?
    private var name = TextPrompt()
    private var confirming: ZoomPlan?
    private var message: String?
    private var messageIsError = false

    func tick(_ ctx: AppContext) {
        plans = ctx.settings.zoomPlans
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if naming != nil { return handleNaming(key, ctx: ctx) }
        if let plan = confirming { return handleConfirm(key, plan: plan, ctx: ctx) }

        switch key {
        case .up: list.move(-1, count: plans.count)
        case .down: list.move(1, count: plans.count)
        case .home: list.jump(to: 0, count: plans.count)
        case .end: list.jump(to: plans.count - 1, count: plans.count)

        case .enter:
            guard let plan = plans[safe: list.selected] else { return .none }
            return .push(ZoomPlanEditScreen(plan: plan, settings: ctx.settings))

        case .char(let typed):
            switch Keys.latin(typed) {
            case "c":
                guard let plan = plans[safe: list.selected] else { return .none }
                naming = .copy(plan)
                name.text = ctx.settings.uniqueZoomPlanName(t(plan.name))
                message = nil
            case "r":
                guard let plan = plans[safe: list.selected] else { return .none }
                guard !plan.isBuiltin else { return refuse(plan) }
                naming = .rename(plan.id)
                name.text = plan.name
                message = nil
            case "d":
                guard let plan = plans[safe: list.selected] else { return .none }
                guard !plan.isBuiltin else { return refuse(plan) }
                confirming = plan
            default: break
            }

        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// Refuses an edit to a built-in plan, pointing at the copy key instead.
    private func refuse(_ plan: ZoomPlan) -> Route {
        say(t("%@ ships with kmap — press c to copy it", t(plan.name)), error: true)
        return .none
    }

    private func handleNaming(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch name.handle(key) {
        case .typing: break
        case .quit: return .quit
        case .cancelled: naming = nil
        case .accepted(let wanted):
            let what = naming
            naming = nil
            switch what {
            case .copy(let source):
                // Every new plan is a copy: a plan records only what it moves against an
                // existing arrangement.
                let made = ctx.settings.copyZoomPlan(source,
                                                     named: wanted.isEmpty ? source.name : wanted)
                plans = ctx.settings.zoomPlans
                select(made.id)
                return .push(ZoomPlanEditScreen(plan: made, settings: ctx.settings))
            case .rename(let id):
                guard !wanted.isEmpty else { return .none }
                ctx.settings.renameZoomPlan(id, to: wanted)
                plans = ctx.settings.zoomPlans
                select(id)
            case .none: break
            }
        }
        return .none
    }

    private func handleConfirm(_ key: KeyEvent, plan: ZoomPlan, ctx: AppContext) -> Route {
        switch YesNo.answer(key) {
        case .yes:
            confirming = nil
            guard ctx.settings.deleteZoomPlan(plan.id) else { return .none }
            plans = ctx.settings.zoomPlans
            list.jump(to: min(list.selected, plans.count - 1), count: plans.count)
            // A profile naming a deleted plan falls back to a built-in one rather than
            // failing the build; see `BuildRecipe.apply`.
            say(t("deleted %@ — any profile using it goes back to what ships", t(plan.name)))
        case .no: confirming = nil
        case .quit: return .quit
        case nil: break
        }
        return .none
    }

    private func select(_ id: String) {
        if let at = plans.firstIndex(where: { $0.id == id }) {
            list.jump(to: at, count: plans.count)
        }
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    // MARK: Drawing

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        let intro = t("A device shows the map at several zoom levels. A zoom plan sets "
                    + "the level where each kind of feature appears: trails, roads, "
                    + "woodland and so on.")
        let howTo = t("Plans marked · come with kmap and cannot be edited. Copy one, "
                    + "and the copy is yours to change.")
        for chunk in wrapText(intro, width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        y += 1
        for chunk in wrapText(howTo, width: rect.w) {
            s.text(rect.x, y, chunk, Style(fg: theme.dim, bg: theme.appBg))
            y += 1
        }
        y += 1

        let listHeight = max(1, rect.maxY - y - 6)
        list.clamp(count: plans.count, visible: listHeight)
        let listTop = y

        for i in 0..<min(listHeight, plans.count - list.offset) {
            let index = list.offset + i
            guard let plan = plans[safe: index] else { break }
            // The ladder is shown on every row: a plan's numbers are rungs of one ladder
            // and cannot be carried to another.
            let ladder = LevelsProfile.all.first { $0.id == plan.levelsID }?.name ?? ""
            let moved = plan.movesAnything
                ? tn("%d family(ies) moved", plan.windows.count)
                : t("as it comes")
            Widgets.row(s, rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1), y: y,
                        text: t(plan.name) + "   " + ladder,
                        trailing: moved,
                        theme: theme, selected: index == list.selected,
                        leading: plan.isBuiltin ? "\(Glyph.dot) " : "  ")
            y += 1
        }
        Widgets.scrollHint(s, rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
                           offset: list.offset, count: plans.count,
                           visible: listHeight, theme: theme)

        if let naming {
            guard y + 1 < rect.maxY else { return }
            let prompt: String
            switch naming {
            case .copy: prompt = t("name for the copy")
            case .rename: prompt = t("new name")
            }
            let x = s.text(rect.x, y + 1, prompt + ": ", Style(fg: theme.dim, bg: theme.appBg))
            let end = s.text(x, y + 1, name.text, Style(fg: theme.strong, bg: theme.appBg, bold: true))
            s.put(end, y + 1, "▏", Style(fg: theme.accent, bg: theme.appBg))
            return
        }

        if let plan = confirming, y + 1 < rect.maxY {
            s.text(rect.x, y + 1, t("delete %@?", t(plan.name)),
                   Style(fg: theme.warn, bg: theme.appBg, bold: true))
            return
        }

        if let message, y + 1 < rect.maxY {
            s.text(rect.x, y + 1, truncate(message, to: rect.w),
                   Style(fg: messageIsError ? theme.danger : theme.ok, bg: theme.appBg))
        }
    }
}

import Foundation

/// The zoom plans, kept by name. The ladder is fixed; only its population is editable,
/// and the plans that ship cannot be edited or deleted.
final class ZoomPlansScreen: Screen {
    var page: Page { Page(t("zoom plans"), keys: keys) }

    private var keys: [Hint] {
        if confirming != nil {
            return [Hint(key: "y", label: t("delete")), Hint(key: "n", label: t("keep it"))]
        }
        if naming != nil {
            return [Hint(key: Glyph.enter, label: t("accept")), Hint(key: "esc", label: t("cancel"))]
        }
        return [
            Hint(key: "↑↓", label: t("move")),
            Hint(key: Glyph.enter, label: t("open")),
            Hint(key: "c", label: t("copy")),
            Hint(key: "r", label: t("rename")),
            Hint(key: "d", label: t("delete")),
            Hint(key: "esc", label: t("back"))
        ]
    }

    private enum Naming {
        case copy(ZoomPlan)
        case rename(String)
    }

    /// Rows kept under the list for the prompt or the message.
    private static let footerRows = 6

    private var plans: [ZoomPlan] = []
    private var list = ListState()
    private var naming: Naming?
    private var name = TextPrompt()
    private var confirming: ZoomPlan?
    private var notice = Notice()

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
            guard let plan = plans[safe: list.selected] else { return .none }
            switch Keys.latin(typed) {
            case "c":
                naming = .copy(plan)
                name.text = ctx.settings.uniqueZoomPlanName(plan.shownName)
                notice.clear()
            case "r":
                guard !plan.isBuiltin else { return refuse(plan) }
                naming = .rename(plan.id)
                name.text = plan.name
                notice.clear()
            case "d":
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

    private func refuse(_ plan: ZoomPlan) -> Route {
        notice.say(t("%@ ships with kmap — press c to copy it", plan.shownName), error: true)
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
                // Every new plan is a copy: a plan records only what it moves.
                let made = ctx.settings.copyZoomPlan(source, named: wanted.isEmpty ? source.shownName : wanted)
                plans = ctx.settings.zoomPlans
                select(made.id)
                guard !saidUnsaved(ctx) else { return .none }
                return .push(ZoomPlanEditScreen(plan: made, settings: ctx.settings))
            case .rename(let id):
                guard !wanted.isEmpty else { return .none }
                ctx.settings.renameZoomPlan(id, to: wanted)
                plans = ctx.settings.zoomPlans
                select(id)
                saidUnsaved(ctx)
            case .none: break
            }
        }
        return .none
    }

    /// Whether the settings file refused the change just made, said in red if so.
    @discardableResult
    private func saidUnsaved(_ ctx: AppContext) -> Bool {
        guard let failure = ctx.settings.saveFailure else { return false }
        notice.say(t("could not save the settings: %@", failure.localizedDescription), error: true)
        return true
    }

    private func handleConfirm(_ key: KeyEvent, plan: ZoomPlan, ctx: AppContext) -> Route {
        switch YesNo.answer(key) {
        case .yes:
            confirming = nil
            guard ctx.settings.deleteZoomPlan(plan.id) else { return .none }
            plans = ctx.settings.zoomPlans
            list.jump(to: min(list.selected, plans.count - 1), count: plans.count)
            if !saidUnsaved(ctx) {
                notice.say(t("deleted %@ — any profile using it goes back to what ships", plan.shownName))
            }
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

    // MARK: Drawing

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = s.paragraph(
            t(
                "A device shows the map at several zoom levels. A zoom plan sets "
                    + "the level where each kind of feature appears: trails, roads, "
                    + "woodland and so on."
            ),
            x: rect.x,
            y: rect.y,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1
        y = s.paragraph(
            t("Plans marked · come with kmap and cannot be edited. Copy one, and the copy is yours to change."),
            x: rect.x,
            y: y,
            width: rect.w,
            style: Style(fg: theme.dim, bg: theme.appBg)
        )
        y += 1

        let listHeight = max(1, rect.maxY - y - Self.footerRows)
        let listTop = y
        for index in list.window(count: plans.count, visible: listHeight) {
            let plan = plans[index]
            // The ladder on every row: a plan's numbers are rungs of one ladder.
            let ladder = LevelsProfile.all.first { $0.id == plan.levelsID }?.name ?? ""
            let moved = plan.movesAnything ? tn("%d family(ies) moved", plan.windows.count) : t("as it comes")
            Widgets.row(
                s,
                rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1),
                y: y,
                text: plan.shownName + "   " + ladder,
                trailing: moved,
                theme: theme,
                selected: index == list.selected,
                leading: plan.isBuiltin ? "\(Glyph.dot) " : "  "
            )
            y += 1
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
            offset: list.offset,
            count: plans.count,
            visible: listHeight,
            theme: theme
        )

        if y + 1 < rect.maxY { drawFooter(into: s, rect: rect, y: y + 1, theme: theme) }
    }

    /// The name being typed, the delete question, or the last message.
    private func drawFooter(into s: Surface, rect: Rect, y: Int, theme: Theme) {
        if let naming {
            let prompt: String
            switch naming {
            case .copy: prompt = t("name for the copy")
            case .rename: prompt = t("new name")
            }
            s.prompt(
                prompt + ": ",
                draft: name.text,
                x: rect.x,
                y: y,
                labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                theme: theme
            )
        } else if let plan = confirming {
            s.text(rect.x, y, t("delete %@?", plan.shownName), Style(fg: theme.warn, bg: theme.appBg, bold: true))
        } else if let text = notice.text {
            s.text(
                rect.x,
                y,
                truncate(text, to: rect.w),
                Style(fg: notice.isError ? theme.danger : theme.ok, bg: theme.appBg)
            )
        }
    }
}

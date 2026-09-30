import Foundation

/// Which rungs of the ladder each family is drawn on: families down the side, rungs
/// across. Space adds or removes the rung under the cursor, keeping a continuous run.
final class ZoomPlanEditScreen: Screen {
    var page: Page { Page(t("zoom plan"), subject: t(plan.name), keys: keys) }

    private var keys: [Hint] {
        if picking != nil {
            return [
                Hint(key: "↑↓", label: t("move")),
                Hint(key: Glyph.enter, label: t("take it")),
                Hint(key: "esc", label: t("cancel"))
            ]
        }
        if plan.isBuiltin {
            return [Hint(key: "↑↓", label: t("move")), Hint(key: "esc", label: t("back"))]
        }
        return [
            Hint(key: "↑↓←→", label: t("move")),
            Hint(key: "space", label: t("add / remove")),
            Hint(key: "0", label: t("as it comes")),
            Hint(key: "esc", label: t("back"))
        ]
    }

    /// The ladder first; every row under it is counted in its rungs.
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

    var plan: ZoomPlan
    private let settings: SettingsStore
    var list = ListState()
    /// The rung under the cursor, kept across rows.
    var column = 0
    var survey: ZoomSurvey?
    var message: String?
    /// The ladder row's open list.
    var picking: Int?
    /// The screen row each field was drawn on, so an open list hangs under it.
    var fieldRows: [String: Int] = [:]

    init(plan: ZoomPlan, settings: SettingsStore) {
        self.plan = plan
        self.settings = settings
    }

    var levels: LevelsProfile {
        LevelsProfile.all.first { $0.id == plan.levelsID } ?? .smooth
    }

    var rungs: ZoomRungs { ZoomRungs(levels: levels.levels) }
    var rows: [Row] { [.ladder] + ZoomFamily.all.map(Row.family) }

    func tick(_ ctx: AppContext) {
        // Once: the rule set does not change while this screen is open.
        if survey == nil {
            survey = ZoomSurvey(styleAt: StyleCatalog.baseStyleDirectory, levels: levels)
        }
    }

    /// The plan's window for a family, else the style's own spread.
    func window(_ family: ZoomFamily) -> ZoomPlan.Window? {
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

    /// Adds or removes the rung under the cursor. A window is a continuous run: adding
    /// beyond the end fills the gap, removing from the middle drops the shorter side.
    private func toggle() {
        guard !plan.isBuiltin else { _ = refuse(); return }
        guard case .family(let family)? = rows[safe: list.selected] else { return }
        guard let now = window(family) else {
            message = t("no rule set on disk yet — build once and this fills in")
            return
        }
        let rung = column
        let next: ZoomPlan.Window
        if now.contains(rung) {
            guard now.count > 1 else {
                message = t("a family has to be drawn somewhere — use Hide on map instead")
                return
            }
            let low = now.rungs.lowerBound, high = now.rungs.upperBound
            if rung == low || (rung != high && rung - low <= high - rung) {
                next = .init(finest: rung + 1, coarsest: high)
            } else {
                next = .init(finest: low, coarsest: rung - 1)
            }
        } else if rung < now.rungs.lowerBound {
            next = .init(finest: rung, coarsest: now.rungs.upperBound)
        } else {
            next = .init(finest: now.rungs.lowerBound, coarsest: rung)
        }

        // A window matching the style's own spread is stored as nil.
        if let spread = survey?.spread(family),
            next.rungs.lowerBound == spread.finest, next.rungs.upperBound == spread.coarsest
        {
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

    /// Another ladder drops every window: an index means a different rung there.
    private func setLadder(_ ladder: LevelsProfile) {
        guard ladder.id != plan.levelsID else { return }
        plan.levelsID = ladder.id
        plan.windows = [:]
        settings.saveZoomPlan(plan)
        survey = nil
        column = 0
        message = t("moved to %@ — the rows are back to what the style does", ladder.name)
    }
}

import Foundation

/// Edits one profile on the build form, in `.profile` mode: without the rows that belong
/// to a map rather than to a set of choices.
final class ProfileEditScreen: Screen {
    var page: Page { Page(t("profile"), subject: profile.name, keys: keys) }

    private var keys: [Hint] {
        var hints = form.keys
        if !form.isPicking { hints.append(Hint(key: "esc", label: t("save & back"))) }
        return hints
    }

    private var profile: BuildProfile
    private let form: RecipeForm

    init(profile: BuildProfile, settings store: SettingsStore, hasSeamPatch: Bool) {
        self.profile = profile
        var recipe = BuildRecipe(
            region: ProfileEditScreen.anyRegion,
            style: .standIn,
            outputDirectory: store.settings.outputURL
        )
        // Code page 0: no region to suggest one; resolved at build time.
        recipe.apply(profile.choices, style: nil, regionCodePage: 0)
        self.form = RecipeForm(
            mode: .profile,
            recipe: recipe,
            askedStyleID: profile.choices.styleID,
            hasSeamPatch: hasSeamPatch
        )
    }

    /// A placeholder so the form has a recipe to edit. Never built.
    private static var anyRegion: Region {
        Region(id: "", name: "", parentID: nil, pbfURL: nil, bbox: .empty, boxes: [])
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if !form.isPicking && !form.isEditingText {
            switch key {
            case .esc: return save(ctx) ? .pop : .none
            case .ctrl("c"): return .quit
            default: break
            }
        }
        switch form.handle(key, ctx: ctx) {
        case .none: return .none
        case .route(let route): return route
        case .commit: return save(ctx) ? .pop : .none
        case .profileChosen: return .none
        }
    }

    /// False when the file could not be written: the screen stays, saying why.
    private func save(_ ctx: AppContext) -> Bool {
        profile.choices = form.recipe.choices
        if case .failure(let error) = ctx.settings.saveProfile(profile) {
            form.message = t("could not save the settings: %@", error.localizedDescription)
            return false
        }
        return true
    }

    func tick(_ ctx: AppContext) {
        form.tick(ctx)
    }

    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        form.renderOverlay(into: s, rect: Layout.split(rect).form, ctx: ctx)
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let (formRect, panel) = Layout.split(rect)
        form.render(into: s, rect: formRect, ctx: ctx)
        guard let side = panel else { return }
        s.vline(side.x - 2, side.y, side.h, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))

        var column = SummaryColumn(s: s, rect: side, theme: theme, y: side.y)
        column.caption(t("profile"))
        column.line(profile.name)
        column.line(t("selected on the New map screen; fills in every field of the form"), tone: theme.faint)
        column.gap()

        column.caption(t("what it does not include"))
        column.line(
            t(
                "The region, the family id and the output folder. The region and the"
                    + " family id are set per map — the device hides maps that share a family id."
                    + " The folder is set once, in Settings."
            ),
            tone: theme.faint
        )
        column.gap()

        column.caption(t("changing it later"))
        column.line(
            t(
                "A profile is edited on this page only. Changes made on the New map"
                    + " screen apply to one map and do not touch the profile."
            ),
            tone: theme.faint
        )
        column.gap()

        column.caption(t("zoom"))
        column.line(form.recipe.levels.name, tone: theme.text)
        column.line(form.recipe.levels.note, tone: theme.faint)
    }
}

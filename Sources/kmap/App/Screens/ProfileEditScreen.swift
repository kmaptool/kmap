import Foundation

/// Edits one profile on the same form the build screen shows, in `.profile` mode. The fields
/// belonging to a map rather than to a set of choices — family id, output folder, region —
/// are absent.
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
            style: MapStyle(id: "plain", name: "Plain", summary: "",
                            origin: .builtin,
                            styleDirectory: StyleCatalog.baseStyleDirectory,
                            typURL: nil, familyID: 6324, productID: 1),
            outputDirectory: store.settings.outputURL)
        // Code page 0: with no region there is nothing to suggest one, and it is resolved at
        // build time.
        recipe.apply(profile.choices, style: nil, regionCodePage: 0)
        self.form = RecipeForm(mode: .profile, recipe: recipe,
                               askedStyleID: profile.choices.styleID,
                               hasSeamPatch: hasSeamPatch)
    }

    /// An empty placeholder region, so the form has a recipe to edit. Never built.
    private static var anyRegion: Region {
        Region(id: "", name: "", parentID: nil, pbfURL: nil, bbox: .empty, boxes: [])
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if !form.isPicking && !form.isEditingText {
            switch key {
            // Esc saves rather than discards, as on the settings screen.
            case .esc: save(ctx); return .pop
            case .ctrl("c"): return .quit
            default: break
            }
        }

        switch form.handle(key, ctx: ctx) {
        case .none: return .none
        case .route(let route): return route
        case .commit: save(ctx); return .pop
        case .profileChosen: return .none
        }
    }

    private func save(_ ctx: AppContext) {
        profile.choices = form.recipe.choices
        ctx.settings.saveProfile(profile)
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

        var y = side.y
        func caption(_ text: String) {
            guard y < side.maxY else { return }
            s.sectionRule(side, y, text,
                          labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                          ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
            y += 2
        }
        func line(_ text: String, tone: Color? = nil) {
            for chunk in wrapText(text, width: side.w) {
                guard y < side.maxY else { return }
                s.text(side.x, y, chunk, Style(fg: tone ?? theme.text, bg: theme.appBg))
                y += 1
            }
        }

        caption(t("profile"))
        line(profile.name)
        line(t("selected on the New map screen; fills in every field of the form"),
             tone: theme.faint)
        y += 1

        caption(t("what it does not include"))
        line(t("The region, the family id and the output folder. The region and the"
             + " family id are set per map — the device hides maps that share a family id."
             + " The folder is set once, in Settings."), tone: theme.faint)
        y += 1

        caption(t("changing it later"))
        line(t("A profile is edited on this page only. Changes made on the New map"
             + " screen apply to one map and do not touch the profile."),
             tone: theme.faint)
        y += 1

        caption(t("zoom"))
        line(form.recipe.levels.name, tone: theme.text)
        line(form.recipe.levels.note, tone: theme.faint)
    }
}

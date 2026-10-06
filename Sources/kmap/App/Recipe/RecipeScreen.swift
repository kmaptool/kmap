import Foundation

/// The build form for one map: pick a profile, change what this map needs, then start.
/// Choices apply to this build only; the profile is edited elsewhere.
final class RecipeScreen: Screen {
    var page: Page { Page(t("new map"), subject: form.recipe.mapName, keys: keys) }

    private var keys: [Hint] {
        var hints = form.keys
        if !form.isPicking { hints.append(Hint(key: "esc", label: t("back"))) }
        return hints
    }

    /// Every region going in; several become one seamless map under one family id.
    private let regions: [Region]
    private let form: RecipeForm
    private let sizes = ExtractSizes()
    private let cost = ElevationCostProbe()
    /// One login check per visit, not one per frame.
    private var checkedLogins = false

    private var region: Region { regions[0] }
    private var recipe: BuildRecipe { form.recipe }

    convenience init(region: Region, index: RegionIndex? = nil, settings: SettingsStore, hasSeamPatch: Bool) {
        self.init(regions: [region], index: index, settings: settings, hasSeamPatch: hasSeamPatch)
    }

    init(regions: [Region], index: RegionIndex? = nil, settings store: SettingsStore, hasSeamPatch: Bool) {
        precondition(!regions.isEmpty, "a map needs at least one region")
        self.regions = regions
        let region = regions[0]
        let settings = store.settings
        let profile = store.currentProfile
        // Where the profile leaves the code page unset, the region decides.
        let regionCodePage = BuildRecipe.suggestedCodePage(for: region, in: index)

        var recipe = BuildRecipe(
            region: region,
            extraRegions: Array(regions.dropFirst()),
            style: .standIn,
            // Shown, not taken: a form left without building keeps no id.
            familyID: store.previewFamilyID(for: BuildRecipe.identityKey(regions)),
            countryOf: RecipeScreen.countries(of: regions, in: index),
            outputDirectory: settings.outputURL,
            workRoot: settings.workURL,
            maxNodesPerTile: settings.maxNodesPerTile,
            heapGB: settings.resolvedHeapGB,
            downloadConnections: settings.downloadConnections
        )
        recipe.apply(profile.choices, style: nil, regionCodePage: regionCodePage, plans: store.zoomPlans)

        form = RecipeForm(
            mode: .build,
            recipe: recipe,
            regionCodePage: regionCodePage,
            askedStyleID: profile.choices.styleID,
            hasSeamPatch: hasSeamPatch
        )
        form.profiles = store.profiles
        form.currentProfileID = profile.id
    }

    /// Region id to country id, for the per-country split: the last ancestor whose own
    /// parent is not the continent root.
    private static func countries(of regions: [Region], in index: RegionIndex?) -> [String: String] {
        guard let index else { return [:] }
        var out: [String: String] = [:]
        for region in regions {
            var current = region
            while let parentID = current.parentID, let parent = index.region(parentID), parent.parentID != nil {
                current = parent
            }
            out[region.id] = current.id
        }
        return out
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        // Esc and ^C are the screen's, unless the form is editing text or holds a list open.
        if !form.isPicking && !form.isEditingText {
            switch key {
            case .esc:
                cost.stop()
                return .pop
            case .ctrl("c"): return .quit
            default: break
            }
        }
        switch form.handle(key, ctx: ctx) {
        case .none: return .none
        case .route(let route): return route
        case .commit: return startBuild(ctx)
        case .profileChosen(let id):
            // The only state this screen persists.
            ctx.settings.useProfile(id)
            return .none
        }
    }

    private func startBuild(_ ctx: AppContext) -> Route {
        if let missing = form.missingStyleID {
            form.message = t("%@ not found — pick a style", missing)
            return .none
        }
        guard region.pbfURL != nil else {
            form.message = t("this region has no downloadable extract")
            return .none
        }
        if recipe.needsElevationData,
            recipe.demSources.contains("srtm") || recipe.demSources.contains("alos"),
            ctx.toolchain.findPyhgtmap() == nil
        {
            form.message = t(
                "%@ needs pyhgtmap — open Toolchain to install it, or pick"
                    + " copernicus1/copernicus3 or view1/view3",
                recipe.demSources
            )
            return .none
        }
        // A fresh install has no Java and no mkgmap: offer to fetch them and then build.
        guard ctx.toolchain.canBuild else {
            let missing = Toolchain.missingRequirements(in: ctx.tools)
            guard !missing.isEmpty else {
                form.message = t("the toolchain is incomplete — open Toolchain to finish setting it up")
                return .none
            }
            return .push(
                SetupScreen(missing: missing) { [weak self] ctx in
                    guard let self else { return .pop }
                    return .replace(self.buildScreen(ctx))
                }
            )
        }
        return .push(buildScreen(ctx))
    }

    /// The build keeps the detail; its screen hides it behind a key.
    private func buildScreen(_ ctx: AppContext) -> BuildScreen {
        BuildScreen(
            pipeline: BuildPipeline(
                recipe: recipe,
                settings: ctx.settings,
                toolchain: ctx.toolchain,
                styles: ctx.styles,
                showing: .debug
            )
        )
    }

    // MARK: Render

    func tick(_ ctx: AppContext) {
        form.tick(ctx)
        // Made and unmade on other screens while this one is on the stack.
        form.profiles = ctx.settings.profiles
        for region in regions { sizes.probe(region) }
        cost.refresh(sources: recipe.needsElevationData ? recipe.demSources : "", regions: regions)
        checkElevationLogins(ctx)
    }

    /// Verifies the stored USGS and JAXA logins once, so the source list can omit srtm
    /// and alos where the login is known to be bad.
    private func checkElevationLogins(_ ctx: AppContext) {
        guard !checkedLogins, ctx.toolchain.findPyhgtmap() != nil else { return }
        checkedLogins = true
        for service in ElevationLogins.Service.allCases {
            let login = ElevationLogins.load(service)
            guard !login.user.isEmpty, !login.password.isEmpty, ElevationLogins.check(service) == nil
            else { continue }
            Task { _ = await ElevationLogins.verify(service) }
        }
    }

    /// Opens one of the form's lists. See `RecipeForm.openPicker`.
    func openPicker(_ field: RecipeForm.Field, _ ctx: AppContext) {
        form.openPicker(field, ctx)
    }

    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        form.renderOverlay(into: s, rect: Layout.split(rect).form, ctx: ctx)
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let (formRect, panel) = Layout.split(rect)
        form.render(into: s, rect: formRect, ctx: ctx)
        if let panel {
            RecipeSummaryPanel(form: form, regions: regions, sizes: sizes, cost: cost).draw(
                into: s,
                rect: panel,
                ctx: ctx
            )
        }
    }
}

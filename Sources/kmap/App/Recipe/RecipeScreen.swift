import Foundation

/// The build form for one map: pick a profile, change whatever this map needs, then start.
///
/// Choices arrive from the chosen profile and apply to this build only; the profile is
/// edited elsewhere. The only thing persisted is which profile was last chosen.
final class RecipeScreen: Screen {
    var page: Page { Page(t("new map"), subject: form.recipe.mapName, keys: keys) }

    private var keys: [Hint] {
        var hints = form.keys
        if !form.isPicking { hints.append(Hint(key: "esc", label: t("back"))) }
        return hints
    }

    private let region: Region
    /// Every region going into this map. Several regions become one seamless map under one
    /// family id.
    private let regions: [Region]
    private let form: RecipeForm
    /// Download size of each region's extract, keyed by region id, probed as the form opens.
    private var extractSizes: [String: Int64] = [:]
    private var probedSizes = false
    /// Fetch cost of the chosen elevation source, with the source list it belongs to and an
    /// in-flight flag, so an answered, a pending and a stale estimate stay distinguishable.
    private var elevationCost: [ElevationCost.Estimate] = []
    private var elevationCostFor = ""
    private var elevationCosting = false
    /// One login check per visit to this screen, not one per frame.
    private var checkedLogins = false

    private var recipe: BuildRecipe { form.recipe }

    convenience init(region: Region, index: RegionIndex? = nil, settings: SettingsStore,
                     hasSeamPatch: Bool) {
        self.init(regions: [region], index: index, settings: settings,
                  hasSeamPatch: hasSeamPatch)
    }

    init(regions: [Region], index: RegionIndex? = nil, settings store: SettingsStore,
         hasSeamPatch: Bool) {
        precondition(!regions.isEmpty, "a map needs at least one region")
        self.regions = regions
        let region = regions[0]
        self.region = region
        let settings = store.settings
        let profile = store.currentProfile
        // Used wherever the profile leaves the code page unset, so one profile serves
        // regions with different scripts.
        let regionCodePage = BuildRecipe.suggestedCodePage(for: region, in: index)

        var recipe = BuildRecipe(
            region: region,
            extraRegions: Array(regions.dropFirst()),
            // A stand-in until the catalogue answers, which it does on the first tick.
            style: MapStyle(id: "plain", name: "Plain", summary: "",
                            origin: .builtin,
                            styleDirectory: StyleCatalog.baseStyleDirectory,
                            typURL: nil, familyID: 6324, productID: 1),
            familyID: store.familyID(for: BuildRecipe.identityKey(regions)),
            countryOf: RecipeScreen.countries(of: regions, in: index),
            outputDirectory: settings.outputURL,
            workRoot: settings.workURL,
            maxNodesPerTile: settings.maxNodesPerTile,
            heapGB: settings.resolvedHeapGB,
            downloadConnections: settings.downloadConnections)
        recipe.apply(profile.choices, style: nil, regionCodePage: regionCodePage)
        recipe.profileName = profile.name
        // Count of terminal extracts covered. Without the index the chosen regions stand
        // in, which is correct whenever they are leaves.
        if let index {
            recipe.leafRegionCount = index.leafRegionCount(of: regions.map(\.id))
        }

        self.form = RecipeForm(mode: .build, recipe: recipe,
                               regionCodePage: regionCodePage,
                               askedStyleID: profile.choices.styleID,
                               hasSeamPatch: hasSeamPatch)
        form.profiles = store.profiles
        form.currentProfileID = profile.id
    }

    /// Maps region id to country id, for the per-country split. Walks each region's parent
    /// chain up to the last ancestor whose own parent is not the continent root.
    private static func countries(of regions: [Region], in index: RegionIndex?)
        -> [String: String] {
        guard let index else { return [:] }
        var out: [String: String] = [:]
        for region in regions {
            var current = region
            while let parentID = current.parentID, let parent = index.region(parentID),
                  parent.parentID != nil {
                current = parent
            }
            out[region.id] = current.id
        }
        return out
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        // esc and ^C belong to the screen; the form takes the rest, and takes esc too while
        // editing text or holding a list open.
        if !form.isPicking && !form.isEditingText {
            switch key {
            case .esc: return .pop
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
        guard region.pbfURL != nil else {
            form.message = t("this region has no downloadable extract")
            return .none
        }
        if recipe.needsElevationData, recipe.demSources.contains("srtm")
            || recipe.demSources.contains("alos"),
           ctx.toolchain.findPyhgtmap() == nil {
            form.message = t("%@ needs pyhgtmap — open Toolchain to install it, or pick"
                           + " copernicus1/copernicus3 or view1/view3", recipe.demSources)
            return .none
        }
        // A machine kmap was just installed on has no Java and no mkgmap. Rather than
        // refusing and naming another screen, offer to fetch them and then build.
        guard ctx.toolchain.canBuild else {
            let missing = Toolchain.missingRequirements(in: ctx.tools)
            guard !missing.isEmpty else {
                form.message = t("the toolchain is incomplete — open Toolchain to finish"
                               + " setting it up")
                return .none
            }
            return .push(SetupScreen(missing: missing) { [weak self] ctx in
                guard let self else { return .pop }
                return .replace(self.buildScreen(ctx))
            })
        }
        return .push(buildScreen(ctx))
    }

    /// The build itself, once there is a toolchain to run it with.
    private func buildScreen(_ ctx: AppContext) -> BuildScreen {
        // The interface keeps the detail rather than dropping it: the build screen hides
        // it behind a key, so it is there the moment it is wanted.
        let pipeline = BuildPipeline(recipe: recipe, settings: ctx.settings,
                                     toolchain: ctx.toolchain, styles: ctx.styles,
                                     showing: .debug)
        return BuildScreen(pipeline: pipeline)
    }

    // MARK: Render

    func tick(_ ctx: AppContext) {
        form.tick(ctx)
        // Made and unmade on other screens while this one is on the stack.
        form.profiles = ctx.settings.profiles
        probeSizes()
        probeElevationCost()
        checkElevationLogins(ctx)
    }

    /// Verifies the configured USGS and JAXA credentials once per visit to this screen, so
    /// the source list can omit srtm and alos where the login is known to be bad.
    private func checkElevationLogins(_ ctx: AppContext) {
        guard !checkedLogins, ctx.toolchain.findPyhgtmap() != nil else { return }
        checkedLogins = true
        for service in ElevationLogins.Service.allCases {
            let login = ElevationLogins.load(service)
            guard !login.user.isEmpty, !login.password.isEmpty,
                  ElevationLogins.check(service) == nil else { continue }
            Task { _ = await ElevationLogins.verify(service) }
        }
    }

    /// Re-estimates the elevation download whenever the displayed figure no longer belongs
    /// to the selected source. Four HEAD requests, issued only when the field changes; a
    /// build without elevation issues none.
    private func probeElevationCost() {
        let wanted = recipe.needsElevationData ? recipe.demSources : ""
        guard wanted != elevationCostFor, !elevationCosting else { return }
        guard !wanted.isEmpty else {
            elevationCost = []
            elevationCostFor = ""
            return
        }
        elevationCosting = true
        let regions = self.regions
        Task { [weak self] in
            let estimate = await ElevationCost.estimate(sources: wanted, regions: regions)
            await MainActor.run {
                guard let self else { return }
                self.elevationCost = estimate
                self.elevationCostFor = wanted
                self.elevationCosting = false
            }
        }
    }

    // MARK: Fitting the output to the card

    private func probeSizes() {
        guard !probedSizes else { return }
        probedSizes = true
        let wanted = regions.compactMap { r in r.pbfURL.map { (r.id, $0) } }
        Task { [weak self] in
            for (id, url) in wanted {
                let info = try? await Downloader.probe(url)
                guard let self else { return }
                await MainActor.run {
                    guard let info else { return }
                    self.extractSizes[id] = info.size
                }
            }
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
        if let panel { renderSummary(s, rect: panel, ctx: ctx) }
    }

    private func renderSummary(_ s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        s.vline(rect.x - 2, rect.y, rect.h, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))

        var column = SummaryColumn(s: s, rect: rect, theme: theme, y: rect.y)
        summarizeRegions(into: &column)
        summarizeCost(into: &column, ctx: ctx)
        summarizeDestination(into: &column)
        summarizeNotes(into: &column)
        summarizeSelection(into: &column, ctx: ctx)
    }

    /// The summary's writing hand: a narrow column of captioned prose that stops at the
    /// bottom of its rect.
    private struct SummaryColumn {
        let s: Surface
        let rect: Rect
        let theme: Theme
        var y: Int

        mutating func caption(_ text: String) {
            guard y < rect.maxY else { return }
            s.sectionRule(rect, y, text,
                          labelStyle: Style(fg: theme.dim, bg: theme.appBg),
                          ruleStyle: Style(fg: theme.rule, bg: theme.appBg))
            y += 2
        }

        mutating func line(_ text: String, tone: Color? = nil) {
            for chunk in wrapText(text, width: rect.w) {
                guard y < rect.maxY else { return }
                s.text(rect.x, y, chunk, Style(fg: tone ?? theme.text, bg: theme.appBg))
                y += 1
            }
        }

        mutating func gap() { y += 1 }
    }

    private func summarizeRegions(into column: inout SummaryColumn) {
        let theme = column.theme
        if regions.count == 1 {
            column.caption(t("region"))
            if let size = extractSizes[region.id] {
                column.line("\(region.name)  \(Fmt.bytes(size))")
            } else {
                column.line(region.name)
            }
            column.line(region.id, tone: theme.faint)
            if region.bbox.isValid {
                column.line(region.bbox.display, tone: theme.dim)
            }
        } else {
            column.caption(tn("%d region(s)", regions.count))
            // One per line, up to eight; the map name itself abbreviates past three.
            for r in regions.prefix(8) {
                let size = extractSizes[r.id].map { "  \(Fmt.bytes($0))" } ?? ""
                column.line("\(r.name)\(size)")
            }
            // Total of the known sizes, marked "+" while any size is still outstanding.
            let known = regions.compactMap { extractSizes[$0.id] }
            let total = Fmt.bytes(known.reduce(Int64(0), +))
                + (known.count < regions.count ? "+" : "")
            if regions.count > 8 {
                column.line(t("and %d more", regions.count - 8) + "  ·  "
                     + t("%@ in all", total), tone: theme.faint)
            } else if !known.isEmpty {
                column.line(t("%@ in all", total), tone: theme.faint)
            }
            if recipe.coverage.isValid {
                column.line(recipe.coverage.display, tone: theme.dim)
                column.line(t("bounds around them all — the map itself covers only the regions"
                     + " themselves"), tone: theme.faint)
            }
        }
        column.gap()
    }

    /// One section for everything the build costs: what it fetches, its output size,
    /// and the resulting file count.
    private func summarizeCost(into column: inout SummaryColumn, ctx: AppContext) {
        let theme = column.theme
        // One section for everything the build costs: what it fetches, its output size,
        // and the resulting file count.
        column.caption(t("cost"))
        if recipe.needsElevationData {
            // Spinner alone while the estimate runs: the previous figure belongs to the
            // previous source.
            if elevationCosting || elevationCost.isEmpty {
                column.line(t("%@ working out what this costs to fetch",
                       String(Widgets.spinner(ctx.frame))), tone: theme.faint)
            }
            let costs = elevationCosting ? [] : elevationCost
            if let first = costs.first {
                let cached = costs.map(\.cached).max() ?? 0
                column.line(tn("elevation: %d cell(s) after the outline trim", first.cells)
                     + (cached > 0 ? "  ·  " + t("%d already in the cache", cached) : ""),
                     tone: theme.faint)
            }
            for cost in costs {
                column.line(costLine(cost),
                     tone: (cost.bytes ?? 0) > 2_000_000_000 ? theme.warn : theme.dim)
            }
            // The chain's sum, when more than one link actually fetches.
            let fetching = costs.filter { ($0.bytes ?? 0) > 0 }
            if fetching.count > 1 {
                let total = fetching.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
                column.line(t("%@ to download in all", Fmt.bytes(total)),
                     tone: total > 2_000_000_000 ? theme.warn : theme.faint)
            }
            let tiles = regions.reduce(0) { $0 + $1.demTileCount }
            if recipe.contours && recipe.contourInterval <= 10 && tiles > 60 {
                column.line(t("a %d m interval over this many tiles makes a large map and a long"
                     + " build", recipe.contourInterval), tone: theme.warn)
            }
        }
        switch recipe.splitMode {
        case .fitCard:
            column.line(t("written as one file when it fits a FAT32 card, several"
                 + " when it does not"), tone: theme.dim)
        case .perRegion:
            column.line(t("one file per region, so a region can be left off the card"), tone: theme.dim)
        case .perCountry:
            column.line(t("one file per country, its regions gathered together"), tone: theme.dim)
        case .count(let n):
            column.line(tn("%d file(s) of equal weight, whatever that means for the card", n),
                 tone: theme.dim)
        }
        if recipe.codePage == CodePage.cyrillic {
            column.line(t("code page 1251 — Cyrillic names"), tone: theme.dim)
        }
        column.gap()
    }

    /// One source of the elevation chain, as a sentence: what it fetches, what that
    /// weighs, and how sure the figure is.
    private func costLine(_ cost: ElevationCost.Estimate) -> String {
        var said = cost.source + "  ·  "
        if cost.wanted == 0 {
            said += t("nothing to fetch — cached or already covered")
            return said
        }
        switch cost.bytes {
        case nil:
            said += cost.note ?? tn("%d cell(s), unmeasured", cost.wanted)
        case 0:
            said += cost.note ?? t("nothing to fetch")
        case let bytes?:
            said += t("about %@ to download", Fmt.bytes(bytes))
            said += "  ·  " + (cost.archives > 0
                ? tn("%d zone archive(s)", cost.archives)
                : tn("%d tile(s)", cost.published))
            if let note = cost.note {
                said += "  ·  " + note
            } else if cost.exact {
                said += "  ·  " + t("every size asked")
            } else {
                said += "  ·  " + tn("measured on %d tile(s)", cost.sampled)
            }
        }
        return said
    }

    private func summarizeDestination(into column: inout SummaryColumn) {
        let theme = column.theme
        column.caption(t("output folder"))
        column.line(recipe.outputFolderName)
        column.line(Paths.display(recipe.outputDirectory), tone: theme.faint)
        column.gap()
    }

    /// Conditional notes only.
    private func summarizeNotes(into column: inout SummaryColumn) {
        let theme = column.theme
        var notes: [(String, Color)] = []
        if recipe.style.typURL == nil {
            notes.append((t("no TYP — the device picks the colours"), theme.warn))
        }
        if recipe.codePage == CodePage.westernEuropean, recipe.coverage.isValid,
           recipe.coverage.minLon > CodePage.cyrillicMeridian {
            notes.append((t("code page 1252 cannot hold Cyrillic — set 1251 if the names"
                          + " here are in it"), theme.warn))
        }
        if form.isModified, form.currentProfile != nil {
            notes.append((t("changed on this screen — the map is built with what is on it,"
                          + " and the profile is left as it was"), theme.dim))
        }
        if !notes.isEmpty {
            column.caption(t("worth knowing"))
            for (text, tone) in notes { column.line(text, tone: tone) }
            column.gap()
        }
    }

    /// The full explanation for the selected row, whose value on the left is often
    /// truncated.
    private func summarizeSelection(into column: inout SummaryColumn, ctx: AppContext) {
        // The full explanation for the selected row, whose value on the left is often
        // truncated.
        if let field = form.selectedField {
            let told = explanation(field, ctx)
            if !told.isEmpty {
                column.caption(field.label.lowercased())
                for (text, tone) in told { column.line(text, tone: tone) }
            }
        }
    }

    /// Explanatory lines for the selected row, each with the colour it is drawn in.
    private func explanation(_ field: RecipeForm.Field,
                             _ ctx: AppContext) -> [(String, Color)] {
        let theme = ctx.theme
        switch field {
        case .profile:
            guard let profile = form.currentProfile else { return [] }
            return [(profile.name, theme.text),
                    (t("a saved set of the choices on this screen"), theme.faint)]
        case .style:
            var out: [(String, Color)] = [(t(recipe.style.summary), theme.faint)]
            out.append((t("family id %d", recipe.style.familyID), theme.dim))
            return out
        case .zoomPlan:
            var out: [(String, Color)] = [(recipe.levels.note, theme.faint),
                                          (recipe.levels.levels, theme.dim)]
            if recipe.zoomPlan.movesAnything {
                out.append((tn("%d family(ies) moved", recipe.zoomPlan.windows.count),
                            theme.ok))
            }
            out.append((t("edit these on the Zoom plans screen"), theme.faint))
            return out
        case .healRoads:
            return [
                (t("In OSM two roads can touch on screen yet share no point — for the "
                 + "router that is a dead end, and no route crosses it. This joins ends "
                 + "closer than %d m, and only where there is no way through at all: an "
                 + "existing route is never changed, however long the detour.",
                 Int(recipe.healRadius)), theme.faint),
                (t("Never through a building, a fence, a wall or a hedge — whether a plot "
                 + "can be crossed is OSM's to say — and never a footway onto the road it "
                 + "runs beside."), theme.dim),
                (t("A kerb, a bank or a step between the two ends is crossed by a separate "
                 + "short link, drawn as a thin dotted line, so the map shows what it "
                 + "steps over."), theme.dim),
            ]
        case .customPOIs:
            return [
                (t("A .gpi beside the map, holding every object that has an OSM description. "
                 + "The only Garmin format with a real description field."), theme.faint),
                (t("Copy it to Garmin/POI on the device; it opens under Custom POIs."),
                 theme.dim),
            ]
        case .descriptions:
            guard recipe.descriptions != .off else { return [] }
            return [(recipe.descriptions == .inName
                     ? t("OSM description text is appended to the object's own name.")
                     : t("OSM description text is shown when an object is opened, never on the map."),
                     theme.faint)]
        case .hide:
            guard !recipe.hidden.isEmpty else { return [] }
            let names = recipe.hidden.compactMap { HideableFeature.feature(id: $0)?.localizedName }
            return [(names.sorted().joined(separator: ", "), theme.faint)]
        default:
            return []
        }

    }

}

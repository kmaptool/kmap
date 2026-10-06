import Foundation

/// The panel beside the form: the regions, what the build costs, where it lands, and
/// what the selected row means.
@MainActor
struct RecipeSummaryPanel {
    let form: RecipeForm
    let regions: [Region]
    let sizes: ExtractSizes
    let cost: ElevationCostProbe

    private static let mostRegionsListed = 8
    private static let largeDownload: Int64 = 2_000_000_000
    /// A fine contour interval over this many tiles makes a large map.
    private static let manyTiles = 60
    private static let fineInterval = 10

    private var recipe: BuildRecipe { form.recipe }
    private var region: Region { regions[0] }

    func draw(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        s.vline(rect.x - 2, rect.y, rect.h, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))
        var column = SummaryColumn(s: s, rect: rect, theme: theme, y: rect.y)
        summarizeRegions(into: &column)
        summarizeCost(into: &column, ctx: ctx)
        summarizeDestination(into: &column)
        summarizeNotes(into: &column)
        summarizeSelection(into: &column, ctx: ctx)
    }

    private func summarizeRegions(into column: inout SummaryColumn) {
        let theme = column.theme
        if regions.count == 1 {
            column.caption(t("region"))
            if let size = sizes[region] {
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
            for r in regions.prefix(Self.mostRegionsListed) {
                let size = sizes[r].map { "  \(Fmt.bytes($0))" } ?? ""
                column.line("\(r.name)\(size)")
            }
            // The known sizes, marked "+" while any is still outstanding.
            let known = regions.compactMap { sizes[$0] }
            let total = Fmt.bytes(known.reduce(Int64(0), +)) + (known.count < regions.count ? "+" : "")
            if regions.count > Self.mostRegionsListed {
                column.line(
                    t("and %d more", regions.count - Self.mostRegionsListed) + "  ·  " + t("%@ in all", total),
                    tone: theme.faint
                )
            } else if !known.isEmpty {
                column.line(t("%@ in all", total), tone: theme.faint)
            }
            if recipe.coverage.isValid {
                column.line(recipe.coverage.display, tone: theme.dim)
                column.line(
                    t("bounds around them all — the map itself covers only the regions themselves"),
                    tone: theme.faint
                )
            }
        }
        column.gap()
    }

    /// What the build fetches, what it writes, and how many files.
    private func summarizeCost(into column: inout SummaryColumn, ctx: AppContext) {
        let theme = column.theme
        column.caption(t("cost"))
        if recipe.needsElevationData { summarizeElevation(into: &column, ctx: ctx) }
        if recipe.format.writesCardFiles {
            switch recipe.splitMode {
            case .fitCard:
                column.line(
                    t("written as one file when it fits a FAT32 card, several when it does not"),
                    tone: theme.dim
                )
            case .perRegion:
                column.line(t("one file per region, so a region can be left off the card"), tone: theme.dim)
            case .perCountry:
                column.line(t("one file per country, its regions gathered together"), tone: theme.dim)
            case .count(let n):
                column.line(tn("%d file(s) of equal weight, whatever that means for the card", n), tone: theme.dim)
            }
        }
        if recipe.format.writesGmap {
            column.line(
                t("a .gmap folder for BaseCamp as well, about the size of the tiles; the tiles are packed twice"),
                tone: theme.dim
            )
        }
        if recipe.codePage == CodePage.cyrillic {
            column.line(t("code page 1251 — Cyrillic names"), tone: theme.dim)
        }
        column.gap()
    }

    private func summarizeElevation(into column: inout SummaryColumn, ctx: AppContext) {
        let theme = column.theme
        // A spinner alone while the estimate runs: the old figure belongs to the old source.
        if cost.isRunning || cost.estimates.isEmpty {
            column.line(
                t("%@ working out what this costs to fetch", String(Widgets.spinner(ctx.frame))),
                tone: theme.faint
            )
        }
        let costs = cost.isRunning ? [] : cost.estimates
        if let first = costs.first {
            let cached = costs.map(\.cached).max() ?? 0
            column.line(
                tn("elevation: %d cell(s) after the outline trim", first.cells)
                    + (cached > 0 ? "  ·  " + t("%d already in the cache", cached) : ""),
                tone: theme.faint
            )
        }
        for cost in costs {
            column.line(costLine(cost), tone: (cost.bytes ?? 0) > Self.largeDownload ? theme.warn : theme.dim)
        }
        let fetching = costs.filter { ($0.bytes ?? 0) > 0 }
        if fetching.count > 1 {
            let total = fetching.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
            column.line(
                t("%@ to download in all", Fmt.bytes(total)),
                tone: total > Self.largeDownload ? theme.warn : theme.faint
            )
        }
        let tiles = regions.reduce(0) { $0 + $1.demTileCount }
        if recipe.contours && recipe.contourInterval <= Self.fineInterval && tiles > Self.manyTiles {
            column.line(
                t("a %d m interval over this many tiles makes a large map and a long build", recipe.contourInterval),
                tone: theme.warn
            )
        }
    }

    /// One source of the chain: what it fetches, what that weighs, how sure the figure is.
    private func costLine(_ cost: ElevationCost.Estimate) -> String {
        var said = cost.source + "  ·  "
        if cost.wanted == 0 {
            return said + t("nothing to fetch — cached or already covered")
        }
        switch cost.bytes {
        case nil:
            said += cost.note ?? tn("%d cell(s), unmeasured", cost.wanted)
        case 0:
            said += cost.note ?? t("nothing to fetch")
        case let bytes?:
            said += t("about %@ to download", Fmt.bytes(bytes))
            said +=
                "  ·  "
                + (cost.archives > 0 ? tn("%d zone archive(s)", cost.archives) : tn("%d tile(s)", cost.published))
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
        column.caption(t("output folder"))
        column.line(recipe.outputFolderName)
        column.line(Paths.display(recipe.outputDirectory), tone: column.theme.faint)
        column.gap()
    }

    private func summarizeNotes(into column: inout SummaryColumn) {
        let theme = column.theme
        var notes: [(String, Color)] = []
        if recipe.style.typURL == nil {
            notes.append((t("no TYP — the device picks the colours"), theme.warn))
        }
        if recipe.codePage == CodePage.westernEuropean, recipe.coverage.isValid,
            recipe.coverage.minLon > CodePage.cyrillicMeridian
        {
            notes.append((t("code page 1252 cannot hold Cyrillic — set 1251 if the names here are in it"), theme.warn))
        }
        if recipe.repairsRoadsBlind {
            notes.append(
                (
                    t(
                        "road ends are repaired without elevation data — a drop between them may go unseen. Turning the DEM layer on is recommended"
                    ), theme.warn
                )
            )
        }
        if form.isModified, form.currentProfile != nil {
            notes.append(
                (
                    t(
                        "changed on this screen — the map is built with what is on it, and the profile is left as it was"
                    ), theme.dim
                )
            )
        }
        guard !notes.isEmpty else { return }
        column.caption(t("worth knowing"))
        for (text, tone) in notes { column.line(text, tone: tone) }
        column.gap()
    }

    /// The full explanation of the selected row, whose value on the left is often cut.
    private func summarizeSelection(into column: inout SummaryColumn, ctx: AppContext) {
        guard let field = form.selectedField else { return }
        let told = explanation(field, ctx)
        guard !told.isEmpty else { return }
        column.caption(field.label.lowercased())
        for (text, tone) in told { column.line(text, tone: tone) }
    }

    private func explanation(_ field: RecipeForm.Field, _ ctx: AppContext) -> [(String, Color)] {
        let theme = ctx.theme
        switch field {
        case .profile:
            guard let profile = form.currentProfile else { return [] }
            return [(profile.name, theme.text), (t("a saved set of the choices on this screen"), theme.faint)]
        case .style:
            // The style's own TYP number, not the map's: the map's is the Family id row.
            return [(t(recipe.style.summary), theme.faint), (t("TYP family %d", recipe.style.familyID), theme.dim)]
        case .zoomPlan:
            var out: [(String, Color)] = [(recipe.levels.note, theme.faint), (recipe.levels.levels, theme.dim)]
            if recipe.zoomPlan.movesAnything {
                out.append((tn("%d family(ies) moved", recipe.zoomPlan.windows.count), theme.ok))
            }
            out.append((t("edit these on the Zoom plans screen"), theme.faint))
            return out
        case .healRoads:
            return [
                (
                    t(
                        "Two roads can meet on screen without sharing a point — to the router "
                            + "that is a dead end. kmap joins forgotten road ends closer than %d m, "
                            + "and only where there is no way round at all.",
                        Int(recipe.healRadius)
                    ), theme.faint
                ),
                (
                    t(
                        "It never joins through a building, a fence or a hedge: whether a plot "
                            + "can be crossed is OSM's to say. Where the gap crosses a kerb or a "
                            + "step, kmap adds a thin dotted line, and the map shows that the gap "
                            + "was mended for you."
                    ), theme.dim
                )
            ]
        case .customPOIs:
            return [
                (
                    t(
                        "A .gpi beside the map, holding every object that has an OSM description. "
                            + "The only Garmin format with a real description field."
                    ), theme.faint
                ),
                (t("Copy it to Garmin/POI on the device; it opens under Custom POIs."), theme.dim)
            ]
        case .descriptions:
            guard recipe.descriptions != .off else { return [] }
            return [
                (
                    recipe.descriptions == .inName
                        ? t("OSM description text is appended to the object's own name.")
                        : t("OSM description text is shown when an object is opened, never on the map."),
                    theme.faint
                )
            ]
        case .hide:
            guard !recipe.hidden.isEmpty else { return [] }
            let names = recipe.hidden.compactMap { HideableFeature.feature(id: $0)?.localizedName }
            return [(names.sorted().joined(separator: ", "), theme.faint)]
        default:
            return []
        }
    }
}

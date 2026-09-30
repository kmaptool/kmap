import Foundation

/// Browses the Geofabrik region tree and hands the chosen regions to the recipe screen.
final class RegionPickerScreen: Screen {
    var page: Page { Page(t("regions"), subject: search.subject, keys: keys) }

    private var keys: [Hint] {
        if search.open { return search.hints }
        if !marked.isEmpty {
            return [
                Hint(key: "space", label: t("mark")),
                Hint(key: "→←", label: t("browse")),
                Hint(key: Glyph.enter, label: t("build %d", marked.count)),
                Hint(key: "c", label: t("clear"))
            ]
        }
        return [
            Hint(key: "↑↓", label: t("move")),
            Hint(key: "→", label: t("open")),
            Hint(key: "←", label: t("back")),
            Hint(key: Glyph.enter, label: t("choose")),
            Hint(key: "space", label: t("mark several")),
            Hint(key: "/", label: t("search"))
        ]
    }

    var currentID: String? = nil
    var list = ListState()
    /// A query stays applied once kept, so search results can be marked and opened.
    var search = SearchPrompt()
    var message: String?
    /// The selection at each level left, so going back lands where it was.
    private var trail: [(id: String?, selected: Int)] = []
    let sizes = ExtractSizes()
    /// Regions to build as one map, in the order marked; the first names the map. An
    /// overlap is refused, since the shared ground would be built twice.
    var marked: [String] = []

    func visibleRegions(_ ctx: AppContext) -> [Region] {
        if !search.query.isEmpty { return ctx.index.search(search.query) }
        return ctx.index.children(of: currentID)
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        if search.open { return search.take(key, list: &list) }
        let regions = visibleRegions(ctx)

        switch key.command {
        case .char(" "):
            guard let region = regions[safe: list.selected] else { return .none }
            mark(region, ctx)
            list.move(1, count: regions.count)
        case .char("c"):
            guard !marked.isEmpty else { return .none }
            marked.removeAll()
            message = nil
        case .up, .char("k"): list.move(-1, count: regions.count)
        case .down, .char("j"): list.move(1, count: regions.count)
        case .pageUp: list.page(-1, count: regions.count)
        case .pageDown: list.page(1, count: regions.count)
        case .home: list.jump(to: 0, count: regions.count)
        case .end: list.jump(to: regions.count - 1, count: regions.count)
        case .char("/"): search.open = true
        case .char("r"):
            message = t("refreshing the region index…")
            ctx.loadIndexIfNeeded(force: true)
        case .right, .char("l"), .tab:
            guard let region = regions[safe: list.selected], region.hasChildren else { return .none }
            descend(into: region.id)
        case .left, .char("h"):
            return ascend()
        case .esc:
            if search.drop(list: &list) { return .none }
            if currentID == nil { return .pop }
            return ascend()
        case .enter:
            if !marked.isEmpty { return buildMarked(ctx) }
            guard let region = regions[safe: list.selected] else { return .none }
            return open(region, ctx)
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// Enter with marks builds the marks; they are emptied so Enter next means the row.
    private func buildMarked(_ ctx: AppContext) -> Route {
        let chosen = marked.compactMap { ctx.index.region($0) }
        guard !chosen.isEmpty else { return .none }
        marked.removeAll()
        message = nil
        return .push(recipe(for: chosen, ctx))
    }

    private func recipe(for regions: [Region], _ ctx: AppContext) -> RecipeScreen {
        RecipeScreen(
            regions: regions,
            index: ctx.index,
            settings: ctx.settings,
            hasSeamPatch: ctx.toolchain.mkgmapIsPatched
        )
    }

    /// Adds a region to the basket, or takes it out. Marking one drops any marked inside
    /// it; marking inside an already marked one is refused.
    private func mark(_ region: Region, _ ctx: AppContext) {
        guard region.pbfURL != nil else {
            message = t("%@ has no extract of its own — open it and mark inside", region.name)
            return
        }
        if let at = marked.firstIndex(of: region.id) {
            marked.remove(at: at)
            message = nil
            return
        }
        if let covering = marked.first(where: { ctx.index.isAncestor($0, of: region.id) }) {
            message = t("%@ already covers that", ctx.index.region(covering)?.name ?? covering)
            return
        }
        let inside = marked.filter { ctx.index.isAncestor(region.id, of: $0) }
        if !inside.isEmpty {
            marked.removeAll { inside.contains($0) }
            message = tn("%2$@ replaces %1$d marked inside it", inside.count, region.name)
        } else {
            message = nil
        }
        marked.append(region.id)
        sizes.probe(region)
    }

    /// Leaving the list, by either door, drops a kept search.
    private func open(_ region: Region, _ ctx: AppContext) -> Route {
        if region.pbfURL != nil {
            search.query = ""
            return .push(recipe(for: [region], ctx))
        }
        if region.hasChildren {
            descend(into: region.id)
            return .none
        }
        message = t("%@ has no downloadable extract", region.name)
        return .none
    }

    private func descend(into id: String) {
        search.query = ""
        trail.append((currentID, list.selected))
        currentID = id
        list = ListState()
    }

    private func ascend() -> Route {
        guard let previous = trail.popLast() else {
            if currentID == nil { return .pop }
            currentID = nil
            list = ListState()
            return .none
        }
        currentID = previous.id
        list = ListState()
        list.selected = previous.selected
        return .none
    }

    func tick(_ ctx: AppContext) {
        ctx.loadIndexIfNeeded()
        if let region = visibleRegions(ctx)[safe: list.selected] { sizes.probe(region) }
    }
}

import Foundation

/// Browses the Geofabrik region tree and hands the chosen region to the recipe screen.
final class RegionPickerScreen: Screen {
    var page: Page { Page(t("regions"), subject: searching ? t("search") : nil, keys: keys) }

    private var keys: [Hint] {
        if !marked.isEmpty {
            return [Hint(key: "space", label: t("mark")),
                    Hint(key: "→←", label: t("browse")),
                    Hint(key: Glyph.enter, label: t("build %d", marked.count)),
                    Hint(key: "c", label: t("clear"))]
        }
        if searching {
            return [Hint(key: "type", label: t("filter")),
                    Hint(key: Glyph.enter, label: t("open")),
                    Hint(key: "esc", label: t("cancel"))]
        }
        return [Hint(key: "↑↓", label: t("move")),
                Hint(key: "→", label: t("open")),
                Hint(key: "←", label: t("back")),
                Hint(key: Glyph.enter, label: t("choose")),
                Hint(key: "space", label: t("mark several")),
                Hint(key: "/", label: t("search"))]
    }

    private var currentID: String? = nil
    private var list = ListState()
    private var searching = false
    private var query = ""
    private var message: String?

    /// Remembered selection per level, so going back lands where it left off.
    private var trail: [(id: String?, selected: Int)] = []

    /// Lazily probed remote sizes, keyed by region id.
    private var sizes: [String: Int64] = [:]
    private var probing = Set<String>()

    /// Regions marked with space, to be built as one map, filled from anywhere in the tree.
    /// An overlap is refused, since the shared ground would be built twice. Order is the
    /// order they were marked in, and the first one names the map.
    private var marked: [String] = []

    // MARK: Data

    private func visibleRegions(_ ctx: AppContext) -> [Region] {
        if searching && !query.isEmpty { return ctx.index.search(query) }
        return ctx.index.children(of: currentID)
    }

    // MARK: Input

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        let regions = visibleRegions(ctx)

        if searching {
            switch key {
            case .esc:
                searching = false
                query = ""
                list.selected = 0
                return .none
            case .backspace:
                if !query.isEmpty { query.removeLast(); list.selected = 0 }
                return .none
            case .char(let c):
                query.append(c)
                list.selected = 0
                return .none
            case .paste(let text):
                query += text.replacingOccurrences(of: "\n", with: " ")
                return .none
            case .up: list.move(-1, count: regions.count); return .none
            case .down: list.move(1, count: regions.count); return .none
            case .enter:
                guard let region = regions[safe: list.selected] else { return .none }
                searching = false
                query = ""
                return open(region, ctx)
            default:
                return .none
            }
        }

        switch key.command {
        case .char(" "):
            guard let region = regions[safe: list.selected] else { return .none }
            mark(region, ctx)
            list.move(1, count: regions.count)
            return .none

        case .char("c"):
            guard !marked.isEmpty else { return .none }
            marked.removeAll()
            message = nil
            return .none

        case .up, .char("k"): list.move(-1, count: regions.count)
        case .down, .char("j"): list.move(1, count: regions.count)
        case .pageUp: list.move(-10, count: regions.count, wrap: false)
        case .pageDown: list.move(10, count: regions.count, wrap: false)
        case .home: list.jump(to: 0, count: regions.count)
        case .end: list.jump(to: regions.count - 1, count: regions.count)

        case .char("/"):
            searching = true
            query = ""
            list.selected = 0

        case .char("r"):
            message = t("refreshing the region index…")
            ctx.loadIndexIfNeeded(force: true)

        case .right, .char("l"), .tab:
            guard let region = regions[safe: list.selected], region.hasChildren else { return .none }
            descend(into: region.id)

        case .left, .char("h"):
            return ascend()

        case .esc:
            if currentID == nil { return .pop }
            return ascend()

        case .enter:
            if !marked.isEmpty {
                let chosen = marked.compactMap { ctx.index.region($0) }
                guard !chosen.isEmpty else { return .none }
                // Emptied here, so ⏎ always means what is on screen: the marks while
                // there are marks, the highlighted row once there are none.
                marked.removeAll()
                message = nil
                return .push(RecipeScreen(regions: chosen, index: ctx.index,
                                          settings: ctx.settings,
                                          hasSeamPatch: ctx.toolchain.mkgmapIsPatched))
            }
            guard let region = regions[safe: list.selected] else { return .none }
            return open(region, ctx)

        case .ctrl("c"):
            return .quit

        default:
            break
        }
        return .none
    }

    /// Adds a region to the basket, or takes it out again. Marking a region drops any
    /// marked inside it; marking one inside an already-marked region is refused, since the
    /// shared ground would be written twice into every tile it touched.
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
            message = t("%@ already covers that",
                        ctx.index.region(covering)?.name ?? covering)
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
        probeSize(region)
    }

    private func open(_ region: Region, _ ctx: AppContext) -> Route {
        if region.pbfURL != nil {
            return .push(RecipeScreen(region: region, index: ctx.index,
                                      settings: ctx.settings,
                                      hasSeamPatch: ctx.toolchain.mkgmapIsPatched))
        }
        if region.hasChildren {
            descend(into: region.id)
            return .none
        }
        message = t("%@ has no downloadable extract", region.name)
        return .none
    }

    private func descend(into id: String) {
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

    // MARK: Background size probing

    func tick(_ ctx: AppContext) {
        ctx.loadIndexIfNeeded()
        let regions = visibleRegions(ctx)
        guard let region = regions[safe: list.selected],
              region.pbfURL != nil,
              sizes[region.id] == nil,
              !probing.contains(region.id) else { return }

        probeSize(region)
    }

    private func probeSize(_ region: Region) {
        guard let url = region.pbfURL, sizes[region.id] == nil,
              !probing.contains(region.id) else { return }
        probing.insert(region.id)
        Task { [weak self] in
            let info = try? await Downloader.probe(url)
            guard let self else { return }
            // Back on the main actor, where the render loop reads these.
            await MainActor.run {
                self.probing.remove(region.id)
                if let info { self.sizes[region.id] = info.size }
            }
        }
    }

    // MARK: Render

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme

        if case .loading = ctx.indexState, ctx.index.regions.isEmpty {
            Widgets.notice(s, rect: rect, title: t("loading"),
                           message: t("Fetching the region index from Geofabrik %@",
                                      String(Widgets.spinner(ctx.frame))),
                           theme: theme)
            return
        }
        if case .failed(let error) = ctx.indexState, ctx.index.regions.isEmpty {
            Widgets.notice(s, rect: rect, title: t("index unavailable"),
                           message: error + "\n\n" + t("Press r to try again."),
                           theme: theme, tone: theme.danger)
            return
        }

        renderHeader(into: s, rect: rect, ctx: ctx, theme: theme)

        let regions = visibleRegions(ctx)
        let bodyY = rect.y + 2
        let bodyHeight = rect.h - 2
        guard bodyHeight > 0 else { return }

        let detailWidth = rect.w >= 92 ? 38 : 0
        let listWidth = rect.w - detailWidth - (detailWidth > 0 ? 3 : 0)
        let listRect = Rect(x: rect.x, y: bodyY, w: listWidth, h: bodyHeight)

        renderList(regions, into: s, listRect: listRect, bodyHeight: bodyHeight,
                   theme: theme)

        if detailWidth > 0 {
            let detail = Rect(x: rect.x + listWidth + 3, y: bodyY, w: detailWidth, h: bodyHeight)
            if marked.isEmpty {
                if let region = regions[safe: list.selected] {
                    renderDetail(s, rect: detail, region: region, ctx: ctx)
                }
            } else {
                renderBasket(s, rect: detail, ctx: ctx)
            }
        }

        if let message {
            s.text(rect.x, rect.maxY - 1, truncate(message, to: rect.w),
                   Style(fg: theme.warn, bg: theme.appBg))
        }
    }

    /// The breadcrumb, or the search field, with the marked total riding on the right.
    private func renderHeader(into s: Surface, rect: Rect, ctx: AppContext, theme: Theme) {
        if searching {
            let prompt = t("search") + ": "
            let x = s.text(rect.x, rect.y, prompt, Style(fg: theme.dim, bg: theme.appBg))
            let end = s.text(x, rect.y, query, Style(fg: theme.strong, bg: theme.appBg, bold: true))
            s.put(end, rect.y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        } else {
            let crumb = ctx.index.breadcrumb(currentID)
            let x = s.text(rect.x, rect.y, truncate(crumb, to: rect.w),
                           Style(fg: theme.dim, bg: theme.appBg))
            if !marked.isEmpty {
                var summary = "  \(Glyph.dot) " + tn("%d marked", marked.count)
                let known = marked.compactMap { sizes[$0] }
                if known.count == marked.count {
                    summary += ", \(Fmt.bytes(known.reduce(0, +)))"
                } else if !known.isEmpty {
                    summary += ", \(Fmt.bytes(known.reduce(0, +)))+"
                }
                s.text(x, rect.y, truncate(summary, to: max(0, rect.maxX - x)),
                       Style(fg: theme.accent, bg: theme.appBg, bold: true))
            }
        }
        s.hline(rect.x, rect.y + 1, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
    }

    /// One row per region: marker, name, and either its size or its child count.
    private func renderList(_ regions: [Region], into s: Surface, listRect: Rect,
                            bodyHeight: Int, theme: Theme) {
        guard !regions.isEmpty else {
            let text = searching ? t("nothing matches \"%@\"", query) : t("no sub-regions here")
            s.text(listRect.x, listRect.y, text, Style(fg: theme.faint, bg: theme.appBg))
            return
        }
        list.clamp(count: regions.count, visible: bodyHeight)
        let visible = min(bodyHeight, regions.count - list.offset)
        for i in 0..<visible {
            let index = list.offset + i
            guard let region = regions[safe: index] else { break }
            let y = listRect.y + i

            var trailing: String?
            if let size = sizes[region.id] {
                trailing = Fmt.bytes(size)
            } else if region.hasChildren && region.pbfURL == nil {
                trailing = tn("%d region(s)", region.childIDs.count)
            }

            let isMarked = marked.contains(region.id)
            let leading = isMarked
                ? "\(Glyph.check) "
                : (region.hasChildren ? "\(Glyph.arrowRight) " : "  ")
            Widgets.row(s, rect: Rect(x: listRect.x, y: y, w: listRect.w - 1, h: 1),
                        y: y,
                        text: searching ? "\(region.name)  \(Glyph.dot) \(region.id)" : region.name,
                        trailing: trailing,
                        theme: theme,
                        selected: index == list.selected,
                        dimmed: region.pbfURL == nil,
                        leading: leading,
                        leadingColor: isMarked ? theme.picked : nil)
        }
        Widgets.scrollHint(s, rect: listRect, offset: list.offset,
                           count: regions.count, visible: bodyHeight, theme: theme)
    }

    /// What is in the basket, and what it comes to. Replaces the detail panel while marking.
    private func renderBasket(_ s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y
        s.vline(rect.x - 2, rect.y, rect.h, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))
        s.text(rect.x, y, t("building together"),
               Style(fg: theme.strong, bg: theme.appBg, bold: true))
        y += 2

        var total: Int64 = 0
        var complete = true
        for id in marked {
            guard y < rect.maxY - 3 else {
                s.text(rect.x, y, t("… and %d more", marked.count - (y - rect.y - 2)),
                       Style(fg: theme.faint, bg: theme.appBg))
                y += 1
                break
            }
            let region = ctx.index.region(id)
            let size = sizes[id]
            if let size { total += size } else { complete = false }
            s.text(rect.x, y, truncate(region?.name ?? id, to: rect.w - 10),
                   Style(fg: theme.text, bg: theme.appBg))
            if let size {
                let text = Fmt.bytes(size)
                s.text(rect.maxX - text.count, y, text, Style(fg: theme.faint, bg: theme.appBg))
            }
            y += 1
        }

        y = max(y + 1, rect.maxY - 3)
        guard y < rect.maxY else { return }
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1
        s.text(rect.x, y, t("to download"), Style(fg: theme.faint, bg: theme.appBg), limit: 13)
        s.text(rect.x + 13, y, Fmt.bytes(total) + (complete ? "" : " +"),
               Style(fg: theme.text, bg: theme.appBg))
        y += 1
        guard y < rect.maxY else { return }
        s.text(rect.x, y, t("⏎ builds one map · c clears"),
               Style(fg: theme.faint, bg: theme.appBg))
    }

    private func renderDetail(_ s: Surface, rect: Rect, region: Region, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        s.vline(rect.x - 2, rect.y, rect.h, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))

        s.text(rect.x, y, truncate(region.name, to: rect.w),
               Style(fg: theme.strong, bg: theme.appBg, bold: true))
        y += 1
        s.text(rect.x, y, truncate(region.id, to: rect.w), Style(fg: theme.faint, bg: theme.appBg))
        y += 2

        func line(_ label: String, _ value: String, tone: Color? = nil) {
            guard y < rect.maxY else { return }
            s.text(rect.x, y, label, Style(fg: theme.faint, bg: theme.appBg), limit: 11)
            for (i, chunk) in wrapText(value, width: max(1, rect.w - 11)).enumerated() {
                guard y < rect.maxY else { return }
                s.text(rect.x + 11, y, chunk, Style(fg: tone ?? theme.text, bg: theme.appBg))
                y += 1
                if i > 3 { break }
            }
        }

        if let size = sizes[region.id] {
            line(t("extract"), Fmt.bytes(size))
        } else if region.pbfURL != nil {
            line(t("extract"), probing.contains(region.id)
                    ? t("checking %@", String(Widgets.spinner(ctx.frame))) : "—",
                 tone: theme.dim)
        } else {
            line(t("extract"), t("not downloadable"), tone: theme.warn)
        }

        if region.hasChildren {
            line(t("contains"), tn("%d sub-region(s)", region.childIDs.count))
        }

        if region.bbox.isValid {
            line(t("bounds"), region.bbox.display)
            let tiles = region.demTileCount
            line(t("elevation"), tn("%d × 1° tile(s)", tiles))
        }

        let cached = Paths.pbfCache.appendingPathComponent("\(FileTools.slugify(region.id)).osm.pbf")
        if FileTools.exists(cached) {
            line(t("cached"), Fmt.bytes(FileTools.size(of: cached)), tone: theme.ok)
        }

        let codePage = BuildRecipe.suggestedCodePage(for: region)
        if codePage != CodePage.westernEuropean {
            line(t("code page"), t("%d suggested", codePage), tone: theme.warn)
        }
    }
}

// MARK: - Safe indexing

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

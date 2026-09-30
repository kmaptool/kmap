import Foundation

/// Drawing the region tree: the breadcrumb or search, the list, and beside it the
/// selected region or the basket of marked ones.
extension RegionPickerScreen {
    private static let leastWidthForDetail = 92
    private static let detailWidth = 38
    private static let gutter = 3
    private static let labelColumn = 11
    private static let basketLabelColumn = 13
    private static let basketFooterRows = 3
    private static let mostValueLines = 4

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        if case .loading = ctx.indexState, ctx.index.regions.isEmpty {
            Widgets.notice(
                s,
                rect: rect,
                title: t("loading"),
                message: t("Fetching the region index from Geofabrik %@", String(Widgets.spinner(ctx.frame))),
                theme: theme
            )
            return
        }
        if case .failed(let error) = ctx.indexState, ctx.index.regions.isEmpty {
            Widgets.notice(
                s,
                rect: rect,
                title: t("index unavailable"),
                message: error + "\n\n" + t("Press r to try again."),
                theme: theme,
                tone: theme.danger
            )
            return
        }

        renderHeader(into: s, rect: rect, ctx: ctx, theme: theme)

        let regions = visibleRegions(ctx)
        let bodyY = rect.y + 2
        let bodyHeight = rect.h - 2
        guard bodyHeight > 0 else { return }

        let detailWidth = rect.w >= Self.leastWidthForDetail ? Self.detailWidth : 0
        let listWidth = rect.w - detailWidth - (detailWidth > 0 ? Self.gutter : 0)
        renderList(regions, into: s, listRect: Rect(x: rect.x, y: bodyY, w: listWidth, h: bodyHeight), theme: theme)

        if detailWidth > 0 {
            let detail = Rect(x: rect.x + listWidth + Self.gutter, y: bodyY, w: detailWidth, h: bodyHeight)
            if marked.isEmpty {
                if let region = regions[safe: list.selected] {
                    renderDetail(s, rect: detail, region: region, ctx: ctx)
                }
            } else {
                renderBasket(s, rect: detail, ctx: ctx)
            }
        }

        if let message {
            s.text(rect.x, rect.maxY - 1, truncate(message, to: rect.w), Style(fg: theme.warn, bg: theme.appBg))
        }
    }

    /// The breadcrumb, or the search field, with the marked total on the right.
    private func renderHeader(into s: Surface, rect: Rect, ctx: AppContext, theme: Theme) {
        var x: Int
        if search.showing {
            x = search.draw(into: s, x: rect.x, y: rect.y, theme: theme)
        } else {
            let crumb = ctx.index.breadcrumb(currentID)
            x = s.text(rect.x, rect.y, truncate(crumb, to: rect.w), Style(fg: theme.dim, bg: theme.appBg))
        }
        if !marked.isEmpty {
            var summary = "  \(Glyph.dot) " + tn("%d marked", marked.count)
            let known = marked.compactMap { sizes[$0] }
            if !known.isEmpty {
                summary += ", \(Fmt.bytes(known.reduce(0, +)))" + (known.count < marked.count ? "+" : "")
            }
            s.text(
                x,
                rect.y,
                truncate(summary, to: max(0, rect.maxX - x)),
                Style(fg: theme.accent, bg: theme.appBg, bold: true)
            )
        }
        s.hline(rect.x, rect.y + 1, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
    }

    /// One row per region: marker, name, and either its size or its child count.
    private func renderList(_ regions: [Region], into s: Surface, listRect: Rect, theme: Theme) {
        guard !regions.isEmpty else {
            let text = search.query.isEmpty ? t("no sub-regions here") : search.nothingMatches
            s.text(listRect.x, listRect.y, text, Style(fg: theme.faint, bg: theme.appBg))
            return
        }
        for index in list.window(count: regions.count, visible: listRect.h) {
            let region = regions[index]
            let y = listRect.y + index - list.offset
            var trailing: String?
            if let size = sizes[region] {
                trailing = Fmt.bytes(size)
            } else if region.hasChildren && region.pbfURL == nil {
                trailing = tn("%d region(s)", region.childIDs.count)
            }
            let isMarked = marked.contains(region.id)
            Widgets.row(
                s,
                rect: Rect(x: listRect.x, y: y, w: listRect.w - 1, h: 1),
                y: y,
                text: search.query.isEmpty ? region.name : "\(region.name)  \(Glyph.dot) \(region.id)",
                trailing: trailing,
                theme: theme,
                selected: index == list.selected,
                dimmed: region.pbfURL == nil,
                leading: isMarked ? "\(Glyph.check) " : (region.hasChildren ? "\(Glyph.arrowRight) " : "  "),
                leadingColor: isMarked ? theme.picked : nil
            )
        }
        Widgets.scrollHint(
            s,
            rect: listRect,
            offset: list.offset,
            count: regions.count,
            visible: listRect.h,
            theme: theme
        )
    }

    /// What is in the basket, and what it comes to.
    private func renderBasket(_ s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y
        s.vline(rect.x - 2, rect.y, rect.h, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))
        s.text(rect.x, y, t("building together"), Style(fg: theme.strong, bg: theme.appBg, bold: true))
        y += 2

        var total: Int64 = 0
        var complete = true
        for id in marked {
            guard y < rect.maxY - Self.basketFooterRows else {
                s.text(
                    rect.x,
                    y,
                    t("… and %d more", marked.count - (y - rect.y - 2)),
                    Style(fg: theme.faint, bg: theme.appBg)
                )
                y += 1
                break
            }
            let size = sizes[id]
            if let size { total += size } else { complete = false }
            s.text(
                rect.x,
                y,
                truncate(ctx.index.region(id)?.name ?? id, to: rect.w - 10),
                Style(fg: theme.text, bg: theme.appBg)
            )
            if let size {
                let text = Fmt.bytes(size)
                s.text(rect.maxX - text.count, y, text, Style(fg: theme.faint, bg: theme.appBg))
            }
            y += 1
        }

        y = max(y + 1, rect.maxY - Self.basketFooterRows)
        guard y < rect.maxY else { return }
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        y += 1
        s.text(rect.x, y, t("to download"), Style(fg: theme.faint, bg: theme.appBg), limit: Self.basketLabelColumn)
        s.text(
            rect.x + Self.basketLabelColumn,
            y,
            Fmt.bytes(total) + (complete ? "" : " +"),
            Style(fg: theme.text, bg: theme.appBg)
        )
        y += 1
        guard y < rect.maxY else { return }
        s.text(rect.x, y, t("⏎ builds one map · c clears"), Style(fg: theme.faint, bg: theme.appBg))
    }

    private func renderDetail(_ s: Surface, rect: Rect, region: Region, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y
        s.vline(rect.x - 2, rect.y, rect.h, Glyph.v, Style(fg: theme.rule, bg: theme.appBg))
        s.text(rect.x, y, truncate(region.name, to: rect.w), Style(fg: theme.strong, bg: theme.appBg, bold: true))
        y += 1
        s.text(rect.x, y, truncate(region.id, to: rect.w), Style(fg: theme.faint, bg: theme.appBg))
        y += 2

        func line(_ label: String, _ value: String, tone: Color? = nil) {
            guard y < rect.maxY else { return }
            s.text(rect.x, y, label, Style(fg: theme.faint, bg: theme.appBg), limit: Self.labelColumn)
            for (i, chunk) in wrapText(value, width: max(1, rect.w - Self.labelColumn)).enumerated() {
                guard y < rect.maxY else { return }
                s.text(rect.x + Self.labelColumn, y, chunk, Style(fg: tone ?? theme.text, bg: theme.appBg))
                y += 1
                if i >= Self.mostValueLines { break }
            }
        }

        if let size = sizes[region] {
            line(t("extract"), Fmt.bytes(size))
        } else if region.pbfURL != nil {
            line(
                t("extract"),
                sizes.isProbing(region) ? t("checking %@", String(Widgets.spinner(ctx.frame))) : "—",
                tone: theme.dim
            )
        } else {
            line(t("extract"), t("not downloadable"), tone: theme.warn)
        }
        if region.hasChildren {
            line(t("contains"), tn("%d sub-region(s)", region.childIDs.count))
        }
        if region.bbox.isValid {
            line(t("bounds"), region.bbox.display)
            line(t("elevation"), tn("%d × 1° tile(s)", region.demTileCount))
        }
        let cached = Paths.cachedExtract(forRegion: region.id)
        if FileTools.exists(cached) {
            line(t("cached"), Fmt.bytes(FileTools.size(of: cached)), tone: theme.ok)
        }
        let codePage = BuildRecipe.suggestedCodePage(for: region)
        if codePage != CodePage.westernEuropean {
            line(t("code page"), t("%d suggested", codePage), tone: theme.warn)
        }
    }
}

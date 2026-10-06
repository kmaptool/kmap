import Foundation

/// Drawing the type browser: the kind strip, the search line, and one row per code with
/// its day and night previews.
extension TypeBrowserScreen {
    private static let hexColumn = 8
    private static let foldRangeColumn = 14
    private static let nameColumn = 10...28
    /// Rows the list keeps whatever the detail pane wants.
    private static let leastListRows = 8
    private static let leastTagRoom = 4

    /// A line gets a length rather than a square, that being its shape.
    private var previewWidth: Int { kind == .line ? 10 : 2 }

    func renderOverlay(into s: Surface, rect: Rect, ctx: AppContext) {
        asking?.render(into: s, rect: rect, theme: ctx.theme)
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let folding = self.folding
        let shown = folding.rows
        drawHeader(s, rect: rect, theme: theme, shown: shown.count)

        let pane = TypeDetailPane(document: document, kind: kind)
        let detailHeight =
            showingDetail
            ? pane.rows(for: shown[safe: list.selected], within: rect, leastListRows: Self.leastListRows) : 0
        let listTop = rect.y + 3
        let listHeight = max(1, rect.maxY - listTop - detailHeight - 1)

        guard !shown.isEmpty else {
            s.text(
                rect.x,
                listTop,
                search.query.isEmpty
                    ? t("nothing here — the rule set has not been unpacked yet") : search.nothingMatches,
                Style(fg: theme.faint, bg: theme.appBg)
            )
            return
        }

        // A column short of the edge: the scroll hint takes the last one.
        let rowRect = Rect(x: rect.x, y: rect.y, w: rect.w - 1, h: rect.h)
        for index in list.window(count: shown.count, visible: listHeight) {
            let row = shown[index]
            draw(
                row,
                into: s,
                rect: rowRect,
                y: listTop + index - list.offset,
                theme: theme,
                selected: index == list.selected,
                fold: folding.spans[row.code]
            )
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
            offset: list.offset,
            count: shown.count,
            visible: listHeight,
            theme: theme
        )
        // The notice on the last row, the preview above it, so neither covers the other.
        defer { notice.draw(into: s, rect: rect, theme: theme) }
        guard showingDetail, let row = shown[safe: list.selected] else { return }
        pane.draw(
            row,
            into: s,
            rect: Rect(
                x: rect.x,
                y: listTop + listHeight + 1,
                w: rect.w,
                h: max(0, rect.maxY - listTop - listHeight - 2)
            ),
            theme: theme
        )
    }

    /// The three kinds as a strip: one number means different things in each table.
    private func drawHeader(_ s: Surface, rect: Rect, theme: Theme, shown: Int) {
        var x = rect.x
        for candidate in MapElementKind.allCases {
            let selected = candidate == kind
            let style =
                selected
                ? Style(fg: theme.selectionFg, bg: theme.raisedBg, bold: true) : Style(fg: theme.faint, bg: theme.appBg)
            x = s.text(x, rect.y, " \(candidate.plural) ", style)
            x += 1
        }

        let coverage = document.coverage(kind)
        let summary =
            document.isReadable
            ? t("%d styled", coverage.both) + " · " + t("%d not", coverage.unstyled.count)
                + (coverage.deliberate.isEmpty ? "" : " · " + t("%d by choice", coverage.deliberate.count))
                + " · " + t("%d unused", coverage.unused.count)
            : t("TYP not readable")
        s.textRight(rect.maxX, rect.y, summary, Style(fg: theme.dim, bg: theme.appBg))

        search.draw(into: s, x: rect.x, y: rect.y + 1, theme: theme)
        s.textRight(rect.maxX, rect.y + 1, t("%d of %d", shown, rows.count), Style(fg: theme.faint, bg: theme.appBg))
        s.hline(rect.x, rect.y + 2, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
    }

    /// One entry: the day and night drawings, the code, the name, and what the rules
    /// put on it. A fold is one line saying what it stands for.
    private func draw(
        _ row: StyleTypeRow,
        into s: Surface,
        rect: Rect,
        y: Int,
        theme: Theme,
        selected: Bool,
        fold: TypeRowFolding.Span?
    ) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        var x = s.text(rect.x, y, selected ? "\(Glyph.arrowRight) " : "  ", Style(fg: theme.accent, bg: bg))

        if let fold {
            x += previewWidth * 2 + 2
            let range = "\(row.hex)–\(TypeMeaning.hex(fold.last))"
            x = s.text(
                x,
                y,
                range.padding(toLength: Self.foldRangeColumn, withPad: " ", startingAt: 0),
                Style(fg: theme.faint, bg: bg)
            )
            s.text(x, y, tn("%d free code(s) — ⏎ unfolds them", fold.count), Style(fg: theme.faint, bg: bg))
            return
        }

        // A night the file says nothing about stays blank: silence is not a repeat.
        if row.isStyled {
            drawPreview(row, night: false, into: s, x: x, y: y, theme: theme, background: bg)
            drawPreview(row, night: true, into: s, x: x + previewWidth + 1, y: y, theme: theme, background: bg)
        }
        x += previewWidth * 2 + 2
        x = s.text(
            x,
            y,
            row.hex.padding(toLength: Self.hexColumn, withPad: " ", startingAt: 0),
            Style(fg: row.isStyled ? theme.text : theme.faint, bg: bg)
        )

        let nameWidth = min(Self.nameColumn.upperBound, max(Self.nameColumn.lowerBound, rect.w / 3))
        x = s.text(
            x,
            y,
            truncate(row.name(preferringRussian: russian), to: nameWidth).padding(
                toLength: nameWidth,
                withPad: " ",
                startingAt: 0
            ),
            Style(fg: selected ? theme.selectionFg : theme.text, bg: bg, bold: selected)
        )
        x += 1

        let (note, noteColour) = state(of: row, theme: theme)
        let noteWidth = note.isEmpty ? 0 : note.count + 2
        let tagRoom = max(0, rect.maxX - x - noteWidth)
        if tagRoom > Self.leastTagRoom {
            s.text(
                x,
                y,
                truncate(row.tagColumn(preferringRussian: russian), to: tagRoom),
                Style(fg: theme.faint, bg: bg)
            )
        }
        if !note.isEmpty {
            s.textRight(rect.maxX, y, note, Style(fg: noteColour, bg: bg))
        }
    }

    /// The type as the device draws it, scaled to the row's room and drawn in the top
    /// half so adjacent rows do not run into one column of colour.
    private func drawPreview(
        _ row: StyleTypeRow,
        night: Bool,
        into s: Surface,
        x: Int,
        y: Int,
        theme: Theme,
        background: Color
    ) {
        guard previewWidth > 0 else { return }
        Widgets.halfRow(
            s,
            x: x,
            y: y,
            colours: previewColours(row, night: night, width: previewWidth, on: background),
            background: background
        )
    }

    /// One colour per cell, nil where nothing is drawn.
    private func previewColours(_ row: StyleTypeRow, night: Bool, width: Int, on background: Color) -> [Color?] {
        guard let section = row.section else { return [] }
        if let picture = night ? section.nightPicture : section.picture, !picture.isBlank {
            return Widgets.colourRow(picture, width: width, on: background)
        }
        // No picture on this side of the day: the colours, and none for a point.
        guard kind != .point else { return [] }
        let slots = night ? section.colourSlots.night : section.colourSlots.day
        guard let fill = slots.first?.colour.flatMap(Color.hex) else { return [] }
        return Array(repeating: fill, count: width)
    }

    /// What is worth saying about the code at a glance: the only coloured part of the row.
    private func state(of row: StyleTypeRow, theme: Theme) -> (String, Color) {
        if !row.isStyled && !row.isEmitted { return (t("free"), theme.faint) }
        if !row.isStyled {
            return document.isDeliberatelyUnstyled(kind, row.code)
                ? (t("device default, on purpose"), theme.faint)
                : (t("device default"), theme.warn)
        }
        if !row.isEmitted { return (t("never emitted"), theme.faint) }
        if row.meaningCount > 1 { return (tn("%d meanings", row.meaningCount), theme.dim) }
        return ("", theme.dim)
    }
}

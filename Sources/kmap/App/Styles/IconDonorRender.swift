import Foundation

/// Drawing the donor screens: the sources, one donor's types, a picture from a file, and
/// in each case what is there now beside what it would become.
extension IconDonorScreen {
    private static let compareRows = 6...14
    private static let leastRightColumn = 24
    private static let columnGap = 6

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        switch stage {
        case .style: renderStyles(s, rect: rect, theme: ctx.theme)
        case .type: renderTypes(s, rect: rect, theme: ctx.theme)
        case .file: renderFile(s, rect: rect, theme: ctx.theme)
        }
    }

    private func renderFile(_ s: Surface, rect: Rect, theme: Theme) {
        let faint = Style(fg: theme.faint, bg: theme.appBg)
        var y = s.paragraph(
            t(
                "A picture is read at %@ — the size of the drawing "
                    + "it would replace. PNG, JPEG, TIFF, GIF and BMP work, and SVG "
                    + "where the system can draw it. `~` is expanded.",
                "\(wantedSize)×\(wantedSize)"
            ),
            x: rect.x,
            y: rect.y,
            width: rect.w,
            style: faint
        )
        y += 1
        s.text(rect.x, y, t("Path:"), Style(fg: theme.text, bg: theme.appBg))
        y += 1
        s.prompt("", draft: path, x: rect.x, y: y, labelStyle: faint, theme: theme)
        y += 2

        guard let loaded else {
            if let message, y < rect.maxY {
                s.text(rect.x, y, truncate(message, to: rect.w), Style(fg: theme.danger, bg: theme.appBg))
            }
            return
        }

        let rows = max(1, rect.maxY - y - 3)
        y = comparePictures(target?.picture, loaded.block, into: s, rect: rect, y: y, rows: rows, theme: theme)
        guard y < rect.maxY else { return }
        let rightColumn = pair(rect, current: target?.picture, rows: rows).rightColumn
        s.text(
            rightColumn,
            y,
            "\(loaded.block.width)×\(loaded.block.height), " + tn("%d colour(s)", loaded.paletteSize),
            faint
        )
        y += 1

        // What the import had to give up, before the drawing is accepted.
        for warning in loaded.warnings {
            guard y < rect.maxY else { return }
            y = s.paragraph(
                warning,
                x: rect.x,
                y: y,
                width: rect.w,
                style: Style(fg: theme.warn, bg: theme.appBg),
                maxY: rect.maxY
            )
        }
        if loaded.warnings.isEmpty, y < rect.maxY {
            s.text(
                rect.x,
                y,
                t("read at its own size, nothing scaled and no colour lost"),
                Style(fg: theme.ok, bg: theme.appBg)
            )
        }
    }

    private func renderStyles(_ s: Surface, rect: Rect, theme: Theme) {
        var y = s.paragraph(
            t(
                "A drawing comes from a picture on disk, or from another "
                    + "style whose TYP is readable — a compiled one has nothing to "
                    + "offer until it is imported, which decompiles it."
            ),
            x: rect.x,
            y: rect.y,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1
        list.clamp(count: sourceRowCount, visible: max(1, rect.maxY - y - 1))

        Widgets.row(
            s,
            rect: Rect(x: rect.x, y: y, w: rect.w, h: 1),
            y: y,
            text: t("A picture on disk — PNG, JPEG, SVG…"),
            trailing: t("read at %d px", wantedSize),
            theme: theme,
            selected: list.selected == 0,
            leading: "＋ ",
            leadingColor: theme.accent
        )
        y += 1

        if styles.isEmpty, y < rect.maxY {
            s.text(
                rect.x,
                y,
                "  " + t("no other readable style — import one to borrow from it"),
                Style(fg: theme.faint, bg: theme.appBg)
            )
            y += 1
        }
        for (index, style) in styles.enumerated() {
            guard y < rect.maxY - 1 else { break }
            Widgets.row(
                s,
                rect: Rect(x: rect.x, y: y, w: rect.w, h: 1),
                y: y,
                text: style.name,
                trailing: t("family %d", style.familyID),
                theme: theme,
                selected: index + 1 == list.selected
            )
            y += 1
        }
        if let message, y < rect.maxY {
            s.text(rect.x, rect.maxY - 1, message, Style(fg: theme.warn, bg: theme.appBg))
        }
    }

    private func renderTypes(_ s: Surface, rect: Rect, theme: Theme) {
        let shown = visibleSections
        var y = filter.drawHeader(
            into: s,
            trailing: t("%d of %d", shown.count, donorSections.count),
            trailingStyle: Style(fg: theme.faint, bg: theme.appBg),
            rect: rect,
            y: rect.y,
            theme: theme
        )

        guard !shown.isEmpty else {
            s.text(rect.x, y, message ?? filter.nothingMatches, Style(fg: theme.faint, bg: theme.appBg))
            return
        }

        // The comparison takes the bottom half.
        let compareHeight = min(Self.compareRows.upperBound, max(Self.compareRows.lowerBound, rect.h / 2))
        let listHeight = max(1, rect.maxY - y - compareHeight - 1)
        let listTop = y
        for index in filter.list.window(count: shown.count, visible: listHeight) {
            let section = shown[index]
            Widgets.row(
                s,
                rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1),
                y: y,
                text: "\(section.hex)  \(section.englishLabel ?? section.russianLabel ?? "")",
                trailing: section.picture.map { "\($0.width)×\($0.height)" } ?? "",
                theme: theme,
                selected: index == filter.list.selected
            )
            y += 1
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
            offset: filter.list.offset,
            count: shown.count,
            visible: listHeight,
            theme: theme
        )

        guard let section = shown[safe: filter.list.selected] else { return }
        compare(
            section,
            into: s,
            rect: Rect(x: rect.x, y: listTop + listHeight + 1, w: rect.w, h: rect.maxY - listTop - listHeight - 1),
            theme: theme
        )
    }

    /// Room for two drawings side by side, both reduced by the same rule.
    private func pair(_ rect: Rect, current: XpmBlock?, rows: Int) -> (columns: Int, rightColumn: Int) {
        let columns = max(2, (rect.w - Self.columnGap) / 2)
        let width = current.map { Widgets.pictureFit($0, maxColumns: columns, maxRows: rows).columns } ?? 0
        return (columns, rect.x + max(Self.leastRightColumn, width + Self.columnGap))
    }

    /// "now" and "would become", the pictures under the captions. Returns the row after.
    private func comparePictures(
        _ current: XpmBlock?,
        _ incoming: XpmBlock?,
        into s: Surface,
        rect: Rect,
        y: Int,
        rows: Int,
        theme: Theme
    ) -> Int {
        let room = pair(rect, current: current, rows: rows)
        s.text(rect.x, y, t("now"), Style(fg: theme.dim, bg: theme.appBg))
        s.text(room.rightColumn, y, t("would become"), Style(fg: theme.dim, bg: theme.appBg))
        var used = 1
        if let current {
            used = Widgets.picture(
                s,
                x: rect.x,
                y: y + 1,
                current,
                background: theme.appBg,
                maxColumns: room.columns,
                maxRows: rows
            )
        } else {
            s.text(rect.x, y + 1, t("nothing"), Style(fg: theme.faint, bg: theme.appBg))
        }
        if let incoming {
            used = max(
                used,
                Widgets.picture(
                    s,
                    x: room.rightColumn,
                    y: y + 1,
                    incoming,
                    background: theme.appBg,
                    maxColumns: room.columns,
                    maxRows: rows
                )
            )
        }
        return y + 1 + used + 1
    }

    private func compare(_ donorSection: TypSection, into s: Surface, rect: Rect, theme: Theme) {
        guard rect.h > 2 else { return }
        s.hline(rect.x, rect.y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        let current = target?.picture
        let incoming = donorSection.picture
        let rows = max(1, rect.maxY - rect.y - 3)
        var y = comparePictures(current, incoming, into: s, rect: rect, y: rect.y + 1, rows: rows, theme: theme)
        guard y < rect.maxY else { return }

        func facts(_ block: XpmBlock?) -> String {
            guard let block else { return t("no drawing") }
            return "\(block.width)×\(block.height), " + tn("%d colour(s)", block.declaredColours)
        }

        s.text(rect.x, y, facts(current), Style(fg: theme.faint, bg: theme.appBg))
        s.text(
            pair(rect, current: current, rows: rows).rightColumn,
            y,
            facts(incoming),
            Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1

        // Reported, not acted on: nothing here scales a drawing.
        if let current, let incoming, current.width != incoming.width || current.height != incoming.height,
            y < rect.maxY
        {
            s.text(
                rect.x,
                y,
                t("different size — it will be used as it is, not scaled to fit"),
                Style(fg: theme.warn, bg: theme.appBg)
            )
        }
    }
}

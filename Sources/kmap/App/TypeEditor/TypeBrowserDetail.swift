import Foundation

/// The pane under the type list: the drawing at full size beside its facts, or the
/// colours, and every rule that reaches the code.
struct TypeDetailPane {
    let document: StyleDocument
    let kind: MapElementKind

    private static let leastPaneRows = 4
    private static let leastFactsWidth = 12
    private static let sampleWidth = 32
    private static let sampleRows = 8

    /// How many rows the pane needs for `row`, measured as it will be drawn: a picture
    /// too wide for the pane is reduced and so takes fewer rows.
    func rows(for row: StyleTypeRow?, within rect: Rect, leastListRows: Int) -> Int {
        // The rule line above the pane, and the code with its labels under it.
        var wanted = 2
        if let section = row?.section, let picture = section.picture, !section.patternIsBlank {
            let columns = max(2, section.nightPicture == nil ? rect.w / 2 : rect.w / 3)
            wanted += Widgets.pictureFit(picture, maxColumns: columns).rows + 1
        } else {
            // A line of colours, and for a line the sample under it.
            wanted += row?.section?.kind == .line ? 4 : 2
        }
        wanted += max(1, row?.meaning?.conditions.count ?? 1)
        return max(Self.leastPaneRows, min(wanted, rect.h - 3 - leastListRows))
    }

    func draw(_ row: StyleTypeRow, into s: Surface, rect: Rect, theme: Theme) {
        guard rect.h > 2 else { return }
        s.hline(rect.x, rect.y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))

        var y = rect.y + 1
        var x = s.text(rect.x, y, row.hex, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        if let section = row.section {
            for label in [section.englishLabel, section.russianLabel].compactMap({ $0 }) where !label.isEmpty {
                x = s.text(x + 1, y, "· ", Style(fg: theme.faint, bg: theme.appBg))
                x = s.text(x, y, label, Style(fg: theme.text, bg: theme.appBg))
            }
        }
        y += 1

        if let picture = row.section?.picture, row.section?.patternIsBlank == false, rect.maxY - y > 2 {
            y = drawPictures(picture, night: row.section?.nightPicture, into: s, rect: rect, y: y, theme: theme)
        } else {
            y = drawColours(row, into: s, rect: rect, y: y, theme: theme)
        }
        guard y < rect.maxY else { return }

        if row.tags.isEmpty && row.meaning == nil {
            s.text(rect.x, y, t("no rule in this style emits this code"), Style(fg: theme.warn, bg: theme.appBg))
            return
        }
        for condition in row.meaning?.conditions ?? [] {
            guard y < rect.maxY else { return }
            let x = s.text(rect.x, y, "· ", Style(fg: theme.faint, bg: theme.appBg))
            s.text(x, y, truncate(condition, to: max(0, rect.maxX - x)), Style(fg: theme.dim, bg: theme.appBg))
            y += 1
        }
    }

    /// The drawing as big as the pane holds it, the night one beside it where there is
    /// one, then its facts. Returns the next row.
    private func drawPictures(
        _ picture: XpmBlock,
        night: XpmBlock?,
        into s: Surface,
        rect: Rect,
        y: Int,
        theme: Theme
    ) -> Int {
        let rows = max(1, rect.maxY - y - 1)
        let columns = max(2, night == nil ? rect.w / 2 : rect.w / 3)
        let fit = Widgets.pictureFit(picture, maxColumns: columns, maxRows: rows)
        Widgets.picture(s, x: rect.x, y: y, picture, background: theme.appBg, maxColumns: columns, maxRows: rows)
        var right = rect.x + fit.columns + 2
        if let night, !night.isBlank {
            Widgets.picture(s, x: right, y: y, night, background: theme.appBg, maxColumns: columns, maxRows: rows)
            s.text(right, y + fit.rows, t("night"), Style(fg: theme.faint, bg: theme.appBg))
            s.text(rect.x, y + fit.rows, t("day"), Style(fg: theme.faint, bg: theme.appBg))
            right += Widgets.pictureFit(night, maxColumns: columns, maxRows: rows).columns + 2
        }
        drawPictureFacts(
            picture,
            fit: fit,
            into: s,
            rect: Rect(x: right, y: y, w: max(0, rect.maxX - right), h: max(0, rect.maxY - y)),
            theme: theme
        )
        return y + max(fit.rows + 1, 3)
    }

    /// Size, palette depth and the colours, hex beside every swatch.
    private func drawPictureFacts(
        _ picture: XpmBlock,
        fit: Widgets.PictureFit,
        into s: Surface,
        rect: Rect,
        theme: Theme
    ) {
        guard rect.w > Self.leastFactsWidth, rect.h > 0 else { return }
        var y = rect.y
        // The scale is stated only when reduced: single-pixel details are then off screen.
        let scale = fit.isReduced ? "  ·  " + t("shown at 1:%d", fit.scale) : ""
        s.text(
            rect.x,
            y,
            "\(picture.width)×\(picture.height)  " + tn("%d colour(s)", picture.declaredColours) + scale,
            Style(fg: theme.dim, bg: theme.appBg)
        )
        y += 1
        for entry in picture.palette.prefix(max(0, rect.h - 1)) {
            guard y < rect.maxY else { return }
            let x = Widgets.swatch(s, x: rect.x, y: y, colour: entry.colour, width: 2, theme: theme)
            s.text(
                x + 1,
                y,
                entry.colour ?? t("none"),
                Style(fg: entry.colour == nil ? theme.faint : theme.text, bg: theme.appBg)
            )
            y += 1
        }
    }

    /// Colours for a line or polygon, day and night, and for a line its sample at the
    /// thickness the file gives it.
    private func drawColours(_ row: StyleTypeRow, into s: Surface, rect: Rect, y: Int, theme: Theme) -> Int {
        guard let section = row.section else {
            s.text(
                rect.x,
                y,
                t("not styled by this TYP — the device draws its own"),
                Style(fg: theme.warn, bg: theme.appBg)
            )
            return y + 1
        }
        let colours = section.colours
        guard !colours.isEmpty else { return y }

        var x = rect.x
        for colour in colours {
            guard x < rect.maxX - 10 else { break }
            x = Widgets.swatch(s, x: x, y: y, colour: colour, width: 2, theme: theme)
            x = s.text(x + 1, y, colour ?? t("none"), Style(fg: theme.text, bg: theme.appBg))
            x += 2
        }
        if let width = section.lineWidth {
            let border = section.borderWidth.map { ", " + t("border %d", $0) } ?? ""
            s.textRight(rect.maxX, y, t("width %d", width) + border, Style(fg: theme.dim, bg: theme.appBg))
        }

        guard kind == .line, rect.maxY - y > 2 else { return y + 2 }
        let day = section.colourSlots.day
        let used = Widgets.lineSample(
            s,
            rect: Rect(
                x: rect.x,
                y: y + 1,
                w: min(rect.w, Self.sampleWidth),
                h: min(rect.maxY - y - 1, Self.sampleRows)
            ),
            fill: day.first?.colour,
            casing: day.dropFirst().first?.colour,
            width: section.lineWidth,
            border: section.borderWidth,
            background: theme.appBg
        )
        return y + used + 2
    }
}

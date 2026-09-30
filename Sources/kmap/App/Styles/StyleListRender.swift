import Foundation

/// Drawing the styles list and the note about the selected one.
extension StyleListScreen {
    /// Rows kept under the list for the summary and the last line.
    private static let summaryRows = 6

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let defaultID = ctx.settings.settings.defaultStyleID
        var y = s.paragraph(
            t(
                "A style is two things: the rules that turn OSM tags into Garmin types, "
                    + "and a TYP file that says how those types are drawn. kmap ships the "
                    + "rules; the look comes from your library."
            ),
            x: rect.x,
            y: rect.y,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1

        let shown = filtered
        if search.showing {
            search.draw(into: s, x: rect.x, y: y, theme: theme)
            s.textRight(rect.maxX, y, t("%d of %d", shown.count, styles.count), Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }

        let listHeight = max(1, rect.maxY - y - Self.summaryRows)
        list.clamp(count: shown.count, visible: listHeight)
        if shown.isEmpty {
            s.text(
                rect.x,
                y,
                styles.isEmpty ? t("no styles found") : search.nothingMatches,
                Style(fg: theme.faint, bg: theme.appBg)
            )
            drawFooterLine(s, rect: rect, theme: theme)
            asking?.render(into: s, rect: rect, theme: theme)
            return
        }

        let listTop = y
        for index in list.window(count: shown.count, visible: listHeight) {
            let style = shown[index]
            let isDefault = style.id == defaultID
            let inLibrary = libraryFile(of: style) != nil
            Widgets.row(
                s,
                rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1),
                y: y,
                text: style.name,
                trailing: isDefault ? t("default") : (inLibrary ? t("yours") : ""),
                theme: theme,
                selected: index == list.selected,
                leading: isDefault ? "\(Glyph.dot) " : "  "
            )
            y += 1
        }
        Widgets.scrollHint(
            s,
            rect: Rect(x: rect.x, y: listTop, w: rect.w, h: listHeight),
            offset: list.offset,
            count: shown.count,
            visible: listHeight,
            theme: theme
        )

        if let style = shown[safe: list.selected], y + 2 < rect.maxY {
            drawSelected(style, into: s, rect: rect, y: y + 1, theme: theme)
        }
        // Whatever the height: a question or a prompt takes the keys, so it must be seen.
        drawFooterLine(s, rect: rect, theme: theme)
        asking?.render(into: s, rect: rect, theme: theme)
    }

    /// The summary of the selected style under a rule, and where its file is.
    private func drawSelected(_ style: MapStyle, into s: Surface, rect: Rect, y: Int, theme: Theme) {
        s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
        let after = s.paragraph(
            t(style.summary),
            x: rect.x,
            y: y + 1,
            width: rect.w,
            style: Style(fg: theme.text, bg: theme.appBg),
            maxY: rect.maxY
        )
        switch style.origin {
        case .importedTYP(let url), .customDirectory(let url):
            if after < rect.maxY {
                s.text(rect.x, after, truncate(Paths.display(url), to: rect.w), Style(fg: theme.faint, bg: theme.appBg))
            }
        case .builtin: break
        }
    }

    private func drawFooterLine(_ s: Surface, rect: Rect, theme: Theme) {
        let y = rect.maxY - 1
        if let confirming {
            s.text(
                rect.x,
                y,
                t("delete %@? the file goes for good  (y/n)", confirming.name),
                Style(fg: theme.danger, bg: theme.appBg, bold: true)
            )
            return
        }
        if renaming {
            s.prompt(
                t("rename to") + ": ",
                draft: name.text,
                x: rect.x,
                y: y,
                labelStyle: Style(fg: theme.text, bg: theme.appBg),
                theme: theme
            )
            return
        }
        notice.draw(into: s, rect: rect, theme: theme)
    }
}

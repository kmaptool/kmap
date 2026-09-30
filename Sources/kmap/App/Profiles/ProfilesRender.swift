import Foundation

/// Drawing the profiles list, the summary of the selected one, and the last line.
extension ProfilesScreen {
    /// Rows kept under the list for the summary and the last line.
    private static let summaryRows = 8

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let currentID = ctx.settings.currentProfile.id
        var y = s.paragraph(
            t(
                "A profile is a saved set of build settings. Pick one on the New "
                    + "map screen and every field fills in from it. Anything changed after "
                    + "that applies to the current map only — the profile itself stays as "
                    + "it was."
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
            s.textRight(
                rect.maxX,
                y,
                t("%d of %d", shown.count, profiles.count),
                Style(fg: theme.faint, bg: theme.appBg)
            )
            y += 1
        }

        let listHeight = max(1, rect.maxY - y - Self.summaryRows)
        list.clamp(count: shown.count, visible: listHeight)
        if shown.isEmpty {
            s.text(rect.x, y, search.nothingMatches, Style(fg: theme.faint, bg: theme.appBg))
            // A name prompt or a notice must show even over an empty list.
            drawFooterLine(s, rect: rect, theme: theme)
            return
        }

        let listTop = y
        for index in list.window(count: shown.count, visible: listHeight) {
            let profile = shown[index]
            let isCurrent = profile.id == currentID
            Widgets.row(
                s,
                rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1),
                y: y,
                text: profile.name,
                trailing: isCurrent ? t("in use") : "",
                theme: theme,
                selected: index == list.selected,
                leading: isCurrent ? "\(Glyph.dot) " : "  "
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

        if let profile = shown[safe: list.selected], y + 2 < rect.maxY {
            y += 1
            s.hline(rect.x, y, rect.w, Glyph.h, Style(fg: theme.rule, bg: theme.appBg))
            y += 1
            for line in ProfilesScreen.summary(of: profile.choices) {
                guard y < rect.maxY - 1 else { break }
                s.text(rect.x, y, truncate(line, to: rect.w), Style(fg: theme.text, bg: theme.appBg))
                y += 1
            }
        }
        // Whatever the height: the prompts take keys, so they must be seen.
        drawFooterLine(s, rect: rect, theme: theme)
    }

    /// A few lines describing a profile without opening it.
    static func summary(of choices: BuildChoices) -> [String] {
        var parts: [String] = []
        parts.append(choices.contours ? t("contours every %d m", choices.contourInterval) : t("no contours"))
        parts.append(choices.demLayer ? t("with the DEM layer") : t("no DEM"))
        parts.append(LevelsProfile.all.first { $0.id == choices.levelsID }?.name ?? "")
        let labels = LabelLanguage.all.first { $0.id == choices.labelLanguageID } ?? .local
        parts.append(t("labels: %@", labels.name))
        parts.append(choices.codePage == 0 ? t("code page by region") : t("code page %d", choices.codePage))

        var lines = [parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")]
        lines.append(t("style: %@", choices.styleID))
        let format = OutputFormat(rawValue: choices.format) ?? .img
        if format.writesCardFiles {
            lines.append(SplitMode(settingsID: choices.splitMode, count: choices.parts).label)
        }
        if format != .img { lines.append(format.label) }
        if !choices.hiddenFeatures.isEmpty {
            lines.append(tn("%d feature(s) left off the map", choices.hiddenFeatures.count))
        }
        return lines
    }

    private func drawFooterLine(_ s: Surface, rect: Rect, theme: Theme) {
        let y = rect.maxY - 1
        if let confirming {
            s.text(
                rect.x,
                y,
                t("delete %@?  (y/n)", confirming.name),
                Style(fg: theme.danger, bg: theme.appBg, bold: true)
            )
            return
        }
        if let naming {
            let label: String
            switch naming {
            case .fresh: label = t("name it")
            case .copy: label = t("copy as")
            case .rename: label = t("rename to")
            }
            s.prompt(
                label + ": ",
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

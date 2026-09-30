import Foundation

/// Drawing the import screen: the path entry, or the TYPs found on the drives.
extension ImportTypScreen {
    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = s.paragraph(
            t(
                "kmap works with a copy in its own folder and does not touch the "
                    + "original again. The style keeps working even if the source file "
                    + "was on a removable drive."
            ),
            x: rect.x,
            y: rect.y,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
        y += 1

        switch mode {
        case .path: drawPathEntry(into: s, rect: rect, y: &y, theme: theme)
        case .found: drawFound(into: s, rect: rect, y: &y, theme: theme, frame: ctx.frame)
        }

        if y < rect.maxY { notice.draw(into: s, rect: rect, theme: theme) }
        asking?.render(into: s, rect: rect, theme: theme)
        warning?.render(into: s, rect: rect, theme: theme)
        offering?.render(into: s, rect: rect, theme: theme)
    }

    private func drawPathEntry(into s: Surface, rect: Rect, y: inout Int, theme: Theme) {
        s.text(rect.x, y, t("Path to a .typ or a Garmin .img:"), Style(fg: theme.text, bg: theme.appBg))
        y += 1
        s.prompt("", draft: path, x: rect.x, y: y, labelStyle: Style(fg: theme.text, bg: theme.appBg), theme: theme)
        y += 2
        y = s.paragraph(
            t("A .img has its TYP lifted out here — there is no need to unpack it first. `~` is expanded."),
            x: rect.x,
            y: y,
            width: rect.w,
            style: Style(fg: theme.faint, bg: theme.appBg)
        )
    }

    private func drawFound(into s: Surface, rect: Rect, y: inout Int, theme: Theme, frame: Int) {
        let shown = visible
        let trailing =
            scanning
            ? t("%@ searching your drives…", String(Widgets.spinner(frame)))
            : t("%d of %d", shown.count, candidates.count)
        y = filter.drawHeader(
            into: s,
            trailing: trailing,
            trailingStyle: Style(fg: scanning ? theme.dim : theme.faint, bg: theme.appBg),
            rect: rect,
            y: y,
            theme: theme
        )

        guard !shown.isEmpty else {
            let text =
                scanning
                ? t("looking…")
                : (candidates.isEmpty ? t("nothing found — press ⇥ and type a path instead") : filter.nothingMatches)
            s.text(rect.x, y, text, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
            return
        }

        let listHeight = max(1, rect.maxY - y - 2)
        let listTop = y
        for index in filter.list.window(count: shown.count, visible: listHeight) {
            draw(shown[index], into: s, rect: rect, y: y, theme: theme, selected: index == filter.list.selected)
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
    }

    /// Only an exact fingerprint match is dimmed: several TYPs share one family id.
    private func draw(_ candidate: TypCandidate, into s: Surface, rect: Rect, y: Int, theme: Theme, selected: Bool) {
        let trailing: String
        var alreadyHeld = false
        switch TypLibrary.holding(of: candidate, in: held) {
        case .exact:
            trailing = t("in library")
            alreadyHeld = true
        case .family: trailing = t("family %d already here", candidate.familyID)
        case .none: trailing = Fmt.bytes(candidate.size)
        }
        Widgets.row(
            s,
            rect: Rect(x: rect.x, y: y, w: rect.w - 1, h: 1),
            y: y,
            text: candidate.name + "  ·  " + t("family %d", candidate.familyID) + "  ·  " + candidate.location,
            trailing: trailing,
            theme: theme,
            selected: selected,
            dimmed: alreadyHeld,
            leading: candidate.isEmbedded ? "img " : "typ ",
            leadingColor: candidate.isEmbedded ? theme.accentDim : theme.faint
        )
    }
}

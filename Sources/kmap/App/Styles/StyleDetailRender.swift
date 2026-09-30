import Foundation

/// Drawing one style: its identity, its coverage, and the rows into its parts.
extension StyleDetailScreen {
    private static let kindColumn = 12
    private static let summaryLines = 2
    private static let mostMissingListed = 8

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = drawIdentity(into: s, rect: rect, y: rect.y, theme: theme)
        y += 1

        guard document.isReadable else {
            y = drawUnreadable(into: s, rect: rect, y: y, theme: theme)
            drawMessage(into: s, rect: rect, y: y, theme: theme)
            return
        }

        if !document.isEditable {
            y = s.paragraph(
                readOnlyReason,
                x: rect.x,
                y: y,
                width: rect.w,
                style: Style(fg: theme.warn, bg: theme.appBg),
                maxY: rect.maxY
            )
            y += 1
        }
        y = drawCoverage(into: s, rect: rect, y: y, theme: theme)
        y += 1

        s.sectionRule(
            rect,
            y,
            t("edit"),
            labelStyle: Style(fg: theme.dim, bg: theme.appBg),
            ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
        )
        y += 1
        for (index, row) in rows.enumerated() {
            guard y < rect.maxY - 1 else { break }
            draw(row, into: s, rect: rect, y: y, theme: theme, selected: index == list.selected)
            y += 1
        }
        drawMessage(into: s, rect: rect, y: y + 1, theme: theme)
    }

    private func drawIdentity(into s: Surface, rect: Rect, y: Int, theme: Theme) -> Int {
        var y = y
        let style = document.style
        let x = s.text(rect.x, y, style.name, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        if isDefault {
            s.text(x + 2, y, t("default"), Style(fg: theme.ok, bg: theme.appBg))
        }
        y += 1
        for chunk in wrapText(t(style.summary), width: rect.w).prefix(Self.summaryLines) {
            s.text(rect.x, y, chunk, Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }

        // mkgmap rewrites the family id to the build's; a mismatch makes the device ignore the TYP.
        var facts = [t("family %d", document.familyID), t("product %d", document.productID)]
        if let codePage = document.codePage {
            facts.append(t("code page") + " \(codePage)")
        }
        facts.append(kindLabel)
        s.text(rect.x, y, facts.joined(separator: "  ·  "), Style(fg: theme.dim, bg: theme.appBg))
        y += 1

        if let url = document.sourceURL {
            s.text(rect.x, y, truncate(Paths.display(url), to: rect.w), Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        if let img = recoverableMap {
            s.text(
                rect.x,
                y,
                truncate(t("from map %@", img.lastPathComponent), to: rect.w),
                Style(fg: theme.faint, bg: theme.appBg)
            )
            y += 1
        }
        return y
    }

    private var kindLabel: String {
        switch document.availability {
        case .source: return document.isEditable ? t("editable source") : t("read-only source")
        case .binary: return t("compiled TYP")
        case .none: return t("no TYP")
        }
    }

    private var readOnlyReason: String {
        document.style.origin == .builtin || document.sourceURL == nil
            ? t(
                "This is kmap's own TYP, and its working copy is rewritten from the shipped "
                    + "one whenever a build finds the two differ — an edit here would be undone "
                    + "without a word. Press ^F for an editable copy in your TYP library."
            )
            : t(
                "This file is outside kmap's TYP library, which is the only place kmap writes "
                    + "a TYP. Press ^F for an editable copy."
            )
    }

    private func drawUnreadable(into s: Surface, rect: Rect, y: Int, theme: Theme) -> Int {
        let explanation: String
        switch document.availability {
        case .binary:
            explanation = t(
                "This TYP is compiled. Its identity reads fine, but its sections "
                    + "cannot be opened yet: mkgmap compiles source into a TYP and offers no way "
                    + "back, so decoding one is work kmap has to do itself. Until then the file "
                    + "can still be built with — it is simply not editable here."
            )
        case .none:
            explanation = t(
                "This style ships no TYP. The device draws every type its own way, "
                    + "so there is nothing here to edit."
            )
        case .source:
            explanation = ""
        }
        return s.paragraph(
            explanation,
            x: rect.x,
            y: y,
            width: rect.w,
            style: Style(fg: theme.dim, bg: theme.appBg),
            maxY: rect.maxY
        )
    }

    /// Per kind: the codes the rule set emits against the sections the TYP styles.
    private func drawCoverage(into s: Surface, rect: Rect, y: Int, theme: Theme) -> Int {
        var y = y
        s.sectionRule(
            rect,
            y,
            t("coverage"),
            labelStyle: Style(fg: theme.dim, bg: theme.appBg),
            ruleStyle: Style(fg: theme.rule, bg: theme.appBg)
        )
        y += 1

        guard document.rules != nil else {
            s.text(
                rect.x,
                y,
                t("the rule set has not been unpacked yet — run a build once"),
                Style(fg: theme.warn, bg: theme.appBg)
            )
            return y + 1
        }

        for kind in MapElementKind.allCases {
            guard y < rect.maxY else { break }
            drawCoverage(of: kind, into: s, rect: rect, y: y, theme: theme)
            y += 1
        }

        // A polygon absent from [_drawOrder] is never drawn.
        let missing = document.polygonsNeverDrawn
        if !missing.isEmpty, y < rect.maxY {
            let list = missing.prefix(Self.mostMissingListed).map(TypeMeaning.hex).joined(separator: " ")
            s.text(
                rect.x,
                y,
                t("polygons missing from the draw order, never drawn: %@", list),
                Style(fg: theme.danger, bg: theme.appBg)
            )
            y += 1
        }
        return y
    }

    private func drawCoverage(of kind: MapElementKind, into s: Surface, rect: Rect, y: Int, theme: Theme) {
        let coverage = document.coverage(kind)
        var x = s.text(
            rect.x,
            y,
            kind.plural.padding(toLength: Self.kindColumn, withPad: " ", startingAt: 0),
            Style(fg: theme.text, bg: theme.appBg)
        )
        x = s.text(x, y, t("%d of %d styled", coverage.both, coverage.emitted), Style(fg: theme.text, bg: theme.appBg))
        if !coverage.unstyled.isEmpty {
            x = s.text(
                x + 2,
                y,
                tn("%d fall back to the device", coverage.unstyled.count),
                Style(fg: theme.warn, bg: theme.appBg)
            )
        }
        if !coverage.deliberate.isEmpty {
            x = s.text(
                x + 2,
                y,
                tn("%d left to it on purpose", coverage.deliberate.count),
                Style(fg: theme.faint, bg: theme.appBg)
            )
        }
        if !coverage.unused.isEmpty {
            s.textRight(
                rect.maxX,
                y,
                tn("%d styled but never emitted", coverage.unused.count),
                Style(fg: theme.faint, bg: theme.appBg)
            )
        }
    }

    private func draw(_ row: Row, into s: Surface, rect: Rect, y: Int, theme: Theme, selected: Bool) {
        let text: String
        let trailing: String
        switch row {
        case .kind(let kind):
            text = label(for: kind)
            trailing = tn("%d section(s)", document.coverage(kind).styled)
        case .drawOrder:
            text = t("Draw order — which polygon is painted over which")
            trailing = tn("%d entries", document.source?.drawOrder.count ?? 0)
        }
        Widgets.row(
            s,
            rect: Rect(x: rect.x, y: y, w: rect.w, h: 1),
            y: y,
            text: text,
            trailing: trailing,
            theme: theme,
            selected: selected
        )
    }

    private func label(for kind: MapElementKind) -> String {
        switch kind {
        case .point: return t("Points — the POI icons")
        case .line: return t("Lines — roads, paths, contours, streams")
        case .polygon: return t("Polygons — landcover fills and hatches")
        }
    }

    private func drawMessage(into s: Surface, rect: Rect, y: Int, theme: Theme) {
        guard let message, y < rect.maxY else { return }
        s.text(rect.x, y, message, Style(fg: theme.ok, bg: theme.appBg))
    }
}

import Foundation

/// The bars above and below every screen: the title with the clock and the machine load,
/// and the footer keys with the version.
extension App {
    /// Memory use at which the header figure turns to the warning colour.
    static let memoryWarningFraction = 0.9
    /// Cells between a footer key and its label, and between one hint and the next.
    static let hintGap = 1
    static let hintSpacing = 3

    func drawHeader(_ screen: Screen, width w: Int) {
        let theme = ctx.theme
        let bar = Style(fg: theme.headerFg, bg: theme.headerBg)
        surface.fill(Rect(x: 0, y: 0, w: w, h: 1), bar)

        var x = surface.text(App.contentInset, 0, "kmap", bar.with(fg: theme.accent, bold: true))
        x = surface.text(x + 1, 0, String(Glyph.dot), bar.with(fg: theme.faint))
        // Stops short of the clock: a long map name ends in an ellipsis, not under it.
        let clock = Fmt.clock()
        let title = truncate(screen.title, to: max(0, w - 4 - clock.count - (x + 1)))
        surface.text(x + 1, 0, title, bar.with(fg: theme.headerFg))

        let load = ctx.load
        let pieces = Widgets.headerRight(
            width: w,
            titleEnds: x + title.count,
            clock: clock,
            load: load
        )
        for (i, piece) in pieces.enumerated() {
            let style: Style
            if i == 0 {
                style = bar.with(fg: theme.dim)
            } else if piece.text.hasSuffix(t("GB")), load.memoryFraction > App.memoryWarningFraction {
                style = bar.with(fg: theme.warn, bold: true)
            } else {
                style = bar.with(fg: theme.faint)
            }
            surface.textRight(piece.endsAt, 0, piece.text, style)
        }
    }

    /// Where the hints do not all fit beside the version, the version goes first, then hints
    /// from the middle; the last ones, saving and leaving, stay, and an ellipsis marks the gap.
    func drawFooter(_ screen: Screen, width w: Int, y: Int) {
        let theme = ctx.theme
        let bar = Style(fg: theme.footerFg, bg: theme.footerBg)
        surface.fill(Rect(x: 0, y: y, w: w, h: 1), bar)
        let version = Version.full
        let inset = App.contentInset
        // As far from the version as the hints are from each other, and the inset.
        let beside = Self.fitting(screen.footerHints, into: w - 2 * inset - version.count - inset - App.hintSpacing)
        let hints = beside ?? Self.fitting(screen.footerHints, into: w - 2 * inset, dropping: true) ?? []
        // Only where the hints fit beside it: otherwise it would be drawn over them.
        let showsVersion = beside != nil
        var x = inset
        for hint in hints {
            if hint.key.isEmpty {
                x = surface.text(x, y, hint.label, bar.with(fg: theme.dim)) + App.hintSpacing
                continue
            }
            x = surface.text(x, y, hint.key, bar.with(fg: theme.accent, bold: true))
            x = surface.text(x + App.hintGap, y, hint.label, bar)
            x += App.hintSpacing
        }
        if showsVersion { surface.textRight(w - inset, y, version, bar.with(fg: theme.dim)) }
    }

    /// The hints that fit `room`: all of them, or nil; with `dropping`, as many as fit with the
    /// last 2 kept, and Enter and Esc kept where they stand while there is room; an ellipsis
    /// where the others were.
    static func fitting(_ hints: [Hint], into room: Int, dropping: Bool = false) -> [Hint]? {
        func width(_ hint: Hint) -> Int {
            (hint.key.isEmpty ? 0 : hint.key.count + App.hintGap) + hint.label.count + App.hintSpacing
        }
        // No spacing after the last one.
        func total(_ list: [Hint]) -> Int { list.reduce(0) { $0 + width($1) } - (list.isEmpty ? 0 : App.hintSpacing) }
        if total(hints) <= room { return hints }
        guard dropping else { return nil }
        let more = Hint(key: "", label: "…")
        let kept = Set([Glyph.enter, "esc"])
        var shown = hints
        var gap: Int?
        // From the right of what may go, the last 2 aside; Enter and Esc only where the
        // last 2 would not fit beside them, Enter first: Esc is the way out.
        for spared in [kept, ["esc"], []] {
            while total(shown) + width(more) > room,
                let at = shown.indices.dropLast(2).last(where: { !spared.contains(shown[$0].key) })
            {
                shown.remove(at: at)
                gap = gap.map { min($0, at) } ?? at
            }
        }
        guard let gap else { return shown }
        shown.insert(more, at: min(gap, shown.count))
        return shown
    }
}

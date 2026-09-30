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
        surface.text(x + 1, 0, screen.title, bar.with(fg: theme.headerFg))

        let load = ctx.load
        let pieces = Widgets.headerRight(
            width: w,
            titleEnds: x + screen.title.count,
            clock: Fmt.clock(),
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

    /// The hints stop short of the version at the far end.
    func drawFooter(_ screen: Screen, width w: Int, y: Int) {
        let theme = ctx.theme
        let bar = Style(fg: theme.footerFg, bg: theme.footerBg)
        surface.fill(Rect(x: 0, y: y, w: w, h: 1), bar)
        let version = Version.full
        let inset = App.contentInset
        let room = w - inset - version.count - inset
        var x = inset
        for hint in screen.footerHints {
            if x + hint.key.count + hint.label.count + App.hintGap + App.hintSpacing >= room { break }
            x = surface.text(x, y, hint.key, bar.with(fg: theme.accent, bold: true))
            x = surface.text(x + App.hintGap, y, hint.label, bar)
            x += App.hintSpacing
        }
        if room > 0 { surface.textRight(w - inset, y, version, bar.with(fg: theme.dim)) }
    }
}

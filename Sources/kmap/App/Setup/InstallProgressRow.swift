import Foundation

/// An install in two lines: what it is doing, with the numbers, and the bar under it.
enum InstallProgressRow {
    static func status(_ progress: InstallProgress) -> String {
        var line = progress.stage.isEmpty ? t("starting") : progress.stage
        guard let bytes = progress.bytes else { return line }
        line += "   \(Fmt.bytes(bytes.received)) / \(Fmt.bytes(bytes.total))"
        if let rate = progress.rate { line += "  \(Glyph.dot)  \(Fmt.rate(rate))" }
        if let eta = progress.eta { line += "  \(Glyph.dot)  " + t("%@ left", Fmt.duration(eta)) }
        return line
    }

    /// The status line at `y`, the bar at `y + 1`, both `width` wide.
    static func draw(
        _ s: Surface,
        x: Int,
        y: Int,
        width: Int,
        progress: InstallProgress,
        theme: Theme,
        bg: Color? = nil
    ) {
        let ground = bg ?? theme.appBg
        s.text(x, y, truncate(status(progress), to: width), Style(fg: theme.dim, bg: ground))
        Widgets.progressBar(
            s,
            x: x,
            y: y + 1,
            width: width,
            fraction: progress.fraction,
            theme: theme,
            bg: ground
        )
    }
}

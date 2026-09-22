import Foundation

/// The pieces every screen is built from: bars, rows, fields, the scroll hint and the
/// log pane. Popups, the header and pictures are in the files beside this one.
enum Widgets {
    /// The cells a progress bar keeps for its percentage.
    private static let percentWidth = 5
    /// The label column of a field unless the screen says otherwise.
    static let fieldLabelWidth = 16
    /// The cells a row's selection marker takes.
    static let markerWidth = 2

    /// A single-line bar, filled from the left, with the percentage after it.
    static func progressBar(
        _ s: Surface,
        x: Int,
        y: Int,
        width: Int,
        fraction: Double?,
        theme: Theme,
        fillColor: Color? = nil,
        bg: Color? = nil
    ) {
        guard width > 4 else { return }
        let barWidth = width - percentWidth
        let color = fillColor ?? theme.accent
        let ground = bg ?? theme.appBg

        guard let fraction else {
            // Indeterminate: a dim rule and no percentage.
            s.hline(x, y, barWidth, Glyph.barEmpty, Style(fg: theme.rule, bg: ground))
            s.text(x + barWidth + 1, y, "  ·  ", Style(fg: theme.faint, bg: ground))
            return
        }

        let clamped = max(0, min(1, fraction))
        let filled = Int((Double(barWidth) * clamped).rounded())
        s.hline(x, y, filled, Glyph.barFill, Style(fg: color, bg: ground))
        s.hline(x + filled, y, barWidth - filled, Glyph.barEmpty, Style(fg: theme.rule, bg: ground))
        s.text(x + barWidth + 1, y, Fmt.percent(clamped), Style(fg: theme.dim, bg: ground))
    }

    /// A label/value row with the label in a fixed left column.
    static func field(
        _ s: Surface,
        rect: Rect,
        y: Int,
        label: String,
        value: String,
        theme: Theme,
        labelWidth: Int = fieldLabelWidth,
        valueStyle: Style? = nil,
        selected: Bool = false
    ) {
        let bg = selected ? theme.selectionBg : theme.appBg
        if selected {
            s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        }
        s.text(rect.x, y, marker(selected), Style(fg: theme.accent, bg: bg))
        s.text(
            rect.x + markerWidth,
            y,
            label,
            Style(fg: selected ? theme.text : theme.dim, bg: bg),
            limit: labelWidth
        )
        let vx = rect.x + markerWidth + labelWidth
        let style = valueStyle ?? Style(fg: selected ? theme.selectionFg : theme.text, bg: bg)
        s.text(vx, y, truncate(value, to: max(0, rect.maxX - vx)), style.with(bg: bg))
    }

    /// A selectable list row with an optional right-aligned trailing value.
    static func row(
        _ s: Surface,
        rect: Rect,
        y: Int,
        text: String,
        trailing: String? = nil,
        theme: Theme,
        selected: Bool,
        dimmed: Bool = false,
        leading: String = "",
        leadingColor: Color? = nil
    ) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        s.text(rect.x, y, marker(selected), Style(fg: theme.accent, bg: bg))

        var x = rect.x + markerWidth
        if !leading.isEmpty {
            x = s.text(x, y, leading, Style(fg: leadingColor ?? theme.faint, bg: bg))
        }

        let trailingWidth = trailing.map { $0.count + 2 } ?? 0
        let available = max(0, rect.maxX - x - trailingWidth)
        let fg = dimmed ? theme.faint : (selected ? theme.selectionFg : theme.text)
        s.text(x, y, truncate(text, to: available), Style(fg: fg, bg: bg, bold: selected))

        if let trailing {
            s.textRight(rect.maxX, y, trailing, Style(fg: theme.dim, bg: bg))
        }
    }

    /// The mark in front of the selected row, and the blank in front of the others.
    static func marker(_ selected: Bool) -> String {
        selected ? "\(Glyph.arrowRight) " : "  "
    }

    /// A scroll position indicator drawn in the right margin.
    ///
    /// - Parameter rowHeight: terminal rows per entry, so the track covers the list rather
    ///   than the entry count.
    static func scrollHint(
        _ s: Surface,
        rect: Rect,
        offset: Int,
        count: Int,
        visible: Int,
        theme: Theme,
        rowHeight: Int = 1
    ) {
        guard count > visible, visible > 1 else { return }
        let step = max(1, rowHeight)
        let trackHeight = visible * step
        let thumbHeight = max(step, trackHeight * visible / count)
        let maxOffset = max(1, count - visible)
        let thumbTop = (trackHeight - thumbHeight) * offset / maxOffset
        let x = rect.maxX - 1
        for i in 0..<trackHeight {
            let inThumb = i >= thumbTop && i < thumbTop + thumbHeight
            s.put(
                x,
                rect.y + i,
                inThumb ? Glyph.thumb : Glyph.track,
                Style(fg: inThumb ? theme.dim : theme.rule, bg: theme.appBg)
            )
        }
    }

    /// The rolling output pane, showing the last `rect.h` lines less `scrollOffset`.
    static func logPane(
        _ s: Surface,
        rect: Rect,
        lines: [LogEvent],
        theme: Theme,
        scrollOffset: Int = 0
    ) {
        guard rect.h > 0, rect.w > 0 else { return }
        let end = max(0, lines.count - scrollOffset)
        let start = max(0, end - rect.h)
        for (i, line) in lines[start..<end].enumerated() {
            let y = rect.y + i
            let (prefix, style) = logMark(line, theme: theme)
            let x = s.text(rect.x, y, prefix, style)
            s.text(x, y, truncate(line.text, to: max(0, rect.maxX - x)), style)
        }
    }

    /// The mark and colour of a log line: what kind of thing it is first, how much it
    /// matters where the kind says nothing.
    private static func logMark(_ line: LogEvent, theme: Theme) -> (String, Style) {
        switch (line.kind, line.severity) {
        case (.step, _): return ("\(Glyph.arrowRight) ", Style(fg: theme.accent, bg: theme.appBg))
        case (.ok, _): return ("\(Glyph.check) ", Style(fg: theme.ok, bg: theme.appBg))
        case (_, .warn): return ("! ", Style(fg: theme.warn, bg: theme.appBg))
        case (_, .error): return ("\(Glyph.cross) ", Style(fg: theme.danger, bg: theme.appBg))
        case (.output, _): return ("  ", Style(fg: theme.faint, bg: theme.appBg))
        case (.plain, _): return ("  ", Style(fg: theme.dim, bg: theme.appBg))
        }
    }
}

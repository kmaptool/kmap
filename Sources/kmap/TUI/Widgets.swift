import Foundation

/// Selection and scroll offset for a vertical list.
struct ListState {
    var selected = 0
    var offset = 0

    /// Moves the selection by `delta`, wrapping round the ends. Page jumps pass
    /// `wrap: false`, which clamps at the ends instead.
    mutating func move(_ delta: Int, count: Int, wrap: Bool = true) {
        guard count > 0 else { selected = 0; offset = 0; return }
        if wrap {
            selected = ((selected + delta) % count + count) % count
        } else {
            selected = max(0, min(count - 1, selected + delta))
        }
    }

    mutating func jump(to index: Int, count: Int) {
        guard count > 0 else { selected = 0; return }
        selected = max(0, min(count - 1, index))
    }

    /// Keeps the selection inside the visible window.
    mutating func clamp(count: Int, visible: Int) {
        guard count > 0, visible > 0 else { selected = 0; offset = 0; return }
        selected = max(0, min(count - 1, selected))
        if selected < offset { offset = selected }
        if selected >= offset + visible { offset = selected - visible + 1 }
        offset = max(0, min(offset, max(0, count - visible)))
    }
}

enum Widgets {

    /// A single-line bar: `━━━━━━──────  62%`
    static func progressBar(_ s: Surface, x: Int, y: Int, width: Int,
                            fraction: Double?, theme: Theme,
                            fillColor: Color? = nil, bg: Color? = nil) {
        guard width > 4 else { return }
        let labelWidth = 5
        let barWidth = width - labelWidth
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
    static func field(_ s: Surface, rect: Rect, y: Int, label: String, value: String,
                      theme: Theme, labelWidth: Int = 16,
                      valueStyle: Style? = nil, selected: Bool = false) {
        let bg = selected ? theme.selectionBg : theme.appBg
        if selected {
            s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))
        }
        let marker = selected ? "\(Glyph.arrowRight) " : "  "
        s.text(rect.x, y, marker, Style(fg: theme.accent, bg: bg))
        s.text(rect.x + 2, y, label, Style(fg: selected ? theme.text : theme.dim, bg: bg),
               limit: labelWidth)
        let vx = rect.x + 2 + labelWidth
        let style = valueStyle ?? Style(fg: selected ? theme.selectionFg : theme.text, bg: bg)
        s.text(vx, y, truncate(value, to: max(0, rect.maxX - vx)), style.with(bg: bg))
    }

    /// A selectable list row with an optional right-aligned trailing value.
    static func row(_ s: Surface, rect: Rect, y: Int, text: String, trailing: String? = nil,
                    theme: Theme, selected: Bool, dimmed: Bool = false,
                    leading: String = "", leadingColor: Color? = nil) {
        let bg = selected ? theme.selectionBg : theme.appBg
        s.fill(Rect(x: rect.x, y: y, w: rect.w, h: 1), Style(fg: theme.text, bg: bg))

        let marker = selected ? "\(Glyph.arrowRight) " : "  "
        s.text(rect.x, y, marker, Style(fg: theme.accent, bg: bg))

        var x = rect.x + 2
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

    /// A scroll position indicator drawn in the right margin.
    ///
    /// - Parameter rowHeight: terminal rows per entry, so the track covers the list rather
    ///   than the entry count.
    static func scrollHint(_ s: Surface, rect: Rect, offset: Int, count: Int, visible: Int,
                           theme: Theme, rowHeight: Int = 1) {
        guard count > visible, visible > 1 else { return }
        let step = max(1, rowHeight)
        let trackHeight = visible * step
        let thumbHeight = max(step, trackHeight * visible / count)
        let maxOffset = max(1, count - visible)
        let thumbTop = (trackHeight - thumbHeight) * offset / maxOffset
        let x = rect.maxX - 1
        for i in 0..<trackHeight {
            let inThumb = i >= thumbTop && i < thumbTop + thumbHeight
            s.put(x, rect.y + i, inThumb ? "▐" : "│",
                  Style(fg: inThumb ? theme.dim : theme.rule, bg: theme.appBg))
        }
    }

    /// The rolling output pane, showing the last `rect.h` lines less `scrollOffset`.
    static func logPane(_ s: Surface, rect: Rect, lines: [LogEvent], theme: Theme,
                        scrollOffset: Int = 0) {
        guard rect.h > 0, rect.w > 0 else { return }
        let visible = rect.h
        let end = max(0, lines.count - scrollOffset)
        let start = max(0, end - visible)
        let window = Array(lines[start..<end])

        for (i, line) in window.enumerated() {
            let y = rect.y + i
            let style: Style
            let prefix: String
            switch (line.kind, line.severity) {
            case (.step, _):
                style = Style(fg: theme.accent, bg: theme.appBg)
                prefix = "\(Glyph.arrowRight) "
            case (.ok, _):
                style = Style(fg: theme.ok, bg: theme.appBg)
                prefix = "\(Glyph.check) "
            case (_, .warn):
                style = Style(fg: theme.warn, bg: theme.appBg)
                prefix = "! "
            case (_, .error):
                style = Style(fg: theme.danger, bg: theme.appBg)
                prefix = "\(Glyph.cross) "
            case (.output, _):
                style = Style(fg: theme.faint, bg: theme.appBg)
                prefix = "  "
            case (.plain, _):
                style = Style(fg: theme.dim, bg: theme.appBg)
                prefix = "  "
            }
            let x = s.text(rect.x, y, prefix, style)
            s.text(x, y, truncate(line.text, to: max(0, rect.maxX - x)), style)
        }
    }

    /// A centred message box drawn over the screen.
    static func notice(_ s: Surface, rect: Rect, title: String, message: String,
                       theme: Theme, tone: Color? = nil) {
        let width = min(rect.w - 8, 72)
        let body = wrapText(message, width: width - 4)
        let height = body.count + 4
        let box = Rect(x: rect.x + (rect.w - width) / 2,
                       y: rect.y + max(0, (rect.h - height) / 2),
                       w: width, h: height)
        s.fill(box, Style(fg: theme.text, bg: theme.panelBg))
        s.box(box, Style(fg: tone ?? theme.rule, bg: theme.panelBg),
              title: title,
              titleStyle: Style(fg: tone ?? theme.accent, bg: theme.panelBg, bold: true))
        for (i, line) in body.enumerated() {
            s.text(box.x + 2, box.y + 2 + i, line, Style(fg: theme.text, bg: theme.panelBg))
        }
    }

    /// The dropdown a field opens, anchored to `row`: below it where there is room and
    /// above it otherwise.
    static func optionList(_ s: Surface, within form: Rect, anchorRow row: Int,
                           options: [String], at index: Int, theme: Theme,
                           indent: Int = 18) {
        guard !options.isEmpty, form.w > 8 else { return }
        let width = min(form.w - 4, max(24, (options.map(\.count).max() ?? 20) + 6))
        // Ten at a time, scrolled to keep the selection in view.
        let visible = min(10, options.count)
        let first = max(0, min(options.count - visible, index - visible / 2))
        let height = visible + 2
        let top = row + 1 + height <= form.maxY ? row + 1 : max(form.y, row - height)
        let box = Rect(x: form.x + min(indent, max(0, form.w - width)), y: top,
                       w: width, h: height)

        s.fill(box, Style(fg: theme.text, bg: theme.raisedBg))
        s.box(box, Style(fg: theme.accent, bg: theme.raisedBg))
        for i in 0..<visible {
            let at = first + i
            guard let option = options[safe: at] else { break }
            let picked = at == index
            let style = Style(fg: picked ? theme.strong : theme.text,
                              bg: picked ? theme.selectionBg : theme.raisedBg,
                              bold: picked)
            s.fill(Rect(x: box.x + 1, y: box.y + 1 + i, w: box.w - 2, h: 1), style)
            s.text(box.x + 2, box.y + 1 + i, picked ? "\(Glyph.check) " : "  ",
                   Style(fg: theme.picked, bg: style.bg))
            s.text(box.x + 4, box.y + 1 + i, truncate(option, to: box.w - 5), style)
        }
    }

    /// The right-hand header pieces, right to left, each with the column it ends at. The
    /// clock is always present; the load figures are dropped where they would reach the
    /// title.
    static func headerRight(width: Int, titleEnds: Int, clock: String,
                            load: MachineLoad) -> [(text: String, endsAt: Int)] {
        var out = [(clock, width - 2)]
        var edge = width - 2 - clock.count - 2

        let memory = load.totalMemory > 0
            ? Fmt.memory(used: load.usedMemory, total: load.totalMemory) : ""
        let cpu = load.cpu.map { t("cpu %d%%", Int(($0 * 100).rounded())) } ?? ""
        // Memory and CPU are shown together or not at all.
        let needed = [memory, cpu].filter { !$0.isEmpty }.reduce(0) { $0 + $1.count + 2 }
        guard needed > 0, edge - needed > titleEnds + 2 else { return out }

        if !memory.isEmpty {
            out.append((memory, edge))
            edge -= memory.count + 2
        }
        if !cpu.isEmpty {
            out.append((cpu, edge))
        }
        return out
    }

    static func spinner(_ frame: Int) -> Character {
        Glyph.spinner[(frame / 3) % Glyph.spinner.count]
    }

    // MARK: Showing a colour as itself

    /// A block of one colour, `width` cells wide, returning the column after it. A nil or
    /// unparsable colour is drawn as a rule, standing for transparency.
    @discardableResult
    static func swatch(_ s: Surface, x: Int, y: Int, colour: String?,
                       width: Int = 2, theme: Theme) -> Int {
        guard width > 0 else { return x }
        if let colour, let parsed = Color.hex(colour) {
            s.fill(Rect(x: x, y: y, w: width, h: 1), Style(fg: parsed, bg: parsed))
        } else {
            s.hline(x, y, width, Glyph.barEmpty, Style(fg: theme.faint, bg: theme.appBg))
        }
        return x + width
    }

    /// The size a picture is drawn at, in cells.
    struct PictureFit {
        /// Whole-number reduction. 1 draws every pixel; 2 draws one cell per 2x2 block.
        let scale: Int
        let columns: Int
        let rows: Int
        var isReduced: Bool { scale > 1 }
    }

    /// Cells across per pixel: a cell is about twice as tall as it is wide, so two side by
    /// side are square.
    static let cellsPerPixel = 2

    /// The size a picture will be drawn at, reduced by whole steps until it fits.
    static func pictureFit(_ block: XpmBlock,
                           maxColumns: Int = .max, maxRows: Int = .max) -> PictureFit {
        let width = block.width, height = block.height
        guard width > 0, height > 0, maxColumns >= cellsPerPixel, maxRows >= 1 else {
            return PictureFit(scale: 1, columns: 0, rows: 0)
        }
        var scale = 1
        while true {
            let columns = ((width + scale - 1) / scale) * cellsPerPixel
            let rows = (height + scale - 1) / scale
            if (columns <= maxColumns && rows <= maxRows) || scale >= max(width, height) {
                return PictureFit(scale: scale, columns: columns, rows: rows)
            }
            scale += 1
        }
    }

    /// Draws a TYP picture as background-coloured cells, one row per pixel row, reduced by
    /// a whole factor where it does not fit. Transparent pixels are drawn as `background`.
    ///
    /// - Returns: the number of rows used.
    @discardableResult
    static func picture(_ s: Surface, x: Int, y: Int, _ block: XpmBlock,
                        background: Color,
                        maxColumns: Int = .max, maxRows: Int = .max) -> Int {
        guard let grid = block.pixels() else { return 0 }
        let fit = pictureFit(block, maxColumns: maxColumns, maxRows: maxRows)
        guard fit.rows > 0, fit.columns > 0 else { return 0 }
        let clear = Style(fg: background, bg: background)

        for row in 0..<fit.rows {
            for column in 0..<(fit.columns / cellsPerPixel) {
                let colour = average(grid, x: column * fit.scale, y: row * fit.scale,
                                     over: fit.scale, on: background)
                let style = colour.map { Style(fg: $0, bg: $0) } ?? clear
                for cell in 0..<cellsPerPixel {
                    s.put(x + column * cellsPerPixel + cell, y + row, " ", style)
                }
            }
        }
        return fit.rows
    }

    /// One cell of a reduced picture: the mean of the pixels it covers, mixed with
    /// `background` in proportion to the transparent pixels among them. Returns nil when
    /// every covered pixel is transparent.
    private static func average(_ grid: [[String?]], x: Int, y: Int, over scale: Int,
                                on background: Color) -> Color? {
        var r = 0, g = 0, b = 0, opaque = 0, seen = 0
        for py in y..<(y + scale) {
            guard let line = grid[safe: py] else { continue }
            for px in x..<(x + scale) where px < line.count {
                seen += 1
                guard let text = line[px], let colour = Color.hex(text),
                      case .rgb(let cr, let cg, let cb) = colour.kind else { continue }
                r += Int(cr); g += Int(cg); b += Int(cb)
                opaque += 1
            }
        }
        guard opaque > 0, seen > 0 else { return nil }
        let ink = (r / opaque, g / opaque, b / opaque)
        guard opaque < seen, case .rgb(let br, let bg, let bb) = background.kind else {
            return .rgb(UInt8(ink.0), UInt8(ink.1), UInt8(ink.2))
        }
        func mix(_ over: Int, _ under: Int) -> UInt8 {
            UInt8((over * opaque + under * (seen - opaque)) / seen)
        }
        return .rgb(mix(ink.0, Int(br)), mix(ink.1, Int(bg)), mix(ink.2, Int(bb)))
    }

    /// A picture reduced to a single row of cell colours, nil where nothing is painted.
    /// Returned rather than drawn, for callers that have one row per entry.
    static func colourRow(_ block: XpmBlock, width: Int, on background: Color) -> [Color?] {
        guard width > 0, let grid = block.pixels() else { return [] }
        let fit = pictureFit(block, maxColumns: width, maxRows: 1)
        guard fit.columns > 0 else { return [] }
        var out: [Color?] = []
        for column in 0..<(fit.columns / cellsPerPixel) {
            let colour = average(grid, x: column * fit.scale, y: 0, over: fit.scale,
                                 on: background)
            for _ in 0..<cellsPerPixel { out.append(colour) }
        }
        return out
    }

    /// Paints one row of colours into the lower half of its cells, leaving a gap above so
    /// adjacent list entries stay separated without spending a row.
    static func halfRow(_ s: Surface, x: Int, y: Int, colours: [Color?], background: Color) {
        for (i, colour) in colours.enumerated() {
            guard let colour else { continue }
            s.put(x + i, y, Glyph.lowerHalf, Style(fg: colour, bg: background))
        }
    }

    /// Draws a plain line as casing, fill and casing, at the widths the style gives, scaled
    /// down to `rect.h` when they do not fit.
    ///
    /// - Returns: the number of rows used.
    @discardableResult
    static func lineSample(_ s: Surface, rect: Rect, fill: String?, casing: String?,
                           width: Int?, border: Int?, background: Color) -> Int {
        guard rect.w > 0, rect.h > 0 else { return 0 }
        let fillColour = fill.flatMap(Color.hex)
        let casingColour = casing.flatMap(Color.hex)
        // An unspecified width is one pixel, as on the receiver.
        let wanted = max(1, width ?? 1)
        let borderRows = casingColour == nil ? 0 : max(1, border ?? 1)

        let thickness: Int
        let casingRows: Int
        if wanted + borderRows * 2 <= rect.h {
            thickness = wanted
            casingRows = borderRows
        } else {
            // Too tall to draw to scale: one casing row each side of whatever is left.
            casingRows = borderRows > 0 && rect.h >= 3 ? 1 : 0
            thickness = max(1, rect.h - casingRows * 2)
        }
        let rows = thickness + casingRows * 2
        let top = rect.y + max(0, (rect.h - rows) / 2)

        for i in 0..<rows {
            let colour = (i < casingRows || i >= casingRows + thickness)
                ? casingColour : fillColour
            let style = colour.map { Style(fg: $0, bg: $0) }
                ?? Style(fg: background, bg: background)
            s.fill(Rect(x: rect.x, y: top + i, w: rect.w, h: 1), style)
        }
        return rows
    }
}

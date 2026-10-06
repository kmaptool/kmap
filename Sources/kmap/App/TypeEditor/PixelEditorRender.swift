import Foundation

/// Drawing the pixel editor: the canvas of doubled cells, the palette, the prompt.
extension PixelEditorScreen {
    /// A dim tick every this many pixels, as a ruler.
    private static let rulerStep = 5
    private static let paletteWidth = 22
    private static let leastPaletteRoom = 12
    /// Luminance above which black reads better than white over a colour.
    private static let lightThreshold = 140

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        let picture = shown
        var facts =
            "\(picture.width)×\(picture.height), "
            + tn("%d colour(s)", picture.palette.count)
        if showingNight { facts += "  ·  " + t("night — same drawing, its own colours") }
        if dirty { facts += "  ·  " + t("unsaved") }
        s.text(
            rect.x,
            y,
            facts,
            Style(fg: dirty ? theme.warn : theme.dim, bg: theme.appBg)
        )
        y += 1

        canvasOrigin = (rect.x + 3, y + 1)
        // The palette keeps its room beside, the readout and the prompt theirs under: a
        // canvas larger than what is left shows the window round the cursor.
        let across = max(1, min(shown.width, (rect.maxX - canvasOrigin.x - Self.paletteWidth - 3) / 2))
        let down = max(1, min(shown.height, rect.maxY - 2 - canvasOrigin.y))
        canvasScroll.x = Self.follow(cursor.x, from: canvasScroll.x, showing: across, of: shown.width)
        canvasScroll.y = Self.follow(cursor.y, from: canvasScroll.y, showing: down, of: shown.height)
        canvasShown = (across, down)
        drawCanvas(s, across: across, down: down, theme: theme)

        let paletteX = canvasOrigin.x + across * 2 + 3
        paletteOrigin = (paletteX, canvasOrigin.y)
        // Above the readout and the prompt, which sit under the canvas.
        let readout = min(canvasOrigin.y + down + 1, rect.maxY - 2)
        paletteShown = max(0, min(shown.palette.count, readout - canvasOrigin.y))
        paletteScroll = Self.follow(
            selected,
            from: paletteScroll,
            showing: max(1, paletteShown),
            of: shown.palette.count
        )
        drawPalette(s, x: paletteX, y: canvasOrigin.y, right: rect.maxX, theme: theme)

        y = readout
        defer { picker?.render(into: s, rect: rect, theme: theme) }
        guard y >= rect.y, y < rect.maxY else { return }

        // What is under the cursor: the swatch, and its exact value.
        if let rows = grid() {
            let index = rows[min(cursor.y, rows.count - 1)][min(cursor.x, shown.width - 1)]
            let entry = shown.palette[safe: index]
            var x = s.text(
                rect.x,
                y,
                String(format: "%3d,%-3d ", cursor.x, cursor.y),
                Style(fg: theme.dim, bg: theme.appBg)
            )
            x = Widgets.swatch(
                s,
                x: x,
                y: y,
                colour: entry?.colour.flatMap { $0 },
                width: 3,
                theme: theme
            )
            x = s.text(
                x + 1,
                y,
                entry?.colour.flatMap { $0 } ?? t("clear"),
                Style(fg: theme.text, bg: theme.appBg)
            )
            s.text(
                x + 2,
                y,
                t("colour %d of %d", index + 1, shown.palette.count),
                Style(fg: theme.faint, bg: theme.appBg)
            )
            y += 1
        }
        guard y < rect.maxY else { return }

        if let prompt {
            drawPrompt(prompt, s, rect: rect, y: y, theme: theme)
            return
        }
        if let message {
            s.text(
                rect.x,
                y,
                truncate(message, to: rect.w),
                Style(fg: messageIsError ? theme.danger : theme.ok, bg: theme.appBg)
            )
        }
    }

    /// The first of `shown` cells to draw so that `cursor` is among them.
    static func follow(_ cursor: Int, from first: Int, showing shown: Int, of total: Int) -> Int {
        var first = first
        if cursor < first { first = cursor }
        if cursor >= first + shown { first = cursor - shown + 1 }
        return max(0, min(first, total - shown))
    }

    /// Two cells per pixel, a ruler outside, the cursor over the colour in black or white.
    private func drawCanvas(_ s: Surface, across: Int, down: Int, theme: Theme) {
        guard let rows = grid() else { return }
        let columns = canvasScroll.x..<(canvasScroll.x + across)
        let lines = canvasScroll.y..<(canvasScroll.y + down)
        for x in columns where x % Self.rulerStep == 0 {
            s.text(
                canvasOrigin.x + (x - columns.lowerBound) * 2,
                canvasOrigin.y - 1,
                String(format: "%-2d", x),
                Style(fg: theme.faint, bg: theme.appBg)
            )
        }
        for y in lines where y % Self.rulerStep == 0 {
            s.textRight(
                canvasOrigin.x - 1,
                canvasOrigin.y + y - lines.lowerBound,
                "\(y)",
                Style(fg: theme.faint, bg: theme.appBg)
            )
        }

        for y in lines {
            for x in columns {
                let entry = shown.palette[safe: rows[y][x]]
                let colour = entry?.colour.flatMap { $0 }
                let cellX = canvasOrigin.x + (x - columns.lowerBound) * 2
                let cellY = canvasOrigin.y + y - lines.lowerBound
                let onCursor = x == cursor.x && y == cursor.y

                // Transparency is a chequer: on the device it shows what lies beneath.
                let background: Color
                if let colour, let parsed = Color.hex(colour) {
                    background = parsed
                } else {
                    background = (x + y) % 2 == 0 ? theme.rule : theme.panelBg
                }
                s.fill(
                    Rect(x: cellX, y: cellY, w: 2, h: 1),
                    Style(fg: background, bg: background)
                )

                if !onCursor, x % Self.rulerStep == 0, y % Self.rulerStep == 0 {
                    s.put(
                        cellX,
                        cellY,
                        Glyph.dot,
                        Style(fg: contrast(with: colour, theme: theme), bg: background)
                    )
                }

                if onCursor {
                    let ink =
                        focus == .canvas
                        ? contrast(with: colour, theme: theme)
                        : theme.faint
                    s.put(cellX, cellY, "▏", Style(fg: ink, bg: background, bold: true))
                    s.put(cellX + 1, cellY, "▕", Style(fg: ink, bg: background, bold: true))
                }
            }
        }
    }

    /// Black or white by Rec. 601 luminance, whichever reads against the colour.
    private func contrast(with colour: String?, theme: Theme) -> Color {
        guard let colour, let parsed = Color.hex(colour), case .rgb(let r, let g, let b) = parsed.kind
        else { return theme.strong }
        let luminance = (299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000
        return luminance > Self.lightThreshold ? .rgb(0, 0, 0) : .rgb(255, 255, 255)
    }

    /// The marker is lit only while the palette holds the arrow keys.
    private func drawPalette(_ s: Surface, x: Int, y: Int, right: Int, theme: Theme) {
        guard x < right - Self.leastPaletteRoom else { return }
        for (index, entry) in shown.palette.enumerated()
        where index >= paletteScroll && index < paletteScroll + paletteShown {
            let rowY = y + index - paletteScroll
            let isSelected = index == selected
            let bg = isSelected ? theme.selectionBg : theme.appBg
            s.fill(Rect(x: x, y: rowY, w: min(right - x, Self.paletteWidth), h: 1), Style(fg: theme.text, bg: bg))

            var cx = s.text(
                x,
                rowY,
                isSelected ? "\(Glyph.arrowRight) " : "  ",
                Style(
                    fg: focus == .palette ? theme.accent : theme.faint,
                    bg: bg,
                    bold: focus == .palette && isSelected
                )
            )
            cx = Widgets.swatch(s, x: cx, y: rowY, colour: entry.colour, width: 3, theme: theme)
            cx += 1
            s.text(
                cx,
                rowY,
                entry.colour ?? t("none"),
                Style(fg: entry.colour == nil ? theme.faint : theme.text, bg: bg)
            )
        }
    }

    private func drawPrompt(_ prompt: Prompt, _ s: Surface, rect: Rect, y: Int, theme: Theme) {
        let label: String
        switch prompt {
        case .addColour: label = t("New colour:")
        case .changeColour(let index):
            label = t("Colour %d becomes:", index + 1)
        case .size: label = t("Size:")
        case .confirmDiscard:
            s.text(
                rect.x,
                y,
                t("unsaved changes — leave anyway? (y/n)"),
                Style(fg: theme.warn, bg: theme.appBg)
            )
            return
        }
        let x = s.text(rect.x, y, label + " ", Style(fg: theme.text, bg: theme.appBg))
        let end = s.text(x, y, draft, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        if case .size = prompt {
            s.textRight(rect.maxX, y, sizeRule, Style(fg: theme.faint, bg: theme.appBg))
        } else {
            s.textRight(
                rect.maxX,
                y,
                t("#RRGGBB or none"),
                Style(fg: theme.faint, bg: theme.appBg)
            )
        }
    }
}

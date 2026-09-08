import Foundation

/// Drawing the pixel editor: the canvas of doubled cells, the palette, the prompt.
extension PixelEditorScreen {
    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        var y = rect.y

        let picture = shown
        var facts = "\(picture.width)×\(picture.height), "
            + tn("%d colour(s)", picture.palette.count)
        if showingNight { facts += "  ·  " + t("night — same drawing, its own colours") }
        if dirty { facts += "  ·  " + t("unsaved") }
        s.text(rect.x, y, facts,
               Style(fg: dirty ? theme.warn : theme.dim, bg: theme.appBg))
        y += 1

        canvasOrigin = (rect.x + 3, y + 1)
        drawCanvas(s, theme: theme)

        let paletteX = canvasOrigin.x + shown.width * 2 + 3
        paletteOrigin = (paletteX, canvasOrigin.y)
        drawPalette(s, x: paletteX, y: canvasOrigin.y, right: rect.maxX, theme: theme)

        y = canvasOrigin.y + shown.height + 1
        guard y < rect.maxY else { return }

        // What is under the cursor, in words: the swatch shows the colour, the text gives
        // its exact value.
        if let rows = grid() {
            let index = rows[min(cursor.y, rows.count - 1)][min(cursor.x, shown.width - 1)]
            let entry = shown.palette[safe: index]
            var x = s.text(rect.x, y, String(format: "%3d,%-3d ", cursor.x, cursor.y),
                           Style(fg: theme.dim, bg: theme.appBg))
            x = Widgets.swatch(s, x: x, y: y, colour: entry?.colour.flatMap { $0 },
                               width: 3, theme: theme)
            x = s.text(x + 1, y, entry?.colour.flatMap { $0 } ?? t("clear"),
                       Style(fg: theme.text, bg: theme.appBg))
            s.text(x + 2, y, t("colour %d of %d", index + 1, shown.palette.count),
                   Style(fg: theme.faint, bg: theme.appBg))
            y += 1
        }
        guard y < rect.maxY else { return }

        if let prompt {
            drawPrompt(prompt, s, rect: rect, y: y, theme: theme)
            // Drawn over everything else: the picker covers the screen while it is open.
            picker?.render(into: s, rect: rect, theme: theme)
            return
        }
        if let message {
            s.text(rect.x, y, truncate(message, to: rect.w),
                   Style(fg: messageIsError ? theme.danger : theme.ok, bg: theme.appBg))
        }
    }

    /// Draws the canvas at two cells per pixel, with a dim tick every fifth pixel as a
    /// ruler and the cursor drawn over the colour in whichever of black or white reads
    /// against it.
    private func drawCanvas(_ s: Surface, theme: Theme) {
        guard let rows = grid() else { return }

        // A ruler along the top and down the left, outside the canvas: every fifth pixel.
        for x in stride(from: 0, to: shown.width, by: 5) {
            s.text(canvasOrigin.x + x * 2, canvasOrigin.y - 1, String(format: "%-2d", x),
                   Style(fg: theme.faint, bg: theme.appBg))
        }
        for y in stride(from: 0, to: shown.height, by: 5) {
            s.textRight(canvasOrigin.x - 1, canvasOrigin.y + y, "\(y)",
                        Style(fg: theme.faint, bg: theme.appBg))
        }

        for y in 0..<shown.height {
            for x in 0..<shown.width {
                let entry = shown.palette[safe: rows[y][x]]
                let colour = entry?.colour.flatMap { $0 }
                let cellX = canvasOrigin.x + x * 2
                let cellY = canvasOrigin.y + y
                let onCursor = x == cursor.x && y == cursor.y

                // The pixel itself. Transparency is drawn as a chequer, not a colour: on
                // the device it shows whatever lies beneath the icon.
                let background: Color
                if let colour, let parsed = Color.hex(colour) {
                    background = parsed
                } else {
                    background = (x + y) % 2 == 0 ? theme.rule : theme.panelBg
                }
                s.fill(Rect(x: cellX, y: cellY, w: 2, h: 1),
                       Style(fg: background, bg: background))

                // A tick every fifth pixel, dim enough to read past.
                if !onCursor, x % 5 == 0, y % 5 == 0 {
                    s.put(cellX, cellY, Glyph.dot,
                          Style(fg: contrast(with: colour, theme: theme), bg: background))
                }

                if onCursor {
                    // Over the colour, not instead of it: the pixel stays visible.
                    let ink = focus == .canvas ? contrast(with: colour, theme: theme)
                                               : theme.faint
                    s.put(cellX, cellY, "▏", Style(fg: ink, bg: background, bold: true))
                    s.put(cellX + 1, cellY, "▕", Style(fg: ink, bg: background, bold: true))
                }
            }
        }
    }

    /// Black or white, whichever reads against the colour underneath, chosen by luminance.
    private func contrast(with colour: String?, theme: Theme) -> Color {
        guard let colour, let parsed = Color.hex(colour),
              case .rgb(let r, let g, let b) = parsed.kind else { return theme.strong }
        // Rec. 601 weights: green contributes most of the perceived brightness, blue least.
        let luminance = (299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000
        return luminance > 140 ? .rgb(0, 0, 0) : .rgb(255, 255, 255)
    }

    private func drawPalette(_ s: Surface, x: Int, y: Int, right: Int, theme: Theme) {
        guard x < right - 12 else { return }
        // The selected entry is marked in either pane; the marker is lit only while the
        // palette holds the arrow keys.
        for (index, entry) in shown.palette.enumerated() {
            let rowY = y + index
            let isSelected = index == selected
            let bg = isSelected ? theme.selectionBg : theme.appBg
            s.fill(Rect(x: x, y: rowY, w: min(right - x, 22), h: 1),
                   Style(fg: theme.text, bg: bg))

            var cx = s.text(x, rowY, isSelected ? "\(Glyph.arrowRight) " : "  ",
                            Style(fg: focus == .palette ? theme.accent : theme.faint,
                                  bg: bg, bold: focus == .palette && isSelected))
            cx = Widgets.swatch(s, x: cx, y: rowY, colour: entry.colour, width: 3, theme: theme)
            cx += 1
            s.text(cx, rowY, entry.colour ?? t("none"),
                   Style(fg: entry.colour == nil ? theme.faint : theme.text, bg: bg))
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
            s.text(rect.x, y, t("unsaved changes — leave anyway? (y/n)"),
                   Style(fg: theme.warn, bg: theme.appBg))
            return
        }
        let x = s.text(rect.x, y, label + " ", Style(fg: theme.text, bg: theme.appBg))
        let end = s.text(x, y, draft, Style(fg: theme.strong, bg: theme.appBg, bold: true))
        s.put(end, y, "▏", Style(fg: theme.accent, bg: theme.appBg))
        if case .size = prompt {
            s.textRight(rect.maxX, y, sizeRule, Style(fg: theme.faint, bg: theme.appBg))
        } else {
            s.textRight(rect.maxX, y, t("#RRGGBB or none"),
                        Style(fg: theme.faint, bg: theme.appBg))
        }
    }
}

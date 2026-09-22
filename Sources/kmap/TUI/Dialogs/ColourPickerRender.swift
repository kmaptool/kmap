import Foundation

/// The picker on screen: the grid, the style's own colours, the sliders and the readout.
extension ColourPicker {
    /// Luma in thousandths, ITU-R 601; above the threshold the ink goes dark.
    private static let lumaRed = 299, lumaGreen = 587, lumaBlue = 114, darkInkAbove = 140
    /// The grid is drawn no fainter than this, so a grey pick still shows its hues.
    private static let faintestGrid = 0.15
    /// Cells a palette swatch takes, and the gap after it.
    private static let paletteSwatchWidth = 3, paletteGap = 1
    /// The slider row: the name column and the room kept for the readout.
    private static let sliderNameWidth = 11
    private static let sliderBarStart = 15, sliderBarReserve = 24, sliderBarNarrowest = 8
    /// Rows the palette pane takes when there is one: heading, swatches, blank.
    private static let paletteRows = 3
    /// The readout swatch.
    private static let readoutSwatchWidth = 4

    /// Draws over the bottom of whatever is behind it, as wide as it is given.
    mutating func render(into s: Surface, rect: Rect, theme: Theme) {
        fitGrid(toWidth: rect.w)
        // Two borders, the grid, the palette, a blank line, three sliders and the readout.
        let height = 2 + (Self.levels + 1) + (palette.isEmpty ? 0 : Self.paletteRows) + 1 + Slider.allCases.count + 1
        let box = Rect(
            x: rect.x,
            y: max(rect.y, rect.maxY - height),
            w: min(hues * Self.cellWidth + 4, rect.w),
            h: min(height, rect.h)
        )

        s.fill(box, Style(fg: theme.text, bg: theme.panelBg))
        s.box(
            box,
            Style(fg: theme.accent, bg: theme.panelBg),
            title: t("pick a colour"),
            titleStyle: Style(fg: theme.accent, bg: theme.panelBg, bold: true)
        )

        var y = box.y + 1
        y = drawGrid(s, box: box, y: y, theme: theme)
        if !palette.isEmpty { y = drawPalette(s, box: box, y: y + 1, theme: theme) }
        y = drawSliders(s, box: box, y: y + 1, theme: theme)
        drawReadout(s, box: box, y: y, theme: theme)
    }

    private func drawGrid(_ s: Surface, box: Rect, y: Int, theme: Theme) -> Int {
        let column = gridColumn
        let row = gridRow
        let cell = Self.cellWidth
        for r in 0...Self.levels {
            for c in 0..<hues {
                let x = box.x + 2 + c * cell
                guard x + cell <= box.maxX - 1 else { continue }
                let colour = Self.colour(row: r, column: c, hues: hues, saturation: max(Self.faintestGrid, saturation))
                guard let parsed = Color.hex(colour) else { continue }
                s.fill(Rect(x: x, y: y + r, w: cell, h: 1), Style(fg: parsed, bg: parsed))
                if pane == .grid, r == row, c == column {
                    drawCursor(s, x: x, y: y + r, width: cell, on: colour, parsed)
                }
            }
        }
        return y + Self.levels + 1
    }

    /// Draws the colours the edited style already uses, and returns the next free row.
    private func drawPalette(_ s: Surface, box: Rect, y: Int, theme: Theme) -> Int {
        s.text(
            box.x + 2,
            y,
            t("already in this style"),
            Style(fg: pane == .palette ? theme.text : theme.faint, bg: theme.panelBg)
        )
        var x = box.x + 2
        let row = y + 1
        let width = Self.paletteSwatchWidth
        for (index, colour) in palette.enumerated() {
            guard x + width < box.maxX - 1 else { break }
            if let parsed = Color.hex(colour) {
                s.fill(Rect(x: x, y: row, w: width, h: 1), Style(fg: parsed, bg: parsed))
                if pane == .palette, index == paletteIndex {
                    drawCursor(s, x: x, y: row, width: width, on: colour, parsed)
                }
            }
            x += width + Self.paletteGap
        }
        return row + 1
    }

    /// A thin bar on either edge of a colour cell, in whichever ink reads on it.
    private func drawCursor(_ s: Surface, x: Int, y: Int, width: Int, on colour: String, _ parsed: Color) {
        let ink = Self.contrast(with: colour)
        s.put(x, y, Glyph.leftEdge, Style(fg: ink, bg: parsed, bold: true))
        if width > 1 {
            s.put(x + width - 1, y, Glyph.rightEdge, Style(fg: ink, bg: parsed, bold: true))
        }
    }

    private func drawSliders(_ s: Surface, box: Rect, y: Int, theme: Theme) -> Int {
        let names = [t("hue"), t("saturation"), t("lightness")]
        let values = [hue / HSL.degrees, saturation, lightness]
        let shown = [
            String(format: "%3.0f°", hue),
            String(format: "%3.0f%%", saturation * 100),
            String(format: "%3.0f%%", lightness * 100)
        ]
        let barWidth = max(Self.sliderBarNarrowest, box.w - Self.sliderBarReserve)

        for (index, name) in names.enumerated() {
            let row = y + index
            guard row < box.maxY - 2 else { break }
            let active = pane == .sliders && index == slider.rawValue
            s.text(box.x + 2, row, Widgets.marker(active), Style(fg: theme.accent, bg: theme.panelBg))
            s.text(
                box.x + 4,
                row,
                name.padding(toLength: Self.sliderNameWidth, withPad: " ", startingAt: 0),
                Style(fg: active ? theme.text : theme.dim, bg: theme.panelBg)
            )

            let filled = Int(Double(barWidth) * values[index])
            let x = box.x + Self.sliderBarStart
            s.hline(x, row, filled, Glyph.barFill, Style(fg: active ? theme.accent : theme.dim, bg: theme.panelBg))
            s.hline(x + filled, row, barWidth - filled, Glyph.barEmpty, Style(fg: theme.rule, bg: theme.panelBg))
            s.textRight(
                box.maxX - 2,
                row,
                shown[index],
                Style(fg: active ? theme.strong : theme.dim, bg: theme.panelBg)
            )
        }
        return y + names.count
    }

    private func drawReadout(_ s: Surface, box: Rect, y: Int, theme: Theme) {
        guard y < box.maxY - 1 else { return }
        let colour = pane == .palette ? (palette[safe: paletteIndex] ?? current) : current
        var x = Widgets.swatch(s, x: box.x + 2, y: y, colour: colour, width: Self.readoutSwatchWidth, theme: theme)
        x = s.text(x + 1, y, colour, Style(fg: theme.strong, bg: theme.panelBg, bold: true))
        if let (r, g, b) = Color.channels(of: colour) {
            s.text(x + 2, y, String(format: "r %3d  g %3d  b %3d", r, g, b), Style(fg: theme.dim, bg: theme.panelBg))
        }
        // Key names are literal; only what they do is translated.
        s.textRight(
            box.maxX - 2,
            y,
            "\(Glyph.tab) " + t("grid") + " · " + t("sliders")
                + (palette.isEmpty ? "" : " · " + t("style"))
                + "   \(Glyph.enter) " + t("take it") + "   esc " + t("back"),
            Style(fg: theme.faint, bg: theme.panelBg)
        )
    }

    /// Black or white, whichever reads on the colour.
    private static func contrast(with colour: String) -> Color {
        guard let (r, g, b) = Color.channels(of: colour) else { return .rgb(255, 255, 255) }
        let luma = (lumaRed * r + lumaGreen * g + lumaBlue * b) / 1000
        return luma > darkInkAbove ? .rgb(0, 0, 0) : .rgb(255, 255, 255)
    }
}

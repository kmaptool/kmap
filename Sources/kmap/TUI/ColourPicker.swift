import Foundation

/// Chooses a colour through three panes, switched with Tab: a hue-by-lightness grid with a
/// grey row, hue/saturation/lightness sliders, and the colours the edited style already
/// uses. Enter takes the current colour, Esc cancels.
struct ColourPicker {

    enum Outcome {
        case none
        case chose(String)
        case cancelled
    }

    /// Which of the three the keys are working on.
    enum Pane: Int, CaseIterable {
        case grid, sliders, palette
    }

    /// Lightness bands in the grid, not counting the grey row.
    static let levels = 9
    /// The most hue columns the grid is given, however wide the window is.
    private static let maximumHues = 48
    /// The lightness bands run down from the top value in equal steps.
    private static let topLightness = 0.9, lightnessStep = 0.09
    /// Below this saturation a colour is grey and sits on the grey row.
    private static let greyBelow = 0.06
    private static let defaultSaturation = 0.7
    private static let hueDegrees = 360.0
    /// The grid is drawn no fainter than this, so a grey pick still shows its hues.
    private static let faintestGrid = 0.15
    /// Luma in thousandths, ITU-R 601; above the threshold the ink goes dark.
    private static let lumaRed = 299, lumaGreen = 587, lumaBlue = 114, darkInkAbove = 140

    private(set) var pane: Pane = .grid
    /// The chosen colour, held as HSL; everything shown is derived from these three.
    private(set) var hue: Double = 0
    private(set) var saturation: Double = ColourPicker.defaultSaturation
    private(set) var lightness: Double = 0.5

    private var slider = 0
    private var paletteIndex = 0

    /// Colours the file being edited already uses.
    let palette: [String]

    /// The grid width used by the last render, which bounds horizontal movement.
    private var hues = 24

    init(start: String?, palette: [String] = []) {
        // Deduplicated, keeping the order the style declares them in.
        var seen = Set<String>()
        self.palette = palette.filter { seen.insert($0.uppercased()).inserted }

        if let start, let (r, g, b) = ColourPicker.rgb(of: start) {
            let hsl = ColourPicker.rgbToHSL(r: r, g: g, b: b)
            hue = hsl.hue
            saturation = hsl.saturation
            lightness = hsl.lightness
        }
    }

    var current: String {
        let (r, g, b) = ColourPicker.hslToRGB(hue: hue, saturation: saturation,
                                              lightness: lightness)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: Input

    mutating func handle(_ key: KeyEvent) -> Outcome {
        switch key {
        case .tab:
            pane = Pane(rawValue: (pane.rawValue + 1) % Pane.allCases.count) ?? .grid
            if pane == .palette, palette.isEmpty { pane = .grid }
        case .backTab:
            pane = Pane(rawValue: (pane.rawValue + Pane.allCases.count - 1)
                        % Pane.allCases.count) ?? .grid
            if pane == .palette, palette.isEmpty { pane = .sliders }
        case .enter:
            if pane == .palette, let colour = palette[safe: paletteIndex] {
                return .chose(colour)
            }
            return .chose(current)
        case .esc, .ctrl("c"):
            return .cancelled
        default:
            switch pane {
            case .grid: moveInGrid(key)
            case .sliders: moveSlider(key)
            case .palette: moveInPalette(key)
            }
        }
        return .none
    }

    private mutating func moveInGrid(_ key: KeyEvent) {
        let column = gridColumn
        let row = gridRow
        switch key {
        case .left: setGrid(row: row, column: max(0, column - 1))
        case .right: setGrid(row: row, column: min(hues - 1, column + 1))
        case .up: setGrid(row: max(0, row - 1), column: column)
        case .down: setGrid(row: min(ColourPicker.levels, row + 1), column: column)
        default: break
        }
    }

    /// Arrows move one unit, page keys ten, home and end run to the ends.
    private mutating func moveSlider(_ key: KeyEvent) {
        switch key {
        case .up: slider = max(0, slider - 1)
        case .down: slider = min(2, slider + 1)
        case .left: nudge(-1)
        case .right: nudge(1)
        case .pageUp: nudge(10)
        case .pageDown: nudge(-10)
        case .home: nudge(-1000)
        case .end: nudge(1000)
        default: break
        }
    }

    private mutating func nudge(_ steps: Int) {
        switch slider {
        case 0:
            hue = (hue + Double(steps) + ColourPicker.hueDegrees)
                .truncatingRemainder(dividingBy: ColourPicker.hueDegrees)
        case 1:
            saturation = min(1, max(0, saturation + Double(steps) / 100))
        default:
            lightness = min(1, max(0, lightness + Double(steps) / 100))
        }
    }

    private mutating func moveInPalette(_ key: KeyEvent) {
        guard !palette.isEmpty else { return }
        switch key {
        case .left, .up: paletteIndex = max(0, paletteIndex - 1)
        case .right, .down: paletteIndex = min(palette.count - 1, paletteIndex + 1)
        default: break
        }
        if let colour = palette[safe: paletteIndex], let (r, g, b) = ColourPicker.rgb(of: colour) {
            let hsl = ColourPicker.rgbToHSL(r: r, g: g, b: b)
            hue = hsl.hue
            saturation = hsl.saturation
            lightness = hsl.lightness
        }
    }

    /// The grid cell nearest the current colour; derived, so the cursor stays valid after
    /// the sliders move off a cell.
    private var gridColumn: Int {
        Int((hue / ColourPicker.hueDegrees * Double(hues)).rounded()) % max(1, hues)
    }

    private var gridRow: Int {
        if saturation < ColourPicker.greyBelow { return ColourPicker.levels }
        let step = (ColourPicker.topLightness - lightness) / ColourPicker.lightnessStep
        return max(0, min(ColourPicker.levels - 1, Int(step.rounded())))
    }

    private mutating func setGrid(row: Int, column: Int) {
        if row == ColourPicker.levels {
            saturation = 0
            lightness = Double(column) / Double(max(1, hues - 1))
            return
        }
        hue = Double(column) * ColourPicker.hueDegrees / Double(max(1, hues))
        lightness = ColourPicker.topLightness - Double(row) * ColourPicker.lightnessStep
        if saturation < ColourPicker.greyBelow { saturation = ColourPicker.defaultSaturation }
    }

    /// The `#RRGGBB` colour of one grid cell. Row `levels` is the grey row.
    static func colour(row: Int, column: Int, hues: Int,
                       saturation: Double = defaultSaturation) -> String {
        if row == levels {
            let step = 255 * column / max(1, hues - 1)
            return String(format: "#%02X%02X%02X", step, step, step)
        }
        let (r, g, b) = hslToRGB(hue: Double(column) * hueDegrees / Double(max(1, hues)),
                                 saturation: saturation,
                                 lightness: topLightness - Double(row) * lightnessStep)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: Rendering

    /// Draws over the bottom of whatever is behind it, as wide as it is given.
    mutating func render(into s: Surface, rect: Rect, theme: Theme) {
        let cell = 2
        let inner = max(16, min(rect.w - 4, ColourPicker.maximumHues * cell))
        hues = max(8, inner / cell)

        // Two borders, the grid, the palette heading and row, a blank line, three sliders
        // and the readout.
        let paletteRows = palette.isEmpty ? 0 : 3
        let height = 2 + (ColourPicker.levels + 1) + paletteRows + 4 + 1
        let box = Rect(x: rect.x, y: max(rect.y, rect.maxY - height),
                       w: min(hues * cell + 4, rect.w), h: min(height, rect.h))

        s.fill(box, Style(fg: theme.text, bg: theme.panelBg))
        s.box(box, Style(fg: theme.accent, bg: theme.panelBg),
              title: t("pick a colour"),
              titleStyle: Style(fg: theme.accent, bg: theme.panelBg, bold: true))

        var y = box.y + 1
        y = drawGrid(s, box: box, y: y, cell: cell, theme: theme)
        if !palette.isEmpty { y = drawPalette(s, box: box, y: y + 1, theme: theme) }
        y = drawSliders(s, box: box, y: y + 1, theme: theme)
        drawReadout(s, box: box, y: y, theme: theme)
    }

    private func drawGrid(_ s: Surface, box: Rect, y: Int, cell: Int, theme: Theme) -> Int {
        let column = gridColumn
        let row = gridRow
        for r in 0...ColourPicker.levels {
            for c in 0..<hues {
                let x = box.x + 2 + c * cell
                guard x + cell <= box.maxX - 1 else { continue }
                let colour = ColourPicker.colour(row: r, column: c, hues: hues,
                                                 saturation: max(ColourPicker.faintestGrid, saturation))
                guard let parsed = Color.hex(colour) else { continue }
                s.fill(Rect(x: x, y: y + r, w: cell, h: 1), Style(fg: parsed, bg: parsed))

                if pane == .grid, r == row, c == column {
                    let ink = ColourPicker.contrast(with: colour)
                    s.put(x, y + r, "▏", Style(fg: ink, bg: parsed, bold: true))
                    if cell > 1 {
                        s.put(x + cell - 1, y + r, "▕", Style(fg: ink, bg: parsed, bold: true))
                    }
                }
            }
        }
        return y + ColourPicker.levels + 1
    }

    /// Draws the colours the edited style already uses, and returns the next free row.
    private func drawPalette(_ s: Surface, box: Rect, y: Int, theme: Theme) -> Int {
        s.text(box.x + 2, y, t("already in this style"),
               Style(fg: pane == .palette ? theme.text : theme.faint, bg: theme.panelBg))
        var x = box.x + 2
        let row = y + 1
        for (index, colour) in palette.enumerated() {
            guard x + 3 < box.maxX - 1 else { break }
            let focused = pane == .palette && index == paletteIndex
            if let parsed = Color.hex(colour) {
                s.fill(Rect(x: x, y: row, w: 3, h: 1), Style(fg: parsed, bg: parsed))
                if focused {
                    let ink = ColourPicker.contrast(with: colour)
                    s.put(x, row, "▏", Style(fg: ink, bg: parsed, bold: true))
                    s.put(x + 2, row, "▕", Style(fg: ink, bg: parsed, bold: true))
                }
            }
            x += 4
        }
        return row + 1
    }

    private func drawSliders(_ s: Surface, box: Rect, y: Int, theme: Theme) -> Int {
        let names = [t("hue"), t("saturation"), t("lightness")]
        let values = [hue / ColourPicker.hueDegrees, saturation, lightness]
        let shown = [String(format: "%3.0f°", hue),
                     String(format: "%3.0f%%", saturation * 100),
                     String(format: "%3.0f%%", lightness * 100)]
        let barWidth = max(8, box.w - 24)

        for (index, name) in names.enumerated() {
            let row = y + index
            guard row < box.maxY - 2 else { break }
            let active = pane == .sliders && index == slider
            s.text(box.x + 2, row, active ? "\(Glyph.arrowRight) " : "  ",
                   Style(fg: theme.accent, bg: theme.panelBg))
            s.text(box.x + 4, row, name.padding(toLength: 11, withPad: " ", startingAt: 0),
                   Style(fg: active ? theme.text : theme.dim, bg: theme.panelBg))

            let filled = Int(Double(barWidth) * values[index])
            let x = box.x + 15
            s.hline(x, row, filled, Glyph.barFill,
                    Style(fg: active ? theme.accent : theme.dim, bg: theme.panelBg))
            s.hline(x + filled, row, barWidth - filled, Glyph.barEmpty,
                    Style(fg: theme.rule, bg: theme.panelBg))
            s.textRight(box.maxX - 2, row, shown[index],
                        Style(fg: active ? theme.strong : theme.dim, bg: theme.panelBg))
        }
        return y + names.count
    }

    private func drawReadout(_ s: Surface, box: Rect, y: Int, theme: Theme) {
        guard y < box.maxY - 1 else { return }
        let colour = pane == .palette ? (palette[safe: paletteIndex] ?? current) : current
        var x = Widgets.swatch(s, x: box.x + 2, y: y, colour: colour, width: 4, theme: theme)
        x = s.text(x + 1, y, colour, Style(fg: theme.strong, bg: theme.panelBg, bold: true))
        if let (r, g, b) = ColourPicker.rgb(of: colour) {
            s.text(x + 2, y, String(format: "r %3d  g %3d  b %3d", r, g, b),
                   Style(fg: theme.dim, bg: theme.panelBg))
        }
        // Key names are literal; only what they do is translated.
        s.textRight(box.maxX - 2, y,
                    "⇥ " + t("grid") + " · " + t("sliders")
                    + (palette.isEmpty ? "" : " · " + t("style"))
                    + "   ⏎ " + t("take it") + "   esc " + t("back"),
                    Style(fg: theme.faint, bg: theme.panelBg))
    }

    // MARK: For the tests

    var hueForTests: Double { hue }
    var saturationForTests: Double { saturation }
    var lightnessForTests: Double { lightness }

    // MARK: Colour arithmetic

    private static func contrast(with colour: String) -> Color {
        guard let (r, g, b) = rgb(of: colour) else { return .rgb(255, 255, 255) }
        let luma = (lumaRed * r + lumaGreen * g + lumaBlue * b) / 1000
        return luma > darkInkAbove ? .rgb(0, 0, 0) : .rgb(255, 255, 255)
    }

    static func rgb(of hex: String) -> (Int, Int, Int)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// Hue in degrees, saturation and lightness in 0...1.
    private static func hslToRGB(hue: Double, saturation: Double,
                         lightness: Double) -> (Int, Int, Int) {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let h = hue.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2

        let (r, g, b): (Double, Double, Double)
        switch h {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func byte(_ v: Double) -> Int { max(0, min(255, Int(((v + m) * 255).rounded()))) }
        return (byte(r), byte(g), byte(b))
    }

    /// Converts to hue in degrees, saturation and lightness in 0...1.
    private static func rgbToHSL(r: Int, g: Int, b: Int) -> (hue: Double, saturation: Double,
                                                     lightness: Double) {
        let rd = Double(r) / 255, gd = Double(g) / 255, bd = Double(b) / 255
        let high = max(rd, gd, bd), low = min(rd, gd, bd)
        let lightness = (high + low) / 2
        guard high != low else { return (0, 0, lightness) }

        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        switch high {
        case rd: hue = (gd - bd) / delta + (gd < bd ? 6 : 0)
        case gd: hue = (bd - rd) / delta + 2
        default: hue = (rd - gd) / delta + 4
        }
        return (hue * 60, saturation, lightness)
    }
}

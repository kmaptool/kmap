import Foundation

/// Chooses a colour through three panes, switched with Tab: a hue-by-lightness grid with a
/// grey row, hue/saturation/lightness sliders, and the colours the edited style already
/// uses. Enter takes the current colour, Esc cancels. Drawn in ColourPickerRender.
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

    /// The three sliders, top to bottom.
    enum Slider: Int, CaseIterable {
        case hue, saturation, lightness
    }

    /// Lightness bands in the grid, not counting the grey row.
    static let levels = 9
    /// Cells across per grid column.
    static let cellWidth = 2
    /// How many hue columns the grid may be given, however narrow or wide the window is.
    static let fewestHues = 8
    static let mostHues = 48
    /// The lightness bands run down from the top value in equal steps.
    private static let topLightness = 0.9, lightnessStep = 0.09
    /// Below this saturation a colour is grey and sits on the grey row.
    private static let greyBelow = 0.06
    private static let defaultSaturation = 0.7
    /// A slider moves this much per arrow, and this much per page key.
    private static let sliderStep = 1, sliderPage = 10
    /// A nudge large enough to run any slider to its end.
    private static let sliderRun = 1000

    private(set) var pane: Pane = .grid
    /// The chosen colour, held as HSL; everything shown is derived from these three.
    private(set) var hue: Double = 0
    private(set) var saturation: Double = ColourPicker.defaultSaturation
    private(set) var lightness: Double = 0.5

    private(set) var slider: Slider = .hue
    private(set) var paletteIndex = 0

    /// Colours the file being edited already uses, deduplicated in the order the style
    /// declares them.
    let palette: [String]

    /// The grid width used by the last render, which bounds horizontal movement.
    private(set) var hues = 24

    init(start: String?, palette: [String] = []) {
        var seen = Set<String>()
        self.palette = palette.filter { seen.insert($0.uppercased()).inserted }
        if let start, let hsl = HSL(hex: start) { take(hsl) }
    }

    var current: String {
        HSL(hue: hue, saturation: saturation, lightness: lightness).hex
    }

    private mutating func take(_ hsl: HSL) {
        hue = hsl.hue
        saturation = hsl.saturation
        lightness = hsl.lightness
    }

    /// Fits the grid to the width the last render had.
    mutating func fitGrid(toWidth width: Int) {
        let inner = max(Self.fewestHues * Self.cellWidth, min(width - 4, Self.mostHues * Self.cellWidth))
        hues = max(Self.fewestHues, inner / Self.cellWidth)
    }

    // MARK: Input

    mutating func handle(_ key: KeyEvent) -> Outcome {
        switch key {
        case .tab:
            pane = Pane(rawValue: (pane.rawValue + 1) % Pane.allCases.count) ?? .grid
            if pane == .palette, palette.isEmpty { pane = .grid }
        case .backTab:
            pane = Pane(rawValue: (pane.rawValue + Pane.allCases.count - 1) % Pane.allCases.count) ?? .grid
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
        case .down: setGrid(row: min(Self.levels, row + 1), column: column)
        default: break
        }
    }

    /// Arrows move one unit, page keys ten, home and end run to the ends.
    private mutating func moveSlider(_ key: KeyEvent) {
        switch key {
        case .up: slider = Slider(rawValue: max(0, slider.rawValue - 1)) ?? .hue
        case .down: slider = Slider(rawValue: min(Slider.allCases.count - 1, slider.rawValue + 1)) ?? .lightness
        case .left: nudge(-Self.sliderStep)
        case .right: nudge(Self.sliderStep)
        case .pageUp: nudge(Self.sliderPage)
        case .pageDown: nudge(-Self.sliderPage)
        case .home: nudge(-Self.sliderRun)
        case .end: nudge(Self.sliderRun)
        default: break
        }
    }

    /// Hue moves a degree a step and wraps; the other two move a hundredth and stop.
    private mutating func nudge(_ steps: Int) {
        switch slider {
        case .hue:
            hue = (hue + Double(steps) + HSL.degrees).truncatingRemainder(dividingBy: HSL.degrees)
        case .saturation:
            saturation = min(1, max(0, saturation + Double(steps) / 100))
        case .lightness:
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
        if let colour = palette[safe: paletteIndex], let hsl = HSL(hex: colour) { take(hsl) }
    }

    // MARK: The grid

    /// The grid cell nearest the current colour; derived, so the cursor stays valid after
    /// the sliders move off a cell.
    var gridColumn: Int {
        Int((hue / HSL.degrees * Double(hues)).rounded()) % max(1, hues)
    }

    var gridRow: Int {
        if saturation < Self.greyBelow { return Self.levels }
        let step = (Self.topLightness - lightness) / Self.lightnessStep
        return max(0, min(Self.levels - 1, Int(step.rounded())))
    }

    private mutating func setGrid(row: Int, column: Int) {
        if row == Self.levels {
            saturation = 0
            lightness = Double(column) / Double(max(1, hues - 1))
            return
        }
        hue = Double(column) * HSL.degrees / Double(max(1, hues))
        lightness = Self.topLightness - Double(row) * Self.lightnessStep
        if saturation < Self.greyBelow { saturation = Self.defaultSaturation }
    }

    /// The `#RRGGBB` colour of one grid cell. Row `levels` is the grey row.
    static func colour(
        row: Int,
        column: Int,
        hues: Int,
        saturation: Double = defaultSaturation
    ) -> String {
        if row == levels {
            let step = 255 * column / max(1, hues - 1)
            return Color.hexText(step, step, step)
        }
        return HSL(
            hue: Double(column) * HSL.degrees / Double(max(1, hues)),
            saturation: saturation,
            lightness: topLightness - Double(row) * lightnessStep
        ).hex
    }
}

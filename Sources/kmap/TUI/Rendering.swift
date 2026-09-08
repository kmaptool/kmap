import Foundation

/// A colour a cell can be drawn in: the terminal default, an xterm-256 palette index used
/// by the theme, or an exact RGB triple used for colours taken from a TYP.
struct Color: Equatable {
    enum Kind: Equatable {
        case terminalDefault
        case palette(Int)
        case rgb(UInt8, UInt8, UInt8)
    }

    let kind: Kind

    static let `default` = Color(kind: .terminalDefault)
    static func xterm(_ i: Int) -> Color { Color(kind: .palette(i)) }
    static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color { Color(kind: .rgb(r, g, b)) }

    /// Parses `#RRGGBB`, the form colours take in a TYP source. Returns nil for any other
    /// text, including the `none` that means transparent.
    static func hex(_ text: String) -> Color? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return .rgb(UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    /// The nearest xterm-256 entry: the 6×6×6 cube over levels 0, 95, 135, 175, 215, 255
    /// and the 24-step grey ramp are both tried, and the closer one wins. -1 for the
    /// terminal default.
    var paletteApproximation: Int {
        switch kind {
        case .terminalDefault: return -1
        case .palette(let i): return i
        case .rgb(let r, let g, let b):
            let levels = [0, 95, 135, 175, 215, 255]
            func nearestLevel(_ v: Int) -> Int {
                var best = 0
                for i in 1..<levels.count
                where abs(levels[i] - v) < abs(levels[best] - v) { best = i }
                return best
            }
            let (ri, gi, bi) = (nearestLevel(Int(r)), nearestLevel(Int(g)), nearestLevel(Int(b)))
            let cube = 16 + 36 * ri + 6 * gi + bi
            let cubeError = abs(levels[ri] - Int(r)) + abs(levels[gi] - Int(g))
                + abs(levels[bi] - Int(b))

            // The grey ramp runs 8, 18, … 238 at indices 232…255.
            let average = (Int(r) + Int(g) + Int(b)) / 3
            let step = max(0, min(23, (average - 8 + 5) / 10))
            let greyValue = 8 + step * 10
            let greyError = abs(greyValue - Int(r)) + abs(greyValue - Int(g))
                + abs(greyValue - Int(b))

            return greyError < cubeError ? 232 + step : cube
        }
    }
}

/// A cell's visual style: colors + attributes.
struct Style: Equatable {
    var fg: Color = .default
    var bg: Color = .default
    var bold = false
    var dim = false
    var underline = false
    var reverse = false

    static let plain = Style()

    func with(fg: Color? = nil, bg: Color? = nil, bold: Bool? = nil,
              dim: Bool? = nil, underline: Bool? = nil, reverse: Bool? = nil) -> Style {
        var s = self
        if let fg { s.fg = fg }
        if let bg { s.bg = bg }
        if let bold { s.bold = bold }
        if let dim { s.dim = dim }
        if let underline { s.underline = underline }
        if let reverse { s.reverse = reverse }
        return s
    }

    /// The full SGR sequence (reset plus attributes) for this style. With
    /// `trueColour: false`, RGB colours are folded onto the 256-entry palette.
    func sgr(trueColour: Bool = true) -> String {
        var parts = ["0"]
        if bold { parts.append("1") }
        if dim { parts.append("2") }
        if underline { parts.append("4") }
        if reverse { parts.append("7") }
        if let code = Style.code(for: fg, layer: 38, trueColour: trueColour) { parts.append(code) }
        if let code = Style.code(for: bg, layer: 48, trueColour: trueColour) { parts.append(code) }
        return "\u{1B}[" + parts.joined(separator: ";") + "m"
    }

    private static func code(for colour: Color, layer: Int, trueColour: Bool) -> String? {
        switch colour.kind {
        case .terminalDefault:
            return nil
        case .palette(let i):
            return i >= 0 ? "\(layer);5;\(i)" : nil
        case .rgb(let r, let g, let b):
            guard trueColour else {
                let approximation = colour.paletteApproximation
                return approximation >= 0 ? "\(layer);5;\(approximation)" : nil
            }
            return "\(layer);2;\(r);\(g);\(b)"
        }
    }
}

struct Cell: Equatable {
    var ch: Character = " "
    var style: Style = .plain
}

struct Rect {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var maxX: Int { x + w }
    var maxY: Int { y + h }

    func inset(by n: Int) -> Rect {
        Rect(x: x + n, y: y + n, w: max(0, w - 2 * n), h: max(0, h - 2 * n))
    }
    func inset(dx: Int, dy: Int) -> Rect {
        Rect(x: x + dx, y: y + dy, w: max(0, w - 2 * dx), h: max(0, h - 2 * dy))
    }
    /// Splits off `n` columns from the left, returning (left, remainder).
    func splitLeft(_ n: Int) -> (Rect, Rect) {
        let cut = max(0, min(n, w))
        return (Rect(x: x, y: y, w: cut, h: h),
                Rect(x: x + cut, y: y, w: w - cut, h: h))
    }
    /// Splits off `n` rows from the top, returning (top, remainder).
    func splitTop(_ n: Int) -> (Rect, Rect) {
        let cut = max(0, min(n, h))
        return (Rect(x: x, y: y, w: w, h: cut),
                Rect(x: x, y: y + cut, w: w, h: h - cut))
    }
}

/// The interface palette: greyscale for structure, colour for state and selection.
struct Theme {
    let appBg = Color.xterm(233)
    let panelBg = Color.xterm(234)
    let raisedBg = Color.xterm(236)

    let text = Color.xterm(252)
    let strong = Color.xterm(255)
    let dim = Color.xterm(245)
    let faint = Color.xterm(240)
    let rule = Color.xterm(237)

    let accent = Color.xterm(74)      // steel blue
    let accentDim = Color.xterm(67)
    let ok = Color.xterm(108)         // muted green
    let picked = Color.xterm(114)     // brighter green
    let warn = Color.xterm(179)       // khaki
    let danger = Color.xterm(167)     // muted red

    let headerBg = Color.xterm(236)
    let headerFg = Color.xterm(253)
    let footerBg = Color.xterm(235)
    let footerFg = Color.xterm(246)
    let selectionBg = Color.xterm(238)
    let selectionFg = Color.xterm(255)

    var base: Style { Style(fg: text, bg: appBg) }
    var panel: Style { Style(fg: text, bg: panelBg) }
    var border: Style { Style(fg: rule, bg: appBg) }
    var label: Style { Style(fg: dim, bg: appBg) }
    var muted: Style { Style(fg: faint, bg: appBg) }

    static let strict = Theme()
}

enum Glyph {
    // Box drawing.
    static let tl: Character = "┌"
    static let tr: Character = "┐"
    static let bl: Character = "└"
    static let br: Character = "┘"
    static let h: Character = "─"
    static let v: Character = "│"
    static let bar: Character = "│"
    static let dot: Character = "·"
    static let arrowRight: Character = "›"
    static let check: Character = "✓"
    static let cross: Character = "✕"
    static let ellipsis: Character = "…"

    // Progress: heavy rule for filled, light rule for empty.
    static let barFill: Character = "━"
    static let barEmpty: Character = "─"

    // Half block: one cell carries two square pixels, so a 20×20 icon fits in 20 columns
    // and 10 rows.
    static let lowerHalf: Character = "▄"

    /// The turning wheel. Ten braille frames, or four strokes where braille is not drawn:
    /// the substitution maps the ten onto the four, and ten does not divide by four, so
    /// the wheel stepped back at the end of every cycle. A turn takes the same time in
    /// both — three ticks a frame, twelve ticks a turn.
    static let brailleSpinner: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let windowsSpinner: [Character] = ["|", "/", "-", "\\"]

    #if os(Windows)
    static let spinner = windowsSpinner
    #else
    static let spinner = brailleSpinner
    #endif

    /// The two keys named by a picture rather than a word. Windows consoles draw them as
    /// hollow boxes, and a key nobody can read is a key nobody presses, so there they are
    /// spelled out — the hint bar lays out from the text and simply takes the room.
    #if os(Windows)
    static let enter = "Enter"
    static let tab = "Tab"
    #else
    static let enter = "⏎"
    static let tab = "⇥"
    #endif

    /// What a Windows console can actually draw, in place of what it cannot.
    ///
    /// Consolas and Cascadia stop at WGL4, and a character outside it comes out as a
    /// hollow box: the tick, the cross, the braille spinner, the eighth-blocks and the
    /// heavy rules all died that way. Each is swapped for one the font carries and one
    /// cell wide, so nothing shifts. Everything else — Cyrillic included — passes
    /// through untouched, and off Windows nothing is substituted at all.
    static let windowsSubstitutes: [Character: Character] = [
        "✓": "√", "✕": "×", "✗": "×",
        "▏": "│", "▕": "│", "▸": "►", "▹": "►", "◂": "◄",
        // The heavy rules become light ones rather than double ones: the progress bar is
        // drawn filled against empty in two colours, and a double line beside a single one
        // reads as two different things where the Mac shows one line in two shades.
        "━": "─", "┃": "│",
        // A bare key mark drawn in one cell: the word would not fit, and an arrow reads
        // better than a bracket. In a sentence these two are spelled out, see L10n.
        "⏎": "←", "⇥": "→", "＋": "+",
        // The spinner, frame for frame, as the same turning stroke.
        "⠋": "|", "⠙": "/", "⠹": "-", "⠸": "\\", "⠼": "|",
        "⠴": "/", "⠦": "-", "⠧": "\\", "⠇": "|", "⠏": "/",
    ]

    static func drawable(_ ch: Character) -> Character {
        #if os(Windows)
        return windowsSubstitutes[ch] ?? ch
        #else
        return ch
        #endif
    }
}

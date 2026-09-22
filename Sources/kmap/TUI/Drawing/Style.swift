import Foundation

/// A cell's visual style: colours and attributes.
struct Style: Equatable {
    var fg: Color = .default
    var bg: Color = .default
    var bold = false
    var dim = false
    var underline = false
    var reverse = false

    static let plain = Style()

    func with(
        fg: Color? = nil,
        bg: Color? = nil,
        bold: Bool? = nil,
        dim: Bool? = nil,
        underline: Bool? = nil,
        reverse: Bool? = nil
    ) -> Style {
        var s = self
        if let fg { s.fg = fg }
        if let bg { s.bg = bg }
        if let bold { s.bold = bold }
        if let dim { s.dim = dim }
        if let underline { s.underline = underline }
        if let reverse { s.reverse = reverse }
        return s
    }

    /// The SGR layers colours are set on.
    private static let foregroundLayer = 38
    private static let backgroundLayer = 48

    /// The full SGR sequence (reset plus attributes) for this style. With
    /// `trueColour: false`, RGB colours are folded onto the 256-entry palette.
    func sgr(trueColour: Bool = true) -> String {
        var parts = ["0"]
        if bold { parts.append("1") }
        if dim { parts.append("2") }
        if underline { parts.append("4") }
        if reverse { parts.append("7") }
        if let code = Style.code(for: fg, layer: Self.foregroundLayer, trueColour: trueColour) { parts.append(code) }
        if let code = Style.code(for: bg, layer: Self.backgroundLayer, trueColour: trueColour) { parts.append(code) }
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

/// One character on screen, in one style.
struct Cell: Equatable {
    var ch: Character = " "
    var style: Style = .plain
}

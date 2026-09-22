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

    /// Parses `#RRGGBB`, the form colours take in a TYP source. Nil for any other text,
    /// including the `none` that means transparent.
    static func hex(_ text: String) -> Color? {
        guard let (r, g, b) = channels(of: text) else { return nil }
        return .rgb(UInt8(r), UInt8(g), UInt8(b))
    }

    /// The three channels of `#RRGGBB` as integers, or nil for any other text.
    static func channels(of hex: String) -> (Int, Int, Int)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// `#RRGGBB` for three channels.
    static func hexText(_ r: Int, _ g: Int, _ b: Int) -> String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: The 256-colour palette

    /// The levels of the 6x6x6 colour cube.
    private static let cubeLevels = [0, 95, 135, 175, 215, 255]
    private static let cubeStart = 16
    /// The grey ramp runs 8, 18, ... 238 at indices 232...255.
    private static let greyStart = 232
    private static let greySteps = 24
    private static let greyFirst = 8
    private static let greyStep = 10

    /// The nearest xterm-256 entry: the colour cube and the grey ramp are both tried, and
    /// the closer one wins. -1 for the terminal default.
    var paletteApproximation: Int {
        switch kind {
        case .terminalDefault: return -1
        case .palette(let i): return i
        case .rgb(let r, let g, let b):
            let levels = Self.cubeLevels
            func nearestLevel(_ v: Int) -> Int {
                var best = 0
                for i in 1..<levels.count where abs(levels[i] - v) < abs(levels[best] - v) { best = i }
                return best
            }
            let (ri, gi, bi) = (nearestLevel(Int(r)), nearestLevel(Int(g)), nearestLevel(Int(b)))
            let cube = Self.cubeStart + 36 * ri + 6 * gi + bi
            let cubeError = abs(levels[ri] - Int(r)) + abs(levels[gi] - Int(g)) + abs(levels[bi] - Int(b))

            let average = (Int(r) + Int(g) + Int(b)) / 3
            let step = max(0, min(Self.greySteps - 1, (average - Self.greyFirst + Self.greyStep / 2) / Self.greyStep))
            let grey = Self.greyFirst + step * Self.greyStep
            let greyError = abs(grey - Int(r)) + abs(grey - Int(g)) + abs(grey - Int(b))

            return greyError < cubeError ? Self.greyStart + step : cube
        }
    }
}

import Foundation

/// A colour as hue in degrees and saturation and lightness in 0...1: what the picker
/// holds, with the conversions to and from `#RRGGBB`.
struct HSL: Equatable {
    static let degrees = 360.0

    var hue: Double
    var saturation: Double
    var lightness: Double

    init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    init?(hex: String) {
        guard let (r, g, b) = Color.channels(of: hex) else { return nil }
        self.init(r: r, g: g, b: b)
    }

    init(r: Int, g: Int, b: Int) {
        let rd = Double(r) / 255, gd = Double(g) / 255, bd = Double(b) / 255
        let high = max(rd, gd, bd), low = min(rd, gd, bd)
        lightness = (high + low) / 2
        guard high != low else {
            hue = 0
            saturation = 0
            return
        }
        let delta = high - low
        saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        switch high {
        case rd: hue = ((gd - bd) / delta + (gd < bd ? 6 : 0)) * 60
        case gd: hue = ((bd - rd) / delta + 2) * 60
        default: hue = ((rd - gd) / delta + 4) * 60
        }
    }

    var rgb: (Int, Int, Int) {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let h = hue.truncatingRemainder(dividingBy: Self.degrees) / 60
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

    var hex: String {
        let (r, g, b) = rgb
        return Color.hexText(r, g, b)
    }
}

import Foundation

/// One decoded block's shared context: the strings every element's tags point into, and
/// the fixed-point scaling for its coordinates.
struct OSMBlock {
    var strings = StringPool([])
    var granularity: Int64 = 100
    var latOffset: Int64 = 0
    var lonOffset: Int64 = 0

    func text(_ index: Int) -> String { strings.text(index) }

    // Wrapping arithmetic: a corrupt granularity or offset must give a wrong coordinate
    // rather than trap.
    func latitude(_ raw: Int64) -> Double {
        Self.quantise(latOffset &+ granularity &* raw)
    }

    func longitude(_ raw: Int64) -> Double {
        Self.quantise(lonOffset &+ granularity &* raw)
    }

    /// Rounds nanodegrees to the hundred: 1e-7 of a degree, the grid libosmium keeps its
    /// locations on.
    static func quantise(_ nanodegrees: Int64) -> Double {
        Double(nanodegrees / 100) * 1e-7  // toward zero, as the C++ does
    }
}

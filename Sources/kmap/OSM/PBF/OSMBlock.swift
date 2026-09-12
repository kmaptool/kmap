import Foundation

/// A block's string table. An entry is decoded to a Swift string on first request and
/// cached; the table is held once per block and shared by reference.
final class StringPool {
    private let raw: [UnsafeRawBufferPointer]
    private var made: [String?]

    init(_ raw: [UnsafeRawBufferPointer]) {
        self.raw = raw
        made = [String?](repeating: nil, count: raw.count)
    }

    var count: Int { raw.count }

    func text(_ index: Int) -> String {
        guard index >= 0 && index < raw.count else { return "" }
        if let known = made[index] { return known }
        let word = String(decoding: raw[index], as: UTF8.self)
        made[index] = word
        return word
    }

    /// Returns every entry, decoding those not decoded yet.
    func all() -> [String] {
        (0..<raw.count).map { text($0) }
    }

    /// Returns an entry's raw bytes, for comparison without building a String.
    func bytes(_ index: Int) -> UnsafeRawBufferPointer? {
        guard index >= 0 && index < raw.count else { return nil }
        return raw[index]
    }
}

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
        Double(nanodegrees / 100) * 1e-7        // toward zero, as the C++ does
    }
}

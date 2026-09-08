import Foundation

/// A Bloom-style rejection test for a set of OSM ids, sized to stay in cache. It never
/// says no to an id that is present, and says yes to about one absent id in five hundred,
/// which costs one lookup in the set behind it.
struct IDFilter {
    /// Bits kept per id: sixteen puts the false-yes rate near one in five hundred at two
    /// probes, for two bytes an id.
    private static let bitsPerID = 16

    private var words: [UInt64] = []
    /// Index of the last bit, and the mask that wraps a hash into range. Always one less
    /// than a power of two, so the wrap is an AND.
    private var mask: UInt64 = 0

    /// True when the set behind it is empty and nothing can match.
    var isEmpty: Bool { words.isEmpty }

    init() {}

    init(_ ids: some Collection<Int64>) {
        guard !ids.isEmpty else { return }
        var bits = UInt64(ids.count * Self.bitsPerID)
        // Round up to a power of two, with a floor that keeps a handful of ids from
        // sharing a single word.
        var size: UInt64 = 512
        while size < bits { size <<= 1 }
        bits = size
        mask = bits - 1
        words = [UInt64](repeating: 0, count: Int(bits) / 64)
        for id in ids {
            let (a, b) = Self.probes(id, mask: mask)
            words[Int(a >> 6)] |= 1 << (a & 63)
            words[Int(b >> 6)] |= 1 << (b & 63)
        }
    }

    /// False means the id is certainly not in the set. True means it may be, and the set
    /// itself has to be asked.
    @inline(__always)
    func mayContain(_ id: Int64) -> Bool {
        guard !words.isEmpty else { return false }
        let (a, b) = Self.probes(id, mask: mask)
        return words.withUnsafeBufferPointer { bits in
            bits[Int(a >> 6)] >> (a & 63) & 1 == 1 && bits[Int(b >> 6)] >> (b & 63) & 1 == 1
        }
    }

    /// Two bit positions from one multiply-and-fold. OSM ids run in long ascending runs,
    /// so the low bits alone would file whole neighbourhoods into the same word.
    @inline(__always)
    private static func probes(_ id: Int64, mask: UInt64) -> (UInt64, UInt64) {
        var h = UInt64(bitPattern: id) &+ 0x9E37_79B9_7F4A_7C15
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        h = h ^ (h >> 31)
        return (h & mask, (h >> 32 | h << 32) & mask)
    }
}
